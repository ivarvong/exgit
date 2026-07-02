# Partial clone, worked example.
#
# Clones a public repo under a `blob:none` filter — the server ships
# refs + commits + trees but NO file contents — then reads one file
# and proves, via `Exgit.Repository.memory_report/1`, that exactly
# one blob was pulled over the network.
#
# Run with:  elixir examples/partial_clone_demo.exs

Mix.install([{:exgit, "~> 0.1.0"}])

url = "https://github.com/elixir-ai-tools/just_bash"
path = "README.md"

fmt = fn n -> n |> Integer.to_string() |> String.replace(~r/(\d)(?=(\d{3})+$)/, "\\1,") end

report = fn label, r ->
  IO.puts(
    "  #{String.pad_trailing(label, 24)} " <>
      "objects: #{String.pad_leading(fmt.(r.object_count), 6)}   " <>
      "blobs: #{String.pad_leading(fmt.(r.blob_count), 6)}   " <>
      "trees: #{String.pad_leading(fmt.(r.tree_count), 4)}   " <>
      "cache: #{String.pad_leading(fmt.(r.cache_bytes), 9)} B"
  )
end

# ── 1. Partial clone: no blobs cross the wire ──────────────────────
{:ok, repo} = Exgit.clone(url, filter: {:blob, :none})
IO.puts("\nPartial clone (blob:none) of #{url}:")
report.("after clone", Exgit.Repository.memory_report(repo))

# ── 2. Size probe: answered without fetching ───────────────────────
# The blob isn't local and size/3 refuses to trigger a fetch for it.
{:error, :not_local} = Exgit.FS.size(repo, "HEAD", path)
IO.puts("\n  FS.size(#{inspect(path)}) -> {:error, :not_local}  (no fetch triggered)")

# ── 3. Read ONE file: exactly one blob is fetched ───────────────────
{:ok, {_mode, blob}, repo} = Exgit.FS.read_path(repo, "HEAD", path)
first_line = blob.data |> String.split("\n", parts: 2) |> hd()

IO.puts(
  "  FS.read_path(#{inspect(path)}) -> #{byte_size(blob.data)} bytes: #{inspect(first_line)}"
)

# Now it's cached: size answers in O(1), still nothing new fetched.
{:ok, size, repo} = Exgit.FS.size(repo, "HEAD", path)
IO.puts("  FS.size(#{inspect(path)}) -> {:ok, #{size}}  (from cache)\n")

report.("after reading one file", Exgit.Repository.memory_report(repo))

# ── 4. The comparison: what a full clone hauls in ───────────────────
{:ok, eager} = Exgit.clone(url)
full = Exgit.Repository.memory_report(eager)
file_count = Exgit.FS.walk(eager, "HEAD") |> Enum.count()

IO.puts("\nEager clone of the same repo (#{fmt.(file_count)} files at HEAD):")
report.("full object graph", full)

partial = Exgit.Repository.memory_report(repo)

IO.puts("""

The partial clone fetched #{fmt.(partial.blob_count)} of #{fmt.(full.blob_count)} blobs \
(#{fmt.(partial.cache_bytes)} of #{fmt.(full.cache_bytes)} compressed bytes) \
to read #{inspect(path)}.
""")
