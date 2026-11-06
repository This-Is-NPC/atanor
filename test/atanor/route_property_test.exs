defmodule Atanor.RouteTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias Atanor.Route

  @limits %{max_host_labels: 8, max_path_segments: 6}
  @unreserved ~c"abcXYZ019-._~"
  @hex ~c"0123456789abcdefABCDEF"

  defp canonical(host, path, limits \\ @limits), do: Route.canonical(host, path, limits)

  # A byte of a path segment with its spelling in the request and its canonical form.
  defp piece do
    one_of([
      map(member_of(@unreserved), &{<<&1>>, <<&1>>}),
      map({member_of(@unreserved), member_of([:lower, :upper])}, fn {c, case} -> {escape(c, case), <<c>>} end),
      map({member_of(~c" !\"#$&'()*+,:;<=>?@[]^`{|}"), member_of([:lower, :upper])}, fn {c, case} ->
        {escape(c, case), escape(c, :upper)}
      end),
      map(member_of(["é", "世", "🙂"]), &{&1, &1}),
      map(member_of(["é", "世", "🙂"]), fn s -> {escape_all(s, :lower), escape_all(s, :upper)} end)
    ])
  end

  defp escape(c, :upper), do: "%" <> String.upcase(Base.encode16(<<c>>))
  defp escape(c, :lower), do: "%" <> String.downcase(Base.encode16(<<c>>))
  defp escape_all(s, case), do: for(<<c <- s>>, into: "", do: escape(c, case))

  # A segment as `{spelled, canonical}`; never empty, `.` or `..`.
  defp segment do
    gen all(
          pieces <- list_of(piece(), min_length: 1, max_length: 6),
          {spelled, canon} = Enum.unzip(pieces) |> then(fn {a, b} -> {Enum.join(a), Enum.join(b)} end),
          canon not in [".", ".."],
          spelled not in [".", ".."]
        ) do
      {spelled, canon}
    end
  end

  defp path do
    gen all(
          segments <- list_of(segment(), max_length: 6),
          seps <- list_of(member_of(["/", "//"]), length: 7),
          trailing <- boolean()
        ) do
      spelled =
        "/" <> join(Enum.map(segments, &elem(&1, 0)), seps) <> if(trailing and segments != [], do: "/", else: "")

      canon = "/" <> join(Enum.map(segments, &elem(&1, 1)), seps) <> if(trailing and segments != [], do: "/", else: "")
      {spelled, canon, Enum.map(segments, &elem(&1, 1))}
    end
  end

  defp join([], _), do: ""
  defp join([one], _), do: one
  defp join([a | rest], [sep | seps]), do: a <> sep <> join(rest, seps)

  describe "path" do
    # The canonical path is the spelled path with unreserved escapes decoded and the others in upper case.
    property "spellings of the same path give the same canonical path" do
      check all({spelled, canon, _} <- path()) do
        assert {:ok, "", ^canon} = canonical("", spelled)
      end
    end

    # Canonicalizing twice changes nothing, so routing and authorization see one form.
    property "the canonical path is a fixed point" do
      check all({spelled, _, _} <- path()) do
        assert {:ok, _, once} = canonical("h", spelled)
        assert {:ok, "h", ^once} = canonical("h", once)
      end
    end

    # A dot segment, an escaped slash or NUL, and a bad escape are refused wherever they sit in the path.
    property "refused segments are refused in any position" do
      refused = ["..", ".", "%2e", "%2E", "%2e%2E", ".%2e", "%2F", "%2f", "%00", "%", "%4", "%zz", "%G1", "a%", "a%2"]

      check all(
              {_, _, before} <- path(),
              {_, _, after_} <- path(),
              bad <- member_of(refused)
            ) do
        spelled = "/" <> Enum.join(before ++ [bad] ++ after_, "/")
        assert {:error, :bad_path} = canonical("h", spelled)
      end
    end

    # A path with max_path_segments segments passes and one more is refused, empty segments not counted.
    property "the number of segments is bounded" do
      check all(max <- integer(1..8), extra <- integer(0..2), seps <- list_of(member_of(["/", "//"]), length: 12)) do
        segments = List.duplicate("a", max + extra)
        spelled = "/" <> join(segments, seps) <> "/"
        result = canonical("h", spelled, %{@limits | max_path_segments: max})

        if extra == 0,
          do: assert({:ok, "h", _} = result),
          else: assert({:error, :bad_path} = result)
      end
    end

    # Any byte except slash and NUL, escaped in either case, canonicalizes to the upper case escape or the raw unreserved byte.
    property "every escaped byte has one canonical spelling" do
      check all(byte <- integer(1..255), byte != ?/, case <- member_of([:lower, :upper])) do
        want =
          if byte in @unreserved or byte in ?a..?z or byte in ?A..?Z or byte in ?0..?9,
            do: <<byte>>,
            else: escape(byte, :upper)

        if want in [".", ".."] do
          :ok
        else
          assert {:ok, "h", "/" <> ^want} = canonical("h", "/" <> escape(byte, case))
        end
      end
    end
  end

  describe "host" do
    # The host is lower case and loses one trailing dot.
    property "the host is lower case without its trailing dot" do
      check all(
              labels <-
                list_of(string(@hex ++ ~c"xyzXYZ-", min_length: 1, max_length: 10), min_length: 1, max_length: 5),
              dot <- boolean()
            ) do
        host = Enum.join(labels, ".")
        spelled = host <> if(dot, do: ".", else: "")
        want = String.downcase(host)
        assert {:ok, ^want, "/"} = canonical(spelled, "/")
        assert {:ok, ^want, "/"} = canonical(want, "/")
      end
    end

    # A host has at most max_host_labels labels: one more is refused.
    property "the number of labels is bounded" do
      check all(max <- integer(1..8), count <- integer(1..10)) do
        host = Enum.map_join(1..count, ".", &"l#{&1}")
        result = canonical(host, "/", %{@limits | max_host_labels: max})
        if count <= max, do: assert({:ok, _, _} = result), else: assert({:error, :bad_host} = result)
      end
    end

    # A host has at most 253 bytes once the trailing dot is gone.
    property "the length of a host is bounded to 253 bytes" do
      check all(size <- integer(240..270), dot <- boolean()) do
        host = String.duplicate("a", size)
        result = canonical(host <> if(dot, do: ".", else: ""), "/")
        if size <= 253, do: assert({:ok, ^host, _} = result), else: assert({:error, :bad_host} = result)
      end
    end
  end

  describe "candidates" do
    # Host candidates go from the host itself to `*`, one wildcard per suffix, longest first.
    property "host candidates are the host, its wildcard suffixes and *" do
      check all(labels <- list_of(string(?a..?z, min_length: 1, max_length: 5), min_length: 1, max_length: 5)) do
        host = Enum.join(labels, ".")
        suffixes = for n <- 1..length(labels)//1, n < length(labels), do: "*." <> Enum.join(Enum.drop(labels, n), ".")
        assert Route.host_candidates(host) == [host | suffixes] ++ ["*"]
      end
    end

    # Path prefixes stop at segment boundaries, longest first, and end with "/", whatever the empty segments.
    property "path prefixes are the segment prefixes, longest first, and /" do
      check all(
              segments <- list_of(string(?a..?z, min_length: 1, max_length: 4), max_length: 6),
              seps <- list_of(member_of(["/", "//"]), length: 7)
            ) do
        spelled = "/" <> join(segments, seps) <> "/"
        want = for(n <- length(segments)..1//-1, do: "/" <> Enum.join(Enum.take(segments, n), "/")) ++ ["/"]
        assert Route.path_prefixes(spelled) == want
      end
    end
  end
end
