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
      measurements: `%{bytes, cap}`; metadata: `%{}`. Fired when
      a Promisor's eviction loop can't reduce `cache_bytes` below
      `max_cache_bytes` (commit queue empty, only blobs/trees left).

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
end
