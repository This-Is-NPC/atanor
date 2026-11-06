defmodule Atanor.TCP.TLS do
  @moduledoc """
  TLS options of the TCP listeners (design §7.3), and the per-instance
  certificate cache that lets a certificate change without a restart.

  The operator configures `tls: [certfile: ..., keyfile: ...]` on a listener
  with `tls_mode: :implicit` or `tls_mode: :starttls` (see `Atanor`). At start
  the files are read and checked: the key must belong to the certificate. A
  listener whose files do not load refuses the start with `ArgumentError`.

  The cache keeps the certificate, its chain, the key and the optional CA
  certificates in memory. Every new handshake — an implicit TLS connection, a
  `{:starttls, bytes, state}` upgrade or a Ranch protocol's own STARTTLS —
  reads the current entry, so it uses the certificate that is loaded now and
  not the one that was on disk when the listener opened. Established
  connections keep the session they negotiated.

  A watcher polls the source files' mtime and size every `tls.reload_ms`
  (5 000 by default) and reloads them when they change. An invalid new
  certificate keeps the previous one, logs a warning and is reported by
  `[:atanor, :tls, :reload]`. `POST /listeners/:name/reload-tls` reloads one
  listener at once. Side effects are reported by `[:atanor, :tls, :handshake]`
  (with `mode: :implicit` or `:starttls`) and `[:atanor, :tls, :starttls]`.
  """
  use GenServer

  require Logger

  @defaults %{handshake_timeout_ms: 10_000, reload_ms: 5_000, verify: :verify_none}

  @keys [
    :certfile,
    :keyfile,
    :cacertfile,
    :versions,
    :ciphers,
    :verify,
    :fail_if_no_peer_cert,
    :handshake_timeout_ms,
    :reload_ms
  ]
  @key_entries [:RSAPrivateKey, :ECPrivateKey, :DSAPrivateKey, :PrivateKeyInfo]

  @curve_oids %{
    {1, 2, 840, 10045, 3, 1, 7} => :secp256r1,
    {1, 3, 132, 0, 34} => :secp384r1,
    {1, 3, 132, 0, 35} => :secp521r1
  }

  @doc """
  Validates a listener's `tls:` option and returns its normalized form. Raises
  `ArgumentError` when a file is missing, the key does not belong to the
  certificate or an option is invalid.
  """
  @spec build!(String.t(), term) :: map
  def build!(listener, opts) do
    check!(Keyword.keyword?(opts), listener, "must be a keyword list")

    case Keyword.keys(opts) -- @keys do
      [] -> :ok
      unknown -> raise ArgumentError, ":listeners entry #{inspect(listener)} tls: unknown options #{inspect(unknown)}"
    end

    certfile = opts[:certfile]
    keyfile = opts[:keyfile]
    cacertfile = opts[:cacertfile]
    versions = opts[:versions]
    ciphers = opts[:ciphers]
    verify = Keyword.get(opts, :verify, @defaults.verify)
    handshake_timeout_ms = Keyword.get(opts, :handshake_timeout_ms, @defaults.handshake_timeout_ms)
    reload_ms = Keyword.get(opts, :reload_ms, @defaults.reload_ms)

    check!(is_binary(certfile) and certfile != "", listener, "tls :certfile is required")
    check!(is_binary(keyfile) and keyfile != "", listener, "tls :keyfile is required")

    check!(
      is_nil(cacertfile) or (is_binary(cacertfile) and cacertfile != ""),
      listener,
      "tls :cacertfile must be a path"
    )

    check!(
      is_nil(versions) or
        (is_list(versions) and versions != [] and Enum.all?(versions, &(&1 in supported_versions()))),
      listener,
      "tls :versions must be a non-empty list of #{inspect(supported_versions())}"
    )

    check!(
      is_nil(ciphers) or (is_list(ciphers) and ciphers != [] and Enum.all?(ciphers, &(is_binary(&1) or is_map(&1)))),
      listener,
      "tls :ciphers must be a non-empty list of cipher names"
    )

    check!(verify in [:verify_none, :verify_peer], listener, "tls :verify must be :verify_none or :verify_peer")
    check!(verify == :verify_none or is_binary(cacertfile), listener, "tls :verify_peer needs :cacertfile")
    fail_if_no_peer_cert = Keyword.get(opts, :fail_if_no_peer_cert, verify == :verify_peer)

    check!(
      is_boolean(fail_if_no_peer_cert),
      listener,
      "tls :fail_if_no_peer_cert must be true or false"
    )

    check!(
      verify == :verify_peer or not Keyword.has_key?(opts, :fail_if_no_peer_cert),
      listener,
      "tls :fail_if_no_peer_cert is only valid with :verify_peer"
    )

    check!(positive_integer?(handshake_timeout_ms), listener, "tls :handshake_timeout_ms must be a positive integer")
    check!(positive_integer?(reload_ms), listener, "tls :reload_ms must be a positive integer")

    tls = %{
      certfile: certfile,
      keyfile: keyfile,
      cacertfile: cacertfile,
      versions: versions,
      ciphers: ciphers,
      verify: verify,
      fail_if_no_peer_cert: fail_if_no_peer_cert,
      handshake_timeout_ms: handshake_timeout_ms,
      reload_ms: reload_ms
    }

    case load(tls) do
      {:ok, _material} -> tls
      {:error, reason} -> raise ArgumentError, ":listeners entry #{inspect(listener)} tls: #{format_error(reason)}"
    end
  end

  @doc "Starts the certificate cache of an instance."
  def child_spec(config) do
    %{
      id: __MODULE__,
      start: {GenServer, :start_link, [__MODULE__, config, [name: server(config.name)]]}
    }
  end

  @doc "The current TLS options of `listener`, for one handshake."
  @spec options(atom, String.t()) :: {:ok, keyword} | :error
  def options(instance, listener) do
    case lookup(instance, listener) do
      %{ssl: ssl} -> {:ok, ssl}
      nil -> :error
    end
  end

  @doc "The TLS mode of `listener`: `:implicit`, `:starttls`, `nil` (plain) or `:error`."
  @spec mode(atom, String.t()) :: :implicit | :starttls | nil | :error
  def mode(instance, listener) do
    case lookup(instance, listener) do
      %{mode: mode} -> mode
      nil -> :error
    end
  end

  @doc """
  Reloads the certificate files of `listener`. `:poll` is the watcher, `:admin`
  the endpoint; both force a load (the watcher only calls it when the files
  changed). A failed load keeps the previous certificate.
  """
  @spec reload(atom, String.t(), :poll | :admin | :start) :: :ok | {:error, term}
  def reload(instance, listener, cause \\ :admin),
    do: GenServer.call(server(instance), {:reload, listener, cause})

  @doc """
  Times one TLS handshake done by `fun` with the current options of
  `listener` and emits `[:atanor, :tls, :handshake]` (and
  `[:atanor, :tls, :starttls]` for an upgrade). `fun` returns `{:ok, socket}`
  or `{:ok, socket, extensions}` or `{:error, reason}`. A `timeout` of
  `:configured` uses the listener's `tls.handshake_timeout_ms`.
  """
  @spec handshake(atom, String.t(), :implicit | :starttls, timeout | :configured, (keyword, timeout -> term)) ::
          {:ok, term} | {:error, term}
  def handshake(instance, listener, mode, timeout, fun) do
    started = System.monotonic_time()

    result =
      case lookup(instance, listener) do
        %{ssl: ssl, timeout: configured} ->
          timeout = if timeout == :configured, do: configured, else: timeout
          normalize(fun.(ssl, timeout))

        nil ->
          {:error, :tls_not_configured}
      end

    meta = %{
      instance: instance,
      listener: listener,
      mode: mode,
      node: node(),
      result: result_tag(result)
    }

    :telemetry.execute([:atanor, :tls, :handshake], %{duration: System.monotonic_time() - started}, meta)

    if mode == :starttls do
      :telemetry.execute([:atanor, :tls, :starttls], %{count: 1}, Map.delete(meta, :mode))
    end

    result
  end

  @doc false
  # The format of a TLS configuration error, for logs and the admin API.
  def format_error({:file, path, reason}), do: "cannot read #{path}: #{:file.format_error(reason)}"
  def format_error({:pem, path}), do: "#{path} is not a valid PEM file"
  def format_error({:no_certificate, path}), do: "#{path} has no certificate"
  def format_error({:no_key, path}), do: "#{path} has no private key"
  def format_error({:encrypted_key, path}), do: "#{path} holds an encrypted private key"
  def format_error({:unsupported_key, type}), do: "unsupported private key type #{inspect(type)}"
  def format_error(:key_mismatch), do: "the private key does not belong to the certificate"
  def format_error({:bad_certificate, reason}), do: "the certificate cannot be parsed: #{inspect(reason)}"
  def format_error(other), do: inspect(other)

  defp server(instance), do: Module.concat(instance, TLS)

  defp table(instance), do: :persistent_term.get({__MODULE__, instance})

  defp lookup(instance, listener) do
    case :ets.lookup(table(instance), listener) do
      [{^listener, entry}] -> entry
      [] -> nil
    end
  rescue
    ArgumentError -> nil
  end

  ## GenServer

  @impl true
  def init(config) do
    # So that terminate/2 runs when the supervisor stops the node.
    Process.flag(:trap_exit, true)
    table = :ets.new(:atanor_tls, [:set, :protected, read_concurrency: true])
    :persistent_term.put({__MODULE__, config.name}, table)

    entries =
      for {name, %{tls: tls} = listener} <- config.listeners,
          tls != nil,
          into: %{} do
        case load(tls) do
          {:ok, material} -> {name, build_entry(name, listener.tls_mode, listener.tls, material)}
          {:error, reason} -> raise ArgumentError, ":listeners entry #{inspect(name)} tls: #{format_error(reason)}"
        end
      end

    # The key stays in the table the handshakes read; the process state (`:sys.get_state/1`, crash
    # reports) holds only what reloads need.
    for {name, entry} <- entries do
      :ets.insert(table, {name, entry})
      schedule(name, entry.reload_ms)
    end

    {:ok, %{config: config, entries: Map.new(entries, fn {name, entry} -> {name, Map.delete(entry, :ssl)} end)}}
  end

  @impl true
  def handle_call({:reload, listener, cause}, _from, state) do
    cond do
      not is_map_key(state.config.listeners, listener) ->
        {:reply, {:error, :unknown_listener}, state}

      not is_map_key(state.entries, listener) ->
        {:reply, {:error, :no_tls}, state}

      true ->
        {result, state} = reload_entry(state, listener, cause)
        {:reply, result, state}
    end
  end

  @impl true
  def handle_info({:poll, listener}, state) do
    entry = state.entries[listener]
    schedule(listener, entry.reload_ms)

    if changed?(entry) do
      {_result, state} = reload_entry(state, listener, :poll)
      {:noreply, state}
    else
      {:noreply, state}
    end
  end

  @impl true
  def terminate(_reason, state) do
    :persistent_term.erase({__MODULE__, state.config.name})
    :ok
  end

  defp reload_entry(state, listener, cause) do
    entry = Map.fetch!(state.entries, listener)

    case load(entry.source) do
      {:ok, material} ->
        entry = build_entry(listener, entry.mode, entry.source, material)
        :ets.insert(table(state.config.name), {listener, entry})
        Logger.info("atanor: reloaded the TLS certificate of listener #{listener}")
        emit(state, listener, cause, :ok)
        {:ok, %{state | entries: Map.put(state.entries, listener, Map.delete(entry, :ssl))}}

      {:error, reason} ->
        # Keep the old material; remember the new signature so a broken file is
        # not retried and logged every reload_ms. The admin endpoint retries.
        entry = %{entry | signature: signature(entry.source)}

        Logger.warning(
          "atanor: could not reload the TLS certificate of listener #{listener}, keeping the previous one: " <>
            format_error(reason)
        )

        emit(state, listener, cause, {:error, reason})
        {{:error, reason}, %{state | entries: Map.put(state.entries, listener, entry)}}
    end
  end

  defp emit(state, listener, cause, result) do
    :telemetry.execute([:atanor, :tls, :reload], %{count: 1}, %{
      instance: state.config.name,
      listener: listener,
      cause: cause,
      result: result,
      node: node()
    })
  end

  defp schedule(name, reload_ms), do: Process.send_after(self(), {:poll, name}, reload_ms)

  defp changed?(entry), do: signature(entry.source) != entry.signature

  defp build_entry(name, mode, source, material) do
    %{
      name: name,
      mode: mode,
      source: source,
      ssl: material.ssl,
      timeout: source.handshake_timeout_ms,
      reload_ms: source.reload_ms,
      signature: signature(source)
    }
  end

  ## Certificate material

  # Reads the files and checks that the key belongs to the first certificate.
  defp load(tls) do
    with {:ok, certs} <- certificates(tls.certfile),
         {:ok, key} <- private_key(tls.keyfile),
         {:ok, cacerts} <- optional_certificates(tls.cacertfile),
         :ok <- check_key(certs, key) do
      {:ok, %{ssl: ssl_options(certs, key, cacerts, tls)}}
    end
  end

  defp ssl_options(certs, key, cacerts, tls) do
    [cert: certs, key: key] ++
      if(cacerts, do: [cacerts: cacerts], else: []) ++
      if(tls.versions, do: [versions: tls.versions], else: []) ++
      if(tls.ciphers, do: [ciphers: tls.ciphers], else: []) ++
      [verify: tls.verify, client_renegotiation: false] ++
      if(tls.verify == :verify_peer, do: [fail_if_no_peer_cert: tls.fail_if_no_peer_cert], else: [])
  end

  defp certificates(path) do
    with {:ok, entries} <- pem_entries(path) do
      case for {:Certificate, der, _} <- entries, do: der do
        [] -> {:error, {:no_certificate, path}}
        certs -> {:ok, certs}
      end
    end
  end

  defp optional_certificates(nil), do: {:ok, nil}

  defp optional_certificates(path) do
    with {:ok, entries} <- pem_entries(path) do
      case for {:Certificate, der, _} <- entries, do: der do
        [] -> {:error, {:no_certificate, path}}
        certs -> {:ok, certs}
      end
    end
  end

  defp private_key(path) do
    with {:ok, entries} <- pem_entries(path) do
      keys = for {type, der, _} = entry <- entries, type in @key_entries, do: {type, der, entry}

      case keys do
        [] ->
          {:error, {:no_key, path}}

        [{_type, _der, entry}] ->
          case entry do
            {_type, _der, :not_encrypted} -> {:ok, {elem(entry, 0), elem(entry, 1)}}
            _ -> {:error, {:encrypted_key, path}}
          end

        _ ->
          {:error, {:unsupported_key, :multiple}}
      end
    end
  end

  defp pem_entries(path) do
    with {:ok, pem} <- File.read(path) do
      try do
        {:ok, :public_key.pem_decode(pem)}
      rescue
        _ -> {:error, {:pem, path}}
      end
    else
      {:error, reason} -> {:error, {:file, path, reason}}
    end
  end

  # The public part of the key must equal the certificate's
  # SubjectPublicKeyInfo. DSA is accepted for completeness; RSA, ECDSA and
  # EdDSA cover the keys operators use in practice.
  defp check_key([cert | _], {type, der}) do
    with {:ok, public} <- certificate_public(cert),
         {:ok, key_public} <- key_public({type, der, :not_encrypted}) do
      if public == key_public, do: :ok, else: {:error, :key_mismatch}
    end
  end

  defp certificate_public(der) do
    {:OTPCertificate, tbs, _signature_algorithm, _signature} = :public_key.pkix_decode_cert(der, :otp)
    {:OTPSubjectPublicKeyInfo, _algorithm, public} = elem(tbs, 7)
    {:ok, public}
  rescue
    error -> {:error, {:bad_certificate, error}}
  end

  defp key_public(entry) do
    key = :public_key.pem_entry_decode(entry)

    case key do
      {:RSAPrivateKey, _, modulus, exponent, _, _, _, _, _, _, _} ->
        {:ok, {:RSAPublicKey, modulus, exponent}}

      {:DSAPrivateKey, _, p, q, g, y, _x} ->
        {:ok, {:DSAPublicKey, p, q, g, y}}

      {:ECPrivateKey, _version, _private, _params, public} when public != :asn1_NOVALUE ->
        {:ok, {:ECPoint, public}}

      {:ECPrivateKey, _version, _private, _params, public, _} when public != :asn1_NOVALUE ->
        {:ok, {:ECPoint, public}}

      {:ECPrivateKey, _version, private, params, _public} ->
        derive_ec(params, private)

      {:ECPrivateKey, _version, private, params, _public, _} ->
        derive_ec(params, private)

      other ->
        {:error, {:unsupported_key, other}}
    end
  rescue
    _ -> {:error, :unsupported_key}
  end

  defp derive_ec({:namedCurve, {1, 3, 101, 112}}, private), do: eddsa(:ed25519, private)
  defp derive_ec({:namedCurve, {1, 3, 101, 113}}, private), do: eddsa(:ed448, private)

  defp derive_ec({:namedCurve, oid}, private) do
    case Map.fetch(@curve_oids, oid) do
      {:ok, curve} ->
        {public, _private} = :crypto.generate_key(:ecdh, curve, private)
        {:ok, {:ECPoint, public}}

      :error ->
        {:error, {:unsupported_key, {:namedCurve, oid}}}
    end
  end

  defp derive_ec(params, _private), do: {:error, {:unsupported_key, params}}

  defp eddsa(curve, private) do
    {public, _private} = :crypto.generate_key(:eddsa, curve, private)
    {:ok, {:ECPoint, public}}
  end

  ## Signatures of the source files

  defp signature(tls) do
    {stat(tls.certfile), stat(tls.keyfile), stat(tls.cacertfile)}
  end

  defp stat(nil), do: nil

  # The size and digest catch a rewrite that lands in the same second as the
  # previous one (mtime has a one-second resolution) or that keeps the mtime.
  defp stat(path) do
    with {:ok, %File.Stat{mtime: mtime, size: size}} <- File.stat(path, time: :posix),
         {:ok, bytes} <- File.read(path) do
      {mtime, size, :crypto.hash(:sha256, bytes)}
    else
      {:error, reason} -> {:error, reason}
      _ -> {:error, :not_a_file}
    end
  end

  ## Helpers

  defp supported_versions, do: :ssl.versions()[:supported]

  defp normalize({:ok, socket, _extensions}), do: {:ok, socket}
  defp normalize(other), do: other

  defp result_tag({:ok, _}), do: :ok
  defp result_tag({:error, reason}), do: {:error, reason}
  defp result_tag(other), do: other

  defp positive_integer?(value), do: is_integer(value) and value > 0

  defp check!(true, _listener, _message), do: :ok

  defp check!(false, listener, message),
    do: raise(ArgumentError, ":listeners entry #{inspect(listener)} tls: #{message}")
end
