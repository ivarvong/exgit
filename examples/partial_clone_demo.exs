# Partial clone, worked example.
#
# Clones a public repo under a `blob:none` filter — the server ships
# refs + commits + trees but NO file contents — then reads one file.
# The `blob_count: 0 -> 1` transition around the read is the proof
# that exactly one blob crossed the wire.
#
# Run with:  elixir examples/partial_clone_demo.exs

Mix.install([{:exgit, "~> 0.1.0"}])

stats = fn repo ->
  Exgit.Repository.memory_report(repo) |> Map.take([:blob_count, :tree_count, :cache_bytes])
end

# Partial clone: refs + commits + trees cross the wire. No file contents.
{:ok, repo} = Exgit.clone("https://github.com/elixir-ai-tools/just_bash", filter: {:blob, :none})
IO.inspect(stats.(repo), label: "after clone   ")

# The size probe refuses to fetch — gate on it before pulling big files.
{:error, :not_local} = Exgit.FS.size(repo, "HEAD", "README.md")

# Reading ONE file fetches ONE blob.
{:ok, {_mode, blob}, repo} = Exgit.FS.read_path(repo, "HEAD", "README.md")
first_line = blob.data |> String.split("\n", parts: 2) |> hd()
IO.puts(~s(read README.md:  #{byte_size(blob.data)} bytes — "#{first_line}"))
IO.inspect(stats.(repo), label: "after one read")

# Navigation stays free: directory listings come from the local
# trees, so blob_count doesn't move.
{:ok, entries, repo} = Exgit.FS.ls(repo, "HEAD", "")
IO.puts("ls /:  #{length(entries)} entries — blob_count still #{stats.(repo).blob_count}")
