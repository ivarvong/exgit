defmodule Exgit do
  alias Exgit.{Repository, Config, ObjectStore, RefStore, Pack, Transport}

  @spec init(keyword()) :: {:ok, Repository.t()} | {:error, term()}
  def init(opts \\ []) do
    case Keyword.get(opts, :path) do
      nil -> {:ok, Repository.new(ObjectStore.Memory.new(), RefStore.Memory.new())}
      path -> init_disk(path)
    end
  end

  @spec open(Path.t(), keyword()) :: {:ok, Repository.t()} | {:error, term()}
  def open(path, _opts \\ []) do
    head_path = Path.join(path, "HEAD")
    objects_path = Path.join(path, "objects")

    cond do
      not File.exists?(head_path) ->
        {:error, {:not_a_repository, "missing HEAD"}}

      not File.dir?(objects_path) ->
        {:error, {:not_a_repository, "missing objects directory"}}

      true ->
        config =
          case Config.read(Path.join(path, "config")) do
            {:ok, c} -> c
            {:error, _} -> Config.new()
          end

        {:ok,
         Repository.new(
           ObjectStore.Disk.new(path),
           RefStore.Disk.new(path),
           config: config,
           path: path
         )}
    end
  end

  @doc """
  Clone a git repository.

      {:ok, repo} = Exgit.clone("https://github.com/user/repo")

  ## Options

    * `:path` — persistent on-disk clone. When set, the clone is
      backed by `ObjectStore.Disk`/`RefStore.Disk` and survives
      process death. Default: in-memory (lost on process exit).

    * `:lazy` — when `true`, defer object fetching. Returns a
      `%Repository{mode: :lazy}` whose object store is an
      `ObjectStore.Promisor` that fetches on demand. The initial
      clone pulls **refs only** — any subsequent object read
      triggers a `want <sha>` fetch against the transport. Great
      for agent loops that read a handful of files from large
      repos. Default: `false` (full clone).

    * `:filter` — partial-clone filter spec. Valid values:
      `{:blob, :none}`, `{:blob, {:limit, bytes}}`,
      `{:tree, depth}`, `{:raw, "filter=..."}`. When set, the
      server ships a pack that omits blobs (or trees) matching
      the filter; omitted objects are fetched on demand. Implies
      `:lazy`-like semantics for omitted objects but keeps the
      default branch's commit+tree history resident.

    * `:if_unsupported` — `:error` (default) or `:ignore`. When
      `:filter` is set but the server doesn't advertise `filter`
      capability, `:error` fails the clone and `:ignore` proceeds
      as a full clone.

    * `:remote` — remote name to record. Default: `"origin"`.

  ## Matrix of modes

  | Options | Clone-time fetch | On read |
  |---|---|---|
  | `clone(url)` | refs + all objects | local always |
  | `clone(url, lazy: true)` | refs only | per-object fetch |
  | `clone(url, filter: {:blob, :none})` | refs + commits + trees | blobs fetched on read |
  | `clone(url, filter: ..., lazy: true)` | refs only | everything on read |

  ## `:path` + `:lazy` / `:filter`

  On-disk partial clones are not yet supported; `:path` combined
  with `:lazy` or `:filter` returns
  `{:error, :disk_partial_clone_unsupported}`.

  ## Returns

  `{:ok, %Repository{}}` with `:mode => :eager` for full clones
  and `:mode => :lazy` for any form of partial/lazy clone. Use
  `Exgit.Repository.materialize/2` to convert `:lazy` → `:eager`
  after reading what you need.
  """
  @spec clone(String.t() | Transport.File.t() | Transport.HTTP.t(), keyword()) ::
          {:ok, Repository.t()} | {:error, term()}
  def clone(source, opts \\ []) do
    cond do
      disk_partial_clone?(opts) ->
        {:error, :disk_partial_clone_unsupported}

      Keyword.get(opts, :lazy, false) or Keyword.has_key?(opts, :filter) ->
        clone_partial(source, opts)

      true ->
        clone_full(source, opts)
    end
  end

  defp disk_partial_clone?(opts) do
    Keyword.has_key?(opts, :path) and
      (Keyword.get(opts, :lazy, false) or Keyword.has_key?(opts, :filter))
  end

  # Full (eager) clone: pull every reachable object up front, populate
  # a Memory or Disk object store, return an `:eager` repo.
  defp clone_full(source, opts) do
    transport = to_transport(source, opts)

    with {:ok, repo} <- init(opts),
         # Asking for `HEAD` as a ref-prefix pulls the server's HEAD
         # line into the ls-refs output, complete with a symref-target
         # attribute — so we pick the server's actual default branch
         # instead of guessing from the advertised refs.
         {:ok, refs, meta} <-
           safe_ls_refs(transport, prefix: ["HEAD", "refs/heads/", "refs/tags/"]),
         {:ok, repo} <- fetch_into(repo, transport, refs, opts),
         {:ok, repo} <- set_head_to_default(repo, refs, meta) do
      {:ok, repo}
    end
  end

  # Partial / lazy clone: return an `:lazy` repo with a Promisor
  # object store. Triggered by `:lazy` or `:filter` opts.
  defp clone_partial(source, opts) do
    transport = to_transport(source, opts)

    with {:ok, filter_spec} <- resolve_filter(opts),
         :ok <- check_filter_capability(transport, filter_spec, opts),
         {:ok, refs, meta} <-
           safe_ls_refs(transport, prefix: ["HEAD", "refs/heads/", "refs/tags/"]) do
      promisor =
        ObjectStore.Promisor.new(transport,
          default_fetch_opts: promisor_fetch_opts(filter_spec)
        )

      ref_store =
        Enum.reduce(refs, RefStore.Memory.new(), fn {name, sha}, rs ->
          case RefStore.write(rs, name, sha, []) do
            {:ok, rs2} ->
              rs2

            {:error, reason} ->
              # Memory-backed stores shouldn't fail a write, but
              # if they do we at least surface the fact via
              # telemetry so a lazy-cloned repo that's missing
              # refs isn't a silent mystery.
              :telemetry.execute(
                [:exgit, :ref_store, :write_failed],
                %{count: 1},
                %{ref: name, reason: reason, context: :clone_partial}
              )

              rs
          end
        end)

      repo = Repository.new(promisor, ref_store, mode: :lazy)

      with {:ok, repo} <- set_head_to_default(repo, refs, meta),
           {:ok, repo} <- maybe_eager_prefetch(repo, refs, meta, filter_spec) do
        {:ok, repo}
      end
    end
  end

  # All ref reads from a transport MUST go through this wrapper. Ref
  # names from the wire are hostile input; see Exgit.RefName for the
  # validation rules and `[:exgit, :security, :ref_rejected]` telemetry.
  #
  # Transports are responsible for applying `Exgit.RefName.valid?/1`
  # to their output; this wrapper applies the check again as
  # defense-in-depth for third-party transports that forgot. The
  # return shape mirrors `Transport.ls_refs/2` exactly:
  # `{:ok, refs, meta}`.
  defp safe_ls_refs(transport, opts) do
    case Transport.ls_refs(transport, opts) do
      {:ok, refs, meta} ->
        {:ok, Enum.filter(refs, &keep_ref?(&1, transport)), meta}

      other ->
        other
    end
  end

  defp keep_ref?({ref, _sha}, transport) do
    if Exgit.RefName.valid?(ref) do
      true
    else
      :telemetry.execute(
        [:exgit, :security, :ref_rejected],
        %{count: 1},
        %{source: describe_transport(transport), ref: ref}
      )

      false
    end
  end

  defp describe_transport(%{url: url}), do: url
  defp describe_transport(%{path: path}), do: path
  defp describe_transport(other), do: inspect(other.__struct__)

  # Translate a user-facing filter option into a wire string (or :none).
  defp resolve_filter(opts) do
    case Keyword.get(opts, :filter, :none) do
      :none ->
        {:ok, :none}

      spec ->
        case Exgit.Filter.encode(spec) do
          :none -> {:ok, :none}
          {:ok, wire} -> {:ok, wire}
          {:error, _} = err -> err
        end
    end
  end

  # Probe the server's advertised fetch capabilities for "filter" support.
  # When the user asked for a filter but the server doesn't support it,
  # error unless `if_unsupported: :ignore` is set.
  defp check_filter_capability(_transport, :none, _opts), do: :ok

  defp check_filter_capability(transport, _wire, opts) do
    case Transport.capabilities(transport) do
      {:ok, caps} ->
        fetch_caps = String.split(Map.get(caps, "fetch", ""), " ", trim: true)

        cond do
          "filter" in fetch_caps ->
            :ok

          Keyword.get(opts, :if_unsupported) == :ignore ->
            :ok

          true ->
            {:error, {:filter_unsupported, fetch_caps}}
        end

      _ ->
        :ok
    end
  end

  # Options the Promisor should send with every on-demand fetch. Blobs
  # that come back because of a follow-up `want <blob_sha>` shouldn't
  # themselves be filtered; leave the filter off the per-object fetch.
  defp promisor_fetch_opts(:none), do: []
  defp promisor_fetch_opts(_wire), do: []

  # When a filter is in effect, pull the commits+trees pack eagerly at
  # clone time. Without a filter, a lazy clone stays fast (refs only).
  defp maybe_eager_prefetch(repo, _refs, _meta, :none), do: {:ok, repo}

  defp maybe_eager_prefetch(repo, refs, meta, wire) do
    case find_default_ref(refs, meta) do
      nil ->
        {:ok, repo}

      {_name, commit_sha} ->
        # Promisor.fetch_with_filter/3 triggers the tree-only fetch and
        # imports everything into the cache.
        case ObjectStore.Promisor.fetch_with_filter(repo.object_store, [commit_sha], filter: wire) do
          {:ok, new_store} ->
            {:ok, %{repo | object_store: new_store}}

          {:error, _} = err ->
            err
        end
    end
  end

  defp set_head_to_default(repo, refs, meta) do
    case find_default_ref(refs, meta) do
      nil ->
        {:ok, repo}

      {ref_name, sha} ->
        with {:ok, ref_store} <-
               RefStore.write(repo.ref_store, "HEAD", {:symbolic, ref_name}, []),
             {:ok, ref_store} <- RefStore.write(ref_store, ref_name, sha, []) do
          {:ok, %{repo | ref_store: ref_store}}
        end
    end
  end

  @spec fetch(Repository.t(), String.t() | term(), keyword()) ::
          {:ok, Repository.t()} | {:error, term()}
  def fetch(%Repository{} = repo, source, opts \\ []) do
    transport = to_transport(source, opts)
    remote_name = Keyword.get(opts, :remote, "origin")
    prefix = Keyword.get(opts, :prefix, ["refs/heads/", "refs/tags/"])

    with {:ok, refs, _meta} <- safe_ls_refs(transport, prefix: prefix) do
      fetch_into(repo, transport, refs, Keyword.put(opts, :remote, remote_name))
    end
  end

  @doc """
  Push local refs to a remote.

  The `:refspecs` keyword takes a list where each entry is one of:

    * `"refs/heads/main"` — a ref name; pushes the local sha for that
      ref to the same name on the remote (creating it if absent).
    * `{:delete, "refs/heads/branch"}` — delete the ref on the remote.

  Returns `{:ok, %{ref_results: [...]}}` on success.
  """
  @spec push(Repository.t(), String.t() | term(), keyword()) ::
          {:ok, map()} | {:error, term()}
  def push(%Repository{} = repo, dest, opts \\ []) do
    transport = to_transport(dest, opts)
    refspecs = Keyword.get(opts, :refspecs, ["refs/heads/main"])

    # When looking up remote refs we only care about the ref NAMES
    # (not the delete markers).
    ref_names =
      for rs <- refspecs do
        case rs do
          {:delete, name} -> name
          name when is_binary(name) -> name
        end
      end

    remote_refs =
      case safe_ls_refs(transport, prefix: ref_names) do
        {:ok, refs, _meta} -> Map.new(refs)
        _ -> %{}
      end

    {updates, objects} =
      Enum.reduce(refspecs, {[], []}, fn refspec, {upd, objs} ->
        case plan_push(refspec, repo, remote_refs) do
          {:update, ref_name, old_sha, new_sha, sha_for_objects} ->
            new_objs =
              if sha_for_objects,
                do: collect_push_objects(repo.object_store, sha_for_objects, remote_refs),
                else: []

            {[{ref_name, old_sha, new_sha} | upd], objs ++ new_objs}

          :skip ->
            {upd, objs}
        end
      end)

    if updates == [] do
      {:ok, %{ref_results: []}}
    else
      # A receive-pack request body ends with the pkt-line flush
      # followed by the pack bytes. An empty-objects list is legal
      # for:
      #
      #   (a) pure ref-delete pushes — no new objects needed
      #   (b) pure ref-move pushes where every commit referenced is
      #       already present on the remote (e.g. fast-forward to a
      #       commit the remote learned about via another branch)
      #
      # Most git servers accept an empty body after the flush in
      # case (a), but some reject a completely-missing PACK header
      # in case (b). Emit an empty PACK (header + 0 objects + SHA
      # trailer) when we have updates that aren't all deletes — this
      # is the shape `git send-pack` produces for the same case and
      # is accepted by every modern server we've tested.
      pack =
        cond do
          objects != [] -> Pack.Writer.build(objects)
          all_deletes?(updates) -> <<>>
          true -> Pack.Writer.build([])
        end

      Transport.push(transport, Enum.reverse(updates), pack, [])
    end
  end

  defp all_deletes?(updates), do: Enum.all?(updates, fn {_ref, _old, new} -> new == nil end)

  # Translate one user-supplied refspec entry into a concrete update.
  defp plan_push({:delete, ref_name}, _repo, remote_refs) when is_binary(ref_name) do
    case Map.fetch(remote_refs, ref_name) do
      {:ok, old_sha} -> {:update, ref_name, old_sha, nil, nil}
      # Nothing to delete; silently skip so deleting a missing ref is a
      # no-op rather than an error.
      :error -> :skip
    end
  end

  defp plan_push(ref_name, repo, remote_refs) when is_binary(ref_name) do
    case RefStore.resolve(repo.ref_store, ref_name) do
      {:ok, sha} ->
        old_sha = Map.get(remote_refs, ref_name)
        {:update, ref_name, old_sha, sha, sha}

      _ ->
        :skip
    end
  end

  # --- Internal ---

  # Accepts any struct that implements the Exgit.Transport protocol, or a
  # URL string that we can map to the built-in File/HTTP transports.
  defp to_transport(url, opts) when is_binary(url) do
    if String.starts_with?(url, "file://") do
      path = String.trim_leading(url, "file://")
      Transport.File.new(path)
    else
      Transport.HTTP.new(url, opts)
    end
  end

  defp to_transport(transport, _opts) when is_struct(transport) do
    # Any struct implementing the Transport protocol is fine as-is.
    transport
  end

  defp init_disk(path) do
    with :ok <- File.mkdir_p(path),
         :ok <- File.mkdir_p(Path.join(path, "objects")),
         :ok <- File.mkdir_p(Path.join(path, "objects/info")),
         :ok <- File.mkdir_p(Path.join(path, "objects/pack")),
         :ok <- File.mkdir_p(Path.join(path, "refs")),
         :ok <- File.mkdir_p(Path.join(path, "refs/heads")),
         :ok <- File.mkdir_p(Path.join(path, "refs/tags")),
         :ok <- File.write(Path.join(path, "HEAD"), "ref: refs/heads/main\n"),
         config <- bare_config(),
         :ok <- Config.write(config, Path.join(path, "config")) do
      {:ok,
       Repository.new(
         ObjectStore.Disk.new(path),
         RefStore.Disk.new(path),
         config: config,
         path: path
       )}
    end
  end

  defp fetch_into(repo, transport, refs, opts) do
    remote_name = Keyword.get(opts, :remote, "origin")
    wants = for {_ref, sha} <- refs, sha != nil, do: sha
    wants = Enum.uniq(wants)

    if wants == [] do
      {:ok, repo}
    else
      case Transport.fetch(transport, wants, opts) do
        {:ok, pack_data, _summary} when byte_size(pack_data) > 0 ->
          with {:ok, repo} <- unpack_into(repo, pack_data),
               {:ok, repo} <- update_remote_refs(repo, refs, remote_name) do
            {:ok, repo}
          end

        {:ok, _, _} ->
          {:ok, repo}

        error ->
          error
      end
    end
  end

  defp unpack_into(repo, pack_data) do
    case Pack.Reader.parse(pack_data) do
      {:ok, objects} ->
        {:ok, object_store} = ObjectStore.import_objects(repo.object_store, objects)
        {:ok, %{repo | object_store: object_store}}

      error ->
        error
    end
  end

  defp update_remote_refs(repo, refs, remote_name) do
    ref_store =
      Enum.reduce(refs, repo.ref_store, fn {ref, sha}, ref_store ->
        if sha == nil do
          ref_store
        else
          remote_ref =
            cond do
              String.starts_with?(ref, "refs/heads/") ->
                branch = String.trim_leading(ref, "refs/heads/")
                "refs/remotes/#{remote_name}/#{branch}"

              String.starts_with?(ref, "refs/tags/") ->
                ref

              true ->
                nil
            end

          if remote_ref do
            case RefStore.write(ref_store, remote_ref, sha, []) do
              {:ok, rs} ->
                rs

              # Preserve previous store on write failure; propagate err via
              # reduce? Keeping the reduce-to-store structure means we
              # silently skip failed writes. That mirrors real-world git
              # which treats remote-ref writes as best-effort — but we log.
              {:error, reason} ->
                :logger.warning(
                  "exgit: failed to write remote ref #{remote_ref}: #{inspect(reason)}"
                )

                ref_store
            end
          else
            ref_store
          end
        end
      end)

    {:ok, %{repo | ref_store: ref_store}}
  end

  # Pick the default ref to point HEAD at. Prefer the server's own
  # HEAD symref target (surfaced via `meta.head` from the
  # protocol-v2 `symrefs` argument). Falls back to
  # `refs/heads/main` / `refs/heads/master` / any `refs/heads/*`
  # only when the server didn't advertise HEAD's target.
  # Previously we always guessed — that meant consecutive clones of
  # a repo whose default was neither `main` nor `master` could land
  # on different branches depending on wire-order.
  defp find_default_ref(refs, meta) do
    case Map.get(meta, :head) do
      nil ->
        fallback_default_ref(refs)

      target ->
        case Enum.find(refs, fn {ref, _} -> ref == target end) do
          nil -> fallback_default_ref(refs)
          entry -> entry
        end
    end
  end

  defp fallback_default_ref(refs) do
    heads =
      Enum.filter(refs, fn {ref, _} -> String.starts_with?(ref, "refs/heads/") end)

    Enum.find(heads, fn {ref, _} -> ref == "refs/heads/main" end) ||
      Enum.find(heads, fn {ref, _} -> ref == "refs/heads/master" end) ||
      List.first(heads)
  end

  defp collect_push_objects(store, sha, remote_refs) do
    remote_shas = MapSet.new(Map.values(remote_refs))
    collect_reachable(store, [sha], remote_shas)
  end

  # Iterative (non-recursive) reachability walk. Uses a single shared
  # `seen` accumulator so shared subtrees are visited exactly once, and
  # is bounded by O(heap) rather than O(stack) so it handles deep
  # histories (millions of commits) without stack overflow.
  defp collect_reachable(store, initial_shas, seen) do
    do_collect_reachable(store, initial_shas, seen, [])
  end

  defp do_collect_reachable(_store, [], _seen, acc), do: Enum.reverse(acc)

  defp do_collect_reachable(store, [sha | rest], seen, acc) do
    if MapSet.member?(seen, sha) do
      do_collect_reachable(store, rest, seen, acc)
    else
      seen = MapSet.put(seen, sha)

      case ObjectStore.get(store, sha) do
        {:ok, obj} ->
          children = object_children(obj)
          do_collect_reachable(store, children ++ rest, seen, [obj | acc])

        _ ->
          do_collect_reachable(store, rest, seen, acc)
      end
    end
  end

  defp object_children(%Exgit.Object.Commit{} = c),
    do: [Exgit.Object.Commit.tree(c) | Exgit.Object.Commit.parents(c)]

  defp object_children(%Exgit.Object.Tree{entries: entries}), do: Enum.map(entries, &elem(&1, 2))
  defp object_children(%Exgit.Object.Tag{object: sha}), do: [sha]
  defp object_children(%Exgit.Object.Blob{}), do: []

  defp bare_config do
    Config.new()
    |> Config.set("core", nil, "repositoryformatversion", "0")
    |> Config.set("core", nil, "filemode", "true")
    |> Config.set("core", nil, "bare", "true")
  end
end
