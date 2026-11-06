defmodule Atanor.Test.TLS do
  @moduledoc """
  Test certificates generated at test time with `openssl`, in a temporary
  directory. No private key is committed.
  """

  @doc "A fresh temporary directory; remove it with `File.rm_rf!/1` in `on_exit`."
  def dir! do
    path = Path.join(System.tmp_dir!(), "atanor-tls-#{System.pid()}-#{System.unique_integer([:positive])}")
    File.mkdir_p!(path)
    path
  end

  @doc """
  Generates a self-signed certificate for `cn` in `dir`, named `name`.
  `type` is `:rsa` (the default), `:ec` or `:ed25519`. Returns the paths and
  the DER certificate.
  """
  def generate!(dir, name, cn \\ "localhost", type \\ :rsa) do
    certfile = Path.join(dir, "#{name}-cert.pem")
    keyfile = Path.join(dir, "#{name}-key.pem")

    {_output, 0} =
      case type do
        :rsa ->
          openssl([
            "req",
            "-x509",
            "-newkey",
            "rsa:2048",
            "-nodes",
            "-keyout",
            keyfile,
            "-out",
            certfile,
            "-days",
            "1",
            "-subj",
            "/CN=#{cn}"
          ])

        :ec ->
          openssl(["ecparam", "-name", "prime256v1", "-genkey", "-noout", "-out", keyfile])
          openssl(["req", "-x509", "-key", keyfile, "-out", certfile, "-days", "1", "-subj", "/CN=#{cn}"])

        :ed25519 ->
          openssl(["genpkey", "-algorithm", "ed25519", "-out", keyfile])
          openssl(["req", "-x509", "-key", keyfile, "-out", certfile, "-days", "1", "-subj", "/CN=#{cn}"])
      end

    %{certfile: certfile, keyfile: keyfile, cn: cn, der: der!(certfile)}
  end

  @doc "A self-signed CA certificate and key, for client-certificate tests."
  def generate_ca!(dir, name \\ "ca") do
    certfile = Path.join(dir, "#{name}-cert.pem")
    keyfile = Path.join(dir, "#{name}-key.pem")

    {_, 0} =
      openssl([
        "req",
        "-x509",
        "-newkey",
        "rsa:2048",
        "-nodes",
        "-keyout",
        keyfile,
        "-out",
        certfile,
        "-days",
        "1",
        "-subj",
        "/CN=Test CA",
        "-addext",
        "basicConstraints=critical,CA:TRUE",
        "-addext",
        "keyUsage=critical,keyCertSign,cRLSign"
      ])

    %{certfile: certfile, keyfile: keyfile, der: der!(certfile)}
  end

  @doc "A client certificate signed by `ca`, with the clientAuth extension."
  def generate_client!(dir, name, ca, cn \\ "client") do
    certfile = Path.join(dir, "#{name}-cert.pem")
    keyfile = Path.join(dir, "#{name}-key.pem")
    csr = Path.join(dir, "#{name}.csr")
    ext = Path.join(dir, "#{name}.ext")
    File.write!(ext, "extendedKeyUsage=clientAuth\nbasicConstraints=CA:FALSE\n")

    {_, 0} =
      openssl(["req", "-new", "-newkey", "rsa:2048", "-nodes", "-keyout", keyfile, "-out", csr, "-subj", "/CN=#{cn}"])

    {_, 0} =
      openssl([
        "x509",
        "-req",
        "-in",
        csr,
        "-CA",
        ca.certfile,
        "-CAkey",
        ca.keyfile,
        "-CAcreateserial",
        "-out",
        certfile,
        "-days",
        "1",
        "-extfile",
        ext
      ])

    %{certfile: certfile, keyfile: keyfile, cn: cn, der: der!(certfile)}
  end

  defp openssl(args), do: System.cmd("openssl", args, stderr_to_stdout: true)

  @doc "Copies the material of `from` over the configured paths of `to`."
  def install!(from, to) do
    File.cp!(from.certfile, to.certfile)
    File.cp!(from.keyfile, to.keyfile)
    :ok
  end

  @doc "Overwrites a file with bytes that are not a certificate."
  def break!(path), do: File.write!(path, "this is not a PEM file\n")

  @doc "The first DER certificate of a PEM file."
  def der!(certfile) do
    {:Certificate, der, _} = hd(:public_key.pem_decode(File.read!(certfile)))
    der
  end

  @doc "The CN of the first certificate of a PEM file."
  def cn!(certfile) do
    {output, 0} = System.cmd("openssl", ["x509", "-noout", "-subject", "-in", certfile])
    [cn] = Regex.run(~r/CN\s*=\s*(.+)/, output, capture: :all_but_first)
    String.trim(cn)
  end
end
