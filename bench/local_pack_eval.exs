# Local pack evaluation — streaming parser vs Pack.Reader
#
# Runs both parsers against the local opencode .git packfiles
# (no network, pure parser performance and memory comparison).
#
#   mix run bench/local_pack_eval.exs

alias Exgit.ObjectStore.Memory
alias Exgit.Pack.{Reader, StreamParser}

defmodule LocalEval.Fmt do
  def us(t) when t >= 1_000_000, do: "#{Float.round(t / 1_000_000, 2)}s"
  def us(t) when t >= 1_000, do: "#{Float.round(t / 1_000, 1)}ms"
  def us(t), do: "#{t}µs"
  def bytes(b) when b >= 1_073_741_824, do: "#{Float.round(b / 1_073_741_824, 2)} GB"
  def bytes(b) when b >= 1_048_576, do: "#{Float.round(b / 1_048_576, 1)} MB"
  def bytes(b) when b >= 1_024, do: "#{Float.round(b / 1_024, 1)} KB"
  def bytes(b), do: "#{b} B"
end

alias LocalEval.Fmt

packs = [
  {"opencode 34MB",  "/Users/ivar/code/opencode/.git/objects/pack/pack-c6597be5752d52a1569f84052ce7bc96a2071210.pack"},
  {"opencode 135MB", "/Users/ivar/code/opencode/.git/objects/pack/pack-87af0cf7c6779ce067dfbfaf9ef8368804204b3a.pack"}
]

IO.puts("""

━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
  exgit local pack benchmark — StreamParser vs Pack.Reader
  #{DateTime.utc_now() |> Calendar.strftime("%Y-%m-%d %H:%M:%S")} UTC
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
""")

for {label, path} <- packs do
  if not File.exists?(path) do
    IO.puts("SKIP #{label}: #{path} not found")
  else

  pack_size = File.stat!(path).size
  IO.puts("── #{label} (#{Fmt.bytes(pack_size)}) ──────────────────────────────")

  # ── Pack.Reader (baseline) ──────────────────────────────────────────────
  :erlang.garbage_collect()
  :timer.sleep(100)
  mem_before_reader = :erlang.memory(:total)

  {t_reader, reader_result} =
    :timer.tc(fn ->
      pack = File.read!(path)
      Reader.parse(pack)
    end)

  :erlang.garbage_collect()
  mem_after_reader = :erlang.memory(:total)

  case reader_result do
    {:ok, objects} ->
      IO.puts("  Pack.Reader")
      IO.puts("    time         : #{Fmt.us(t_reader)}")
      IO.puts("    objects      : #{length(objects)}")
      IO.puts("    heap growth  : #{Fmt.bytes(mem_after_reader - mem_before_reader)}")
      IO.puts("    growth/pack  : #{Float.round((mem_after_reader - mem_before_reader) / pack_size, 2)}×")

    {:error, reason} ->
      IO.puts("  Pack.Reader FAILED: #{inspect(reason)}")
  end

  IO.puts("")

  # ── StreamParser ────────────────────────────────────────────────────────
  :erlang.garbage_collect()
  :timer.sleep(100)
  mem_before_stream = :erlang.memory(:total)

  {t_stream, stream_result} =
    :timer.tc(fn ->
      store = Memory.new()
      parser = StreamParser.new(store)

      # Feed in 64KB chunks to simulate network streaming.
      chunk_size = 64 * 1024

      result =
        File.stream!(path, chunk_size)
        |> Enum.reduce_while({:ok, parser}, fn chunk, {:ok, p} ->
          case StreamParser.ingest(p, chunk) do
            {:ok, p2} -> {:cont, {:ok, p2}}
            {:error, _} = err -> {:halt, err}
          end
        end)

      case result do
        {:ok, parser} -> StreamParser.finalize(parser)
        {:error, _} = err -> err
      end
    end)

  :erlang.garbage_collect()
  mem_after_stream = :erlang.memory(:total)

  case stream_result do
    {:ok, n, _store} ->
      IO.puts("  StreamParser")
      IO.puts("    time         : #{Fmt.us(t_stream)}")
      IO.puts("    objects      : #{n}")
      IO.puts("    heap growth  : #{Fmt.bytes(mem_after_stream - mem_before_stream)}")
      IO.puts("    growth/pack  : #{Float.round((mem_after_stream - mem_before_stream) / pack_size, 2)}×")

      if match?({:ok, objs}, reader_result) do
        {:ok, reader_objs} = reader_result
        speedup = Float.round(t_reader / t_stream, 2)
        mem_ratio =
          Float.round(
            (mem_after_stream - mem_before_stream) /
              (mem_after_reader - mem_before_reader),
            2
          )

        IO.puts("")
        IO.puts("  Comparison (vs Pack.Reader)")
        IO.puts("    time ratio   : #{speedup}× (>1 = StreamParser faster)")
        IO.puts("    memory ratio : #{mem_ratio}× (>1 = StreamParser uses more)")
        IO.puts("    objects match: #{length(reader_objs) == n}")
      end

    {:error, reason} ->
      IO.puts("  StreamParser FAILED: #{inspect(reason)}")
  end

  IO.puts("")
  end  # end if File.exists?
end

IO.puts("""
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
Notes
  Pack.Reader : loads full binary into heap, parses all at once
  StreamParser: 64KB chunks → inflate → streaming deflate write to Memory
                heap never holds full pack binary; peaks at O(max_object_size)
  Memory usage includes the store (all objects compressed), not just parse overhead
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
""")
