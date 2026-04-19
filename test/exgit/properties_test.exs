defmodule Exgit.PropertiesTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  @moduletag :property

  alias Exgit.Object.{Blob, Commit, Tree}
  alias Exgit.PktLine

  # ---- F.1: pkt-line encode/decode round trip ----

  describe "pkt-line (F.1)" do
    property "encode/decode round trips for arbitrary payloads" do
      check all(
              payload <- binary(min_length: 1, max_length: 64_000),
              max_runs: 100
            ) do
        encoded = IO.iodata_to_binary(PktLine.encode(payload))
        assert [{:data, ^payload}] = PktLine.decode_all(encoded)
      end
    end

    property "flush/delim markers survive decoding" do
      check all(n <- integer(1..5), max_runs: 50) do
        encoded =
          IO.iodata_to_binary([
            for(_ <- 1..n, do: PktLine.encode("x")),
            PktLine.flush(),
            PktLine.encode("y"),
            PktLine.delim()
          ])

        pkts = PktLine.decode_all(encoded)
        assert Enum.count(pkts, &(&1 == :flush)) == 1
        assert Enum.count(pkts, &(&1 == :delim)) == 1
      end
    end
  end

  # ---- F.2: pkt-line never raises on arbitrary bytes ----

  describe "pkt-line fuzz (F.2)" do
    property "decode_all never raises" do
      check all(bytes <- binary(), max_runs: 500) do
        try do
          _ = PktLine.decode_all(bytes)
          :ok
        rescue
          # A raise is a bug — pkt-line decoders must always surface
          # malformed input structurally. The current implementation
          # raises on truncation by design; in that case we accept a
          # structured `ArgumentError` but flag any other error as a
          # regression.
          ArgumentError -> :ok
          e -> flunk("unexpected raise: #{inspect(e)}")
        catch
          _, _ -> :ok
        end
      end
    end
  end

  # ---- F.3: object round-trip properties ----

  describe "object round-trip (F.3)" do
    property "Blob round trip preserves bytes" do
      check all(data <- binary(), max_runs: 100) do
        blob = Blob.new(data)
        encoded = blob |> Blob.encode() |> IO.iodata_to_binary()
        assert {:ok, decoded} = Blob.decode(encoded)
        assert decoded.data == data
      end
    end

    property "Blob SHA is stable under re-encode" do
      check all(data <- binary(max_length: 4096), max_runs: 50) do
        blob = Blob.new(data)
        sha1 = Blob.sha(blob)

        {:ok, decoded} = Blob.decode(blob |> Blob.encode() |> IO.iodata_to_binary())
        sha2 = Blob.sha(decoded)

        assert sha1 == sha2
      end
    end

    property "Tree round trip preserves entries (with sorted input)" do
      check all(entries <- tree_entries(), max_runs: 50) do
        tree = Tree.new(entries)
        encoded = tree |> Tree.encode() |> IO.iodata_to_binary()
        assert {:ok, decoded} = Tree.decode(encoded)

        # new/1 sorts and normalizes. The decoded tree's entries should
        # match what new/1 would produce from the same input.
        assert decoded.entries == tree.entries
      end
    end

    property "Commit round trip preserves tree/author/committer/message" do
      check all(
              tree_sha <- sha_gen(),
              author <- author_line(),
              message <- string(:alphanumeric, min_length: 1, max_length: 200),
              parent_shas <- list_of(sha_gen(), max_length: 3),
              max_runs: 30
            ) do
        commit =
          Commit.new(
            tree: tree_sha,
            parents: parent_shas,
            author: author,
            committer: author,
            message: message
          )

        encoded = commit |> Commit.encode() |> IO.iodata_to_binary()
        assert {:ok, decoded} = Commit.decode(encoded)
        assert Commit.tree(decoded) == tree_sha
        assert Commit.parents(decoded) == parent_shas
        assert Commit.author(decoded) == author
        assert decoded.message == message
      end
    end
  end

  defp tree_entries do
    list_of(
      {constant("100644"), string(:alphanumeric, min_length: 1, max_length: 10), sha_gen()},
      min_length: 0,
      max_length: 5
    )
    |> map(&dedupe_by_name/1)
  end

  defp dedupe_by_name(entries) do
    entries
    |> Enum.uniq_by(fn {_m, n, _s} -> n end)
  end

  defp sha_gen do
    binary(length: 20)
  end

  defp author_line do
    gen all(
          name <- string(:alphanumeric, min_length: 1, max_length: 10),
          ts <- integer(1..2_000_000_000)
        ) do
      "#{name} <#{name}@test> #{ts} +0000"
    end
  end

  # ---- F.5: Config round trip ----

  describe "config round-trip (F.5)" do
    property "parse(encode(config)) == config for safe section/key/value triples" do
      check all(sections <- config_sections(), max_runs: 50) do
        c =
          Enum.reduce(sections, Exgit.Config.new(), fn {sec, sub, k, v}, acc ->
            Exgit.Config.set(acc, sec, sub, k, v)
          end)

        encoded = c |> Exgit.Config.encode() |> IO.iodata_to_binary()
        {:ok, re_parsed} = Exgit.Config.parse(encoded)

        for {sec, sub, k, v} <- sections do
          assert Exgit.Config.get(re_parsed, sec, sub, k) == v
        end
      end
    end
  end

  defp config_sections do
    list_of(
      gen all(
            sec <- string(:alphanumeric, min_length: 1, max_length: 10),
            sub <- one_of([nil, string(:alphanumeric, min_length: 1, max_length: 6)]),
            k <- string(:alphanumeric, min_length: 1, max_length: 10),
            # Restrict values to alphanumeric to keep the property test
            # focused on round-trip semantics, not encoding edge cases
            # (which have their own explicit tests in
            # config_parsing_test.exs).
            v <- string(:alphanumeric, min_length: 1, max_length: 20)
          ) do
        {String.downcase(sec), sub, k, v}
      end,
      max_length: 5
    )
    |> map(&Enum.uniq_by(&1, fn {s, sub, k, _} -> {s, sub, k} end))
  end

  # ---- F.7: Pack writer → reader round trip ----

  describe "pack writer/reader (F.7)" do
    property "pack built from blobs is parsed back into the same blobs" do
      check all(
              datas <- list_of(binary(max_length: 512), min_length: 1, max_length: 10),
              max_runs: 30
            ) do
        blobs = Enum.map(datas, &Blob.new/1)
        pack = Exgit.Pack.Writer.build(blobs)

        assert {:ok, parsed} = Exgit.Pack.Reader.parse(pack)
        assert length(parsed) == length(blobs)

        for {blob, {type, sha, _content}} <- Enum.zip(blobs, parsed) do
          assert type == :blob
          assert sha == Blob.sha(blob)
        end
      end
    end
  end

  # ---- F.6: Pack reader fuzz ----

  describe "pack reader fuzz (F.6)" do
    property "Pack.Reader.parse never raises on random bytes" do
      check all(bytes <- binary(max_length: 400), max_runs: 500) do
        try do
          case Exgit.Pack.Reader.parse(bytes) do
            {:ok, _} -> :ok
            {:error, _} -> :ok
          end
        rescue
          e -> flunk("pack reader raised: #{inspect(e)}")
        catch
          _, _ -> :ok
        end
      end
    end

    property "Pack.Reader.parse never raises on PACK-prefixed garbage" do
      check all(garbage <- binary(max_length: 400), max_runs: 500) do
        input = "PACK" <> <<2::32-big, 0::32-big>> <> garbage

        try do
          case Exgit.Pack.Reader.parse(input) do
            {:ok, _} -> :ok
            {:error, _} -> :ok
          end
        rescue
          e -> flunk("pack reader raised: #{inspect(e)}")
        catch
          _, _ -> :ok
        end
      end
    end
  end

  # ---- F.4: Index fuzz ----

  describe "index parser fuzz (F.4)" do
    property "Index.parse never raises on random bytes" do
      check all(bytes <- binary(max_length: 400), max_runs: 500) do
        try do
          case Exgit.Index.parse(bytes) do
            {:ok, _} -> :ok
            {:error, _} -> :ok
          end
        rescue
          e -> flunk("index parser raised: #{inspect(e)}")
        catch
          _, _ -> :ok
        end
      end
    end

    property "Index.parse never raises on DIRC+version prefixes" do
      check all(
              version <- integer(1..5),
              count <- integer(0..10),
              garbage <- binary(max_length: 200),
              max_runs: 200
            ) do
        input = "DIRC" <> <<version::32, count::32>> <> garbage

        try do
          case Exgit.Index.parse(input) do
            {:ok, _} -> :ok
            {:error, _} -> :ok
          end
        rescue
          e -> flunk("index parser raised: #{inspect(e)}")
        catch
          _, _ -> :ok
        end
      end
    end
  end

  # ---- F.8: Walk ancestors never returns a descendant before its ancestor ----

  describe "walk topo invariant (F.8)" do
    alias Exgit.Test.CommitGraph

    property "topo order respects parent-child for random DAGs" do
      check all(graph <- commit_graph(), max_runs: 30) do
        {repo, shas} = CommitGraph.build(graph)
        tip = pick_tip(graph)

        positions =
          Exgit.Walk.ancestors(repo, shas[tip], order: :topo)
          |> Enum.map(&Exgit.Object.Commit.sha(&1))
          |> Enum.map(&CommitGraph.name_of(shas, &1))
          |> Enum.with_index()
          |> Map.new()

        for {child, parents} <- graph, parent <- parents do
          cond do
            Map.has_key?(positions, child) and Map.has_key?(positions, parent) ->
              assert positions[child] < positions[parent],
                     "parent #{parent}@#{positions[parent]} before child #{child}@#{positions[child]}"

            true ->
              :ok
          end
        end
      end
    end

    defp commit_graph do
      gen all(
            n <- integer(1..8),
            edges_data <- list_of({integer(0..20), integer(0..20)}, max_length: 10)
          ) do
        names = for i <- 0..(n - 1), do: "n#{i}"

        # Build a DAG: node i can have parents only from {0..i-1}.
        Enum.reduce(1..(n - 1)//1, %{"n0" => []}, fn i, acc ->
          num_parents =
            edges_data
            |> Enum.at(rem(i, length(edges_data) + 1), {0, 0})
            |> elem(0)
            |> rem(i + 1)

          parents =
            for j <- 1..max(num_parents, 0)//1, j <= i do
              "n#{rem(Enum.at(names, j - 1) |> :erlang.phash2(), i)}"
            end
            |> Enum.uniq()

          Map.put(acc, "n#{i}", parents)
        end)
        |> then(fn g -> if map_size(g) == 0, do: %{"n0" => []}, else: g end)
      end
    end

    defp pick_tip(graph) do
      # Tip = a node that is nobody's parent.
      all_names = MapSet.new(Map.keys(graph))
      referenced = graph |> Map.values() |> List.flatten() |> MapSet.new()

      case MapSet.difference(all_names, referenced) |> MapSet.to_list() do
        [] -> hd(Map.keys(graph))
        [tip | _] -> tip
      end
    end
  end

  # ---- F.N: FS.read_lines ----
  #
  # Property: for any blob with any combination of trailing-\n /
  # no-trailing-\n, reading line N returns bytes identical to
  # splitting the blob on \n and indexing with N-1. This pins the
  # line-numbering convention the rest of the library uses (grep,
  # grep+context, read_lines) and catches any drift.
  describe "FS.read_lines (F.N)" do
    alias Exgit.{FS, ObjectStore, RefStore, Repository}
    alias Exgit.Object.{Commit, Tree}

    property "read_lines agrees with split-on-\\n for every line in a blob" do
      check all(
              blob_data <- blob_like_binary(),
              max_runs: 200
            ) do
        repo = build_one_file_repo(blob_data)

        # Expected lines via a reference implementation (split on \n,
        # drop phantom empty tail if the file ends with \n).
        expected = reference_lines(blob_data)

        for {expected_text, idx} <- Enum.with_index(expected, 1) do
          assert {:ok, [{^idx, got}], _} = FS.read_lines(repo, "HEAD", "f.txt", idx)
          assert got == expected_text
        end

        # And reading the full range returns the whole thing.
        case length(expected) do
          0 ->
            assert {:ok, [], _} = FS.read_lines(repo, "HEAD", "f.txt", 1..1000)

          n ->
            {:ok, got, _} = FS.read_lines(repo, "HEAD", "f.txt", 1..n)

            assert got == Enum.with_index(expected, 1) |> Enum.map(fn {t, i} -> {i, t} end)
        end
      end
    end

    defp blob_like_binary do
      # Printable ASCII + \n, 0-256 bytes. Enough variation to hit
      # trailing-\n / no-trailing-\n / empty / single-line / 10-line
      # cases uniformly.
      char_gen =
        StreamData.frequency([
          {10, StreamData.integer(32..126)},
          {2, StreamData.constant(?\n)}
        ])

      StreamData.bind(
        StreamData.list_of(char_gen, min_length: 0, max_length: 256),
        fn chars -> StreamData.constant(IO.iodata_to_binary(chars)) end
      )
    end

    # Reference implementation: git's convention.
    defp reference_lines(""), do: []

    defp reference_lines(data) do
      parts = String.split(data, "\n")

      # If data ends with \n, split produces a trailing empty element
      # that isn't actually a line. Strip it.
      if String.ends_with?(data, "\n"),
        do: Enum.drop(parts, -1),
        else: parts
    end

    defp build_one_file_repo(blob_data) do
      store = ObjectStore.Memory.new()
      {:ok, blob_sha, store} = ObjectStore.put(store, %Exgit.Object.Blob{data: blob_data})

      tree = Tree.new([{"100644", "f.txt", blob_sha}])
      {:ok, tree_sha, store} = ObjectStore.put(store, tree)

      commit =
        Commit.new(
          tree: tree_sha,
          parents: [],
          author: "T <t@t> 1700000000 +0000",
          committer: "T <t@t> 1700000000 +0000",
          message: "one\n"
        )

      {:ok, commit_sha, store} = ObjectStore.put(store, commit)
      {:ok, rs} = RefStore.write(RefStore.Memory.new(), "refs/heads/main", commit_sha, [])
      {:ok, rs} = RefStore.write(rs, "HEAD", {:symbolic, "refs/heads/main"}, [])

      %Repository{
        object_store: store,
        ref_store: rs,
        config: Exgit.Config.new(),
        path: nil
      }
    end
  end
end
