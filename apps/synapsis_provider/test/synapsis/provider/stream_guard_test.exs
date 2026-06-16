defmodule Synapsis.Provider.StreamGuardTest do
  use ExUnit.Case, async: true

  alias Synapsis.Provider.StreamGuard

  describe "scan/2" do
    test "holds back possible pattern suffixes and flushes clean text on finish" do
      guard = StreamGuard.new(["secret"])

      assert {:ok, "h", guard} = StreamGuard.scan(guard, "hello ")
      assert {:ok, "ello ", guard} = StreamGuard.scan(guard, "world")
      assert {:ok, "world"} = StreamGuard.finish(guard)
    end

    test "detects violations split across chunks before emitting the held bytes" do
      guard = StreamGuard.new(["secret"])

      assert {:ok, "pref", guard} = StreamGuard.scan(guard, "prefix se")
      assert {:violation, "secret"} = StreamGuard.scan(guard, "cret suffix")
    end

    test "passes clean split UTF-8 bytes through byte-identically" do
      <<first::binary-size(1), rest::binary>> = "é"
      guard = StreamGuard.new(["blocked"])

      assert {:ok, "", guard} = StreamGuard.scan(guard, "a" <> first)
      assert {:ok, "", guard} = StreamGuard.scan(guard, rest)
      assert {:ok, "", guard} = StreamGuard.scan(guard, "z")
      assert {:ok, "aéz"} = StreamGuard.finish(guard)
    end

    test "detects the first matching rule in the buffered bytes" do
      guard = StreamGuard.new(["alpha", "beta"])

      assert {:ok, "start", guard} = StreamGuard.scan(guard, "start bet")
      assert {:violation, "beta"} = StreamGuard.scan(guard, "a end")
    end
  end

  describe "redact/1" do
    test "exposes only the byte length of the matched rule" do
      assert StreamGuard.redact("secret") == "[redacted 6-byte pattern]"
      refute StreamGuard.redact("secret") =~ "secret"
    end
  end

  # Property tests (design doc "Testing strategy"): behavior must be
  # independent of how the byte stream is chunked.
  describe "chunk-boundary independence" do
    @iterations 100

    test "a corpus containing a rule always violates, for any chunking" do
      :rand.seed(:exsss, {101, 102, 103})
      rules = ["FORBIDDEN", "api-key-123"]

      for i <- 1..@iterations do
        rule = Enum.random(rules)
        corpus = "prefix text é→ #{rule} suffix text"

        assert scan_chunks(random_chunks(corpus), rules) == {:violation, rule},
               "iteration #{i}: violation missed for chunking of #{inspect(corpus)}"
      end
    end

    test "a clean corpus passes through byte-identical, for any chunking" do
      :rand.seed(:exsss, {201, 202, 203})
      rules = ["FORBIDDEN", "api-key-123"]
      corpus = "ordinary streamed text with unicode — héllo wörld → fin"

      for i <- 1..@iterations do
        assert {:ok, emitted} = scan_chunks(random_chunks(corpus), rules)
        assert emitted == corpus, "iteration #{i}: emitted bytes differ from corpus"
      end
    end

    test "emitted bytes never contain a rule, even on the violating stream" do
      :rand.seed(:exsss, {301, 302, 303})
      rules = ["FORBIDDEN"]
      corpus = "safe text FORBIDDEN never emitted"

      for _ <- 1..@iterations do
        {result, emitted} = scan_chunks_collecting(random_chunks(corpus), rules)

        assert {:violation, "FORBIDDEN"} = result
        refute emitted =~ "FORBIDDEN"
      end
    end

    # Splits a corpus into 1..n random chunks at arbitrary *byte* boundaries,
    # including boundaries inside rules and multi-byte codepoints.
    defp random_chunks(corpus) when byte_size(corpus) > 0 do
      chunk_count = :rand.uniform(byte_size(corpus))

      cuts =
        1..(chunk_count - 1)//1
        |> Enum.map(fn _ -> :rand.uniform(byte_size(corpus) - 1) end)
        |> Enum.uniq()
        |> Enum.sort()

      {chunks, last_offset} =
        Enum.map_reduce(cuts, 0, fn cut, offset ->
          {binary_part(corpus, offset, cut - offset), cut}
        end)

      chunks ++ [binary_part(corpus, last_offset, byte_size(corpus) - last_offset)]
    end

    defp scan_chunks(chunks, rules) do
      case scan_chunks_collecting(chunks, rules) do
        {{:violation, rule}, _emitted} -> {:violation, rule}
        {:ok, emitted} -> {:ok, emitted}
      end
    end

    defp scan_chunks_collecting(chunks, rules) do
      guard = StreamGuard.new(rules)

      result =
        Enum.reduce_while(chunks, {guard, ""}, fn chunk, {guard, emitted} ->
          case StreamGuard.scan(guard, chunk) do
            {:ok, emit, guard} -> {:cont, {guard, emitted <> emit}}
            {:violation, rule} -> {:halt, {{:violation, rule}, emitted}}
          end
        end)

      case result do
        {{:violation, _rule}, _emitted} = violation ->
          violation

        {guard, emitted} ->
          case StreamGuard.finish(guard) do
            {:ok, tail} -> {:ok, emitted <> tail}
            {:violation, rule} -> {{:violation, rule}, emitted}
          end
      end
    end
  end
end
