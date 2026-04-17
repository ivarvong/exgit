defmodule Exgit.Telemetry do
  @moduledoc """
  Telemetry event names and conventions for exgit.

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

    * `[:exgit, :transport, :fetch]` — metadata: `%{transport, wants_count, result_bytes}`
    * `[:exgit, :transport, :ls_refs]` — metadata: `%{transport, ref_count}`
    * `[:exgit, :transport, :push]` — metadata: `%{transport, update_count}`

  ### Object store

    * `[:exgit, :object_store, :get]` — metadata: `%{store, sha, hit?}`
      - `hit?: true` when a `Promisor`-backed store served from cache
      - `hit?: false` when it had to go to the network
      - omitted for stores that don't track this distinction
    * `[:exgit, :object_store, :put]` — metadata: `%{store, sha}`
    * `[:exgit, :object_store, :has?]` — metadata: `%{store, sha, present?}`

  ### Pack

    * `[:exgit, :pack, :parse]` — metadata: `%{byte_size, object_count}`

  ### FS

    * `[:exgit, :fs, :read_path]` — metadata: `%{reference, path}`
    * `[:exgit, :fs, :ls]` — metadata: `%{reference, path, entry_count}`
    * `[:exgit, :fs, :walk]` — metadata: `%{reference, file_count}`
    * `[:exgit, :fs, :grep]` — metadata: `%{reference, pattern, path_glob, match_count}`
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
