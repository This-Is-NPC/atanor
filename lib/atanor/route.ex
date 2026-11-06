defmodule Atanor.Route do
  @moduledoc """
  The canonical form of the host and path of a request, and the candidates a
  route or an `:auth` rule is looked up under (design §7.1).

  Routing and authorization both see the canonical form, so they cannot
  disagree with a router that decodes the path:

    * The host is lower case, without the trailing dot of a fully qualified
      name, and has at most 253 bytes and `max_host_labels` labels.
    * In the path, percent-escapes of unreserved characters (`A-Z a-z 0-9 - . _ ~`)
      are decoded and the others keep their escape in upper case (`%c3` is
      `%C3`). A path with an invalid escape, an escaped `/` or NUL, a `.` or
      `..` segment (also escaped), or more than `max_path_segments` segments
      is refused.

  Candidates are built from offsets of the same binary, so the cost of a
  lookup is linear in the host and path, times the number of candidates.
  """

  @type reason :: :bad_host | :bad_path

  @max_host_bytes 253

  @doc "The canonical `{host, path}`, or `{:error, reason}` for a request that is refused."
  @spec canonical(String.t(), String.t(), %{max_host_labels: pos_integer, max_path_segments: pos_integer}) ::
          {:ok, String.t(), String.t()} | {:error, reason}
  def canonical(host, path, %{max_host_labels: max_labels, max_path_segments: max_segments}) do
    with {:ok, host} <- canonical_host(host, max_labels),
         {:ok, path} <- canonical_path(path, max_segments) do
      {:ok, host, path}
    end
  end

  defp canonical_host(host, max_labels) do
    host = host |> String.downcase() |> String.replace_suffix(".", "")

    if byte_size(host) <= @max_host_bytes and length(:binary.matches(host, ".")) < max_labels,
      do: {:ok, host},
      else: {:error, :bad_host}
  end

  defp canonical_path(path, max_segments) do
    parts = :binary.split(path, "/", [:global])

    with {:ok, parts} <- decode_all(parts, []),
         true <- Enum.count(parts, &(&1 != "")) <= max_segments do
      {:ok, Enum.join(parts, "/")}
    else
      _ -> {:error, :bad_path}
    end
  end

  defp decode_all([], acc), do: {:ok, Enum.reverse(acc)}

  defp decode_all([part | rest], acc) do
    with {:ok, part} <- decode(part, <<>>), true <- part not in [".", ".."] do
      decode_all(rest, [part | acc])
    else
      _ -> :error
    end
  end

  defp decode(<<>>, acc), do: {:ok, acc}

  defp decode(<<?%, hi, lo, rest::binary>>, acc) do
    with {:ok, byte} <- hex(hi, lo), true <- byte not in [0, ?/] do
      decode(rest, acc <> if(unreserved?(byte), do: <<byte>>, else: <<?%, upper(hi), upper(lo)>>))
    else
      _ -> :error
    end
  end

  defp decode(<<?%, _::binary>>, _acc), do: :error
  defp decode(<<byte, rest::binary>>, acc), do: decode(rest, <<acc::binary, byte>>)

  defp hex(hi, lo) do
    with h when h != :error <- digit(hi), l when l != :error <- digit(lo), do: {:ok, h * 16 + l}
  end

  defp digit(c) when c in ?0..?9, do: c - ?0
  defp digit(c) when c in ?a..?f, do: c - ?a + 10
  defp digit(c) when c in ?A..?F, do: c - ?A + 10
  defp digit(_), do: :error

  defp upper(c) when c in ?a..?f, do: c - 32
  defp upper(c), do: c

  defp unreserved?(c), do: c in ?a..?z or c in ?A..?Z or c in ?0..?9 or c in [?-, ?., ?_, ?~]

  @doc """
  The host patterns a host is looked up under, most specific first: the host,
  `*.` plus each suffix, and `*`.
  """
  @spec host_candidates(String.t()) :: [String.t()]
  def host_candidates(host) do
    suffixes =
      for {pos, 1} <- :binary.matches(host, "."), do: "*" <> binary_part(host, pos, byte_size(host) - pos)

    [host | suffixes] ++ ["*"]
  end

  @doc """
  The path prefixes a path is looked up under, longest first, at segment
  boundaries: `"/a/b"` gives `["/a/b", "/a", "/"]`.
  """
  @spec path_prefixes(String.t()) :: [String.t()]
  def path_prefixes(path) do
    segments = :binary.split(path, "/", [:global, :trim_all])
    joined = "/" <> Enum.join(segments, "/")

    {ends, _} =
      Enum.map_reduce(segments, 0, fn segment, offset ->
        offset = offset + 1 + byte_size(segment)
        {offset, offset}
      end)

    Enum.map(Enum.reverse(ends), &binary_part(joined, 0, &1)) ++ ["/"]
  end
end
