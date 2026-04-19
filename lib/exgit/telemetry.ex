defmodule Exgit.Telemetry do
  @moduledoc """
  Telemetry event names and conventions for exgit.

  ## SemVer

  This module — including the event names and the metadata key sets
  documented below — is part of exgit's **public API** under SemVer.
  A major-version bump is required to rename an event or remove a
  documented metadata key. New metadata keys may be added in any
  release.

  ## Span convention

  All events follow the [`:telemetry.span/3`](https://hexdocs.pm/telemetry/)
  convention, so each logical operation emits three events:

    * `[..., :start]` — measurements: `%{system_time, monotonic_time}`
    * `[..., :stop]`  — measurements: `%{duration, monotonic_time}`
    * `[..., :exception]` — when the operation raised

  The `duration` is in `:native` time units — convert with
  `System.convert_time_unit(duration, :native, :microsecond)`.

  Consumers attach to these events via `:telemetry.attach/4`. Dev/test
  environments can bridge to OpenTelemetry via `opentelemetry_telemetry`;
  see `test/support/otel_console.ex` for an example.

  ## Event catalogue

  ### Transport

    * `[:exgit, :transport, :fetch]` — `%{transport, url, wants_count,
      result_bytes, object_count}`
    * `[:exgit, :transport, :ls_refs]` — `%{transport, url, ref_count}`
    * `[:exgit, :transport, :push]` — `%{transport, url, update_count,
      pack_bytes}`

  ### Object store

    * `[:exgit, :object_store, :get]` — `%{store, sha, hit?}`
      - `hit?: true` when a `Promisor`-backed store served from cache
      - `hit?: false` when it had to go to the network
      - omitted for stores that don't track this distinction
    * `[:exgit, :object_store, :put]` — `%{store, sha}`
    * `[:exgit, :object_store, :has?]` — `%{store, sha, present?}`
    * `[:exgit, :object_store, :fetch_and_cache]` — `%{sha,
      object_count, cache_bytes}` (stop event only)
    * `[:exgit, :object_store, :haves_sent]` — standalone
      (non-span) event; measurements: `%{count}`; metadata: `%{sha}`
    * `[:exgit, :object_store, :cache_overfull]` — standalone;
      measurements: `%{bytes, cap}`; metadata: `%{policy}` where
      `policy` is `:log | :error | :callback`. Fired when a
      Promisor's eviction loop can't reduce `cache_bytes` below
      `max_cache_bytes` (commit queue empty, only blobs/trees left).
    * `[:exgit, :object_store, :shared_promisor, :resolve]` — span;
      metadata: `%{sha, hit?, partial?}`. `hit?: true` means the
      object was served from cache (promisor unchanged);
      `partial?: true` means the fetch returned a pack but the
      requested SHA wasn't in it (sibling objects were still
      cached).
    * `[:exgit, :object_store, :shared_promisor, :put]` — span;
      metadata: `%{sha, overfull: boolean}`.
    * `[:exgit, :object_store, :shared_promisor, :get]` — span;
      metadata: `%{sha, hit?}`.
    * `[:exgit, :object_store, :shared_promisor, :has?]` — span;
      metadata: `%{sha, present?}`.

  ### Ref store

    * `[:exgit, :ref_store, :write_failed]` — standalone; measurements:
      `%{count}`; metadata: `%{ref, reason, context}`. Fired when
      `Exgit.clone/2` with `lazy: true` (or `filter:`) encounters a
      ref-store write failure while seeding the memory-backed ref
      store.

  ### Pack

    * `[:exgit, :pack, :parse]` — `%{byte_size, object_count}`

  ### FS

    * `[:exgit, :fs, :read_path]` — `%{reference, path}`
    * `[:exgit, :fs, :ls]` — `%{reference, path, entry_count}`
    * `[:exgit, :fs, :stat]` — `%{reference, path}`
    * `[:exgit, :fs, :walk]` — `%{reference, file_count}` (stop only)
    * `[:exgit, :fs, :grep]` — `%{reference, pattern, path_glob,
      match_count, files_scanned, bytes_scanned}` (stop only)

  ### Security

    * `[:exgit, :security, :ref_rejected]` — standalone; measurements:
      `%{count}`; metadata: `%{source, ref}`. `source` is either a
      URL string (wire-layer rejection) or a
      `{:ref_store_disk, operation}` tuple (defense-in-depth
      rejection). Fired when a ref name fails
      `Exgit.RefName.valid?/1`.
  """

  @doc """
  Wrap an operation with telemetry span events.

  The callable MUST return one of two shapes:

    * A tagged tuple `{:span, result, extra_metadata}` — the result is
      returned to the caller unchanged; `extra_metadata` (a map) is
      merged into the `:stop` event's metadata.
    * Anything else — returned verbatim; `:stop` event metadata equals
      the `metadata` passed in.

  Using a tagged `:span` triple avoids ambiguity with library functions
  that naturally return `{:ok, map()}` 2-tuples (e.g. `push/4` returning
  `{:ok, %{ref_results: _}}`).
  """
  @spec span([atom()], map(), (-> {:span, result, map()} | result)) :: result when result: var
  def span(event, metadata, fun)
      when is_list(event) and is_map(metadata) and is_function(fun, 0) do
    :telemetry.span(event, metadata, fn ->
      case fun.() do
        {:span, result, extra} when is_map(extra) -> {result, Map.merge(metadata, extra)}
        result -> {result, metadata}
      end
    end)
  end

  @doc """
  Canonical list of span-event prefixes exgit emits.

  Returned as a list of 2- or 3-element atom lists **without** the
  `:start` / `:stop` / `:exception` suffix. Callers who want to
  attach to the stop event append `:stop` themselves; callers who
  want all three use `:telemetry.span`'s start/stop/exception
  suffixes.

  Part of the public API under SemVer — removing an event name or
  renaming one is a major-version bump. Adding new event names is
  not breaking.

  ## Example

      stops = for e <- Exgit.Telemetry.events(), do: e ++ [:stop]

      :telemetry.attach_many("my-handler", stops, fn event, m, md, _ ->
        IO.inspect({event, m.duration, md})
      end, nil)
  """
  @spec events() :: [[atom()]]
  def events do
    [
      [:exgit, :transport, :ls_refs],
      [:exgit, :transport, :fetch],
      [:exgit, :transport, :push],
      [:exgit, :pack, :parse],
      [:exgit, :object_store, :get],
      [:exgit, :object_store, :put],
      [:exgit, :object_store, :has?],
      [:exgit, :object_store, :fetch_and_cache],
      [:exgit, :object_store, :shared_promisor, :get],
      [:exgit, :object_store, :shared_promisor, :put],
      [:exgit, :object_store, :shared_promisor, :has?],
      [:exgit, :object_store, :shared_promisor, :resolve],
      [:exgit, :fs, :read_path],
      [:exgit, :fs, :ls],
      [:exgit, :fs, :stat],
      [:exgit, :fs, :walk],
      [:exgit, :fs, :grep],
      [:exgit, :blame, :auto_fetch]
    ]
  end

  @doc """
  Canonical list of **non-span** events exgit emits.

  Unlike `events/0` (which returns prefixes that get `:start` /
  `:stop` / `:exception` suffixes appended by `:telemetry.span`),
  these events fire once with `:telemetry.execute/3`. They
  represent discrete occurrences — "the batched prefetch path
  was abandoned and we fell back to the slow path" is a thing
  that happens once, not a span of time.

  Part of the public API under SemVer (same rules as `events/0`).
  """
  @spec emit_events() :: [[atom()]]
  def emit_events do
    [
      [:exgit, :fs, :prefetch, :fallback]
    ]
  end

  @doc """
  Run `fun` with a caller-supplied telemetry handler attached
  to every event in `events/0`. Handles attach / detach around
  the call; returns whatever `fun` returns.

  The caller owns the aggregation policy. We just provide the
  plumbing.

  ## Handler signature

  Standard `:telemetry` handler:
  `(event_name, measurements, metadata, config) -> any`. Runs in
  the process that fired the event.

  ## Examples

  Dead-simple "print every event":

      Exgit.Telemetry.with_handler(
        fn event, m, md, _ -> IO.inspect({event, m.duration, md}) end,
        fn ->
          {:ok, repo} = Exgit.clone(url, lazy: true)
          Exgit.FS.grep(repo, "HEAD", "foo") |> Enum.to_list()
        end
      )

  Aggregate into per-event totals in ETS:

      table = :ets.new(:my_totals, [:public, :bag])

      Exgit.Telemetry.with_handler(
        fn event, %{duration: d}, _md, _ ->
          :ets.insert(table, {event, d})
        end,
        fn -> my_agent_step() end
      )

      :ets.tab2list(table)
      # => [{[:exgit, :fs, :grep, :stop], 11_340_000}, ...]

  Bridge to OpenTelemetry:

      Exgit.Telemetry.with_handler(
        &OpentelemetryTelemetry.handle_event/4,
        fn -> my_agent_step() end
      )

  ## Scope

  Attaches to `:stop` events only. Callers who want start events
  too should attach manually via `:telemetry.attach_many/4` and
  `events/0`.
  """
  @spec with_handler(:telemetry.handler_function(), (-> result)) :: result when result: var
  def with_handler(handler_fun, fun)
      when is_function(handler_fun, 4) and is_function(fun, 0) do
    id = "exgit-telemetry-#{System.unique_integer([:positive])}"
    stops = for e <- events(), do: e ++ [:stop]
    _ = :telemetry.attach_many(id, stops, handler_fun, nil)

    try do
      fun.()
    after
      _ = :telemetry.detach(id)
    end
  end
end
