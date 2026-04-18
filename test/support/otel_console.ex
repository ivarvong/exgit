defmodule Exgit.Test.OtelConsole do
  @moduledoc """
  A lightweight `:telemetry` handler that pretty-prints span events as
  an indented timeline — the poor man's OpenTelemetry console exporter.

  Also works as a model for wiring real OTel: replace the `log/4`
  callback with a handler that calls `OpenTelemetry.Tracer.with_span/2`
  (or use the `opentelemetry_telemetry` bridge directly).

  ## Usage

      Exgit.Test.OtelConsole.attach()
      # ... run your code ...
      Exgit.Test.OtelConsole.detach()
  """

  @events [
    [:exgit, :transport, :fetch],
    [:exgit, :transport, :ls_refs],
    [:exgit, :transport, :push],
    [:exgit, :object_store, :get],
    [:exgit, :object_store, :put],
    [:exgit, :object_store, :fetch_and_cache],
    [:exgit, :object_store, :import_objects],
    [:exgit, :pack, :parse],
    [:exgit, :fs, :read_path],
    [:exgit, :fs, :ls],
    [:exgit, :fs, :walk],
    [:exgit, :fs, :grep]
  ]

  @handler "exgit-otel-console"

  @doc """
  Attach the handler. `opts`:

    * `:min_duration_us` — only print `:stop` events whose duration
      exceeds this threshold. Default: 0 (print everything).
    * `:summary` — when true, collects timing stats in an Agent and
      prints a summary via `summary/0`. Default: true.
  """
  def attach(opts \\ []) do
    detach()

    min_us = Keyword.get(opts, :min_duration_us, 0)

    # Agent holds timing stats so we can print a summary at the end.
    {:ok, agent} = Agent.start_link(fn -> %{events: [], start_time: System.monotonic_time()} end)
    :persistent_term.put({__MODULE__, :agent}, agent)
    :persistent_term.put({__MODULE__, :min_us}, min_us)

    events =
      Enum.flat_map(@events, fn e -> [e ++ [:start], e ++ [:stop]] end)

    :telemetry.attach_many(@handler, events, &__MODULE__.handle/4, nil)
    :ok
  end

  def detach do
    :telemetry.detach(@handler)

    case :persistent_term.get({__MODULE__, :agent}, nil) do
      nil ->
        :ok

      pid ->
        if Process.alive?(pid), do: Agent.stop(pid)
        :persistent_term.erase({__MODULE__, :agent})
    end

    :ok
  end

  @doc "Print a summary of all events captured so far."
  def summary do
    case :persistent_term.get({__MODULE__, :agent}, nil) do
      nil ->
        IO.puts("(no events captured)")

      pid ->
        events = Agent.get(pid, & &1.events) |> Enum.reverse()
        print_summary(events)
    end
  end

  @doc false
  def handle(event, measurements, metadata, _config) do
    record(event, measurements, metadata)

    case List.last(event) do
      :stop ->
        min_us = :persistent_term.get({__MODULE__, :min_us}, 0)
        duration_us = System.convert_time_unit(measurements.duration, :native, :microsecond)

        if duration_us >= min_us do
          print_stop(event, duration_us, metadata)
        end

      _ ->
        :ok
    end
  end

  defp record(event, measurements, metadata) do
    case :persistent_term.get({__MODULE__, :agent}, nil) do
      nil ->
        :ok

      pid ->
        Agent.update(pid, fn s -> %{s | events: [{event, measurements, metadata} | s.events]} end)
    end
  end

  defp print_stop(event, duration_us, metadata) do
    name =
      event
      |> Enum.slice(1..-2//1)
      |> Enum.map_join(".", &to_string/1)

    meta_parts =
      metadata
      |> Map.drop([:telemetry_span_context])
      |> Enum.map_join(" ", fn {k, v} -> "#{k}=#{format_value(v)}" end)

    ms = Float.round(duration_us / 1000, 2)
    IO.puts("  [#{format_ms(ms)} ms] #{name}  #{meta_parts}")
  end

  defp format_ms(ms) when ms >= 100, do: :io_lib.format("~6.1f", [ms]) |> IO.iodata_to_binary()
  defp format_ms(ms), do: :io_lib.format("~6.2f", [ms]) |> IO.iodata_to_binary()

  defp format_value(v) when is_binary(v) and byte_size(v) > 40 do
    "\"" <> binary_part(v, 0, 37) <> "...\""
  end

  defp format_value(v) when is_binary(v), do: inspect(v)
  defp format_value(v), do: inspect(v, limit: 5)

  defp print_summary(events) do
    stops = Enum.filter(events, fn {e, _, _} -> List.last(e) == :stop end)

    by_name =
      Enum.group_by(stops, fn {e, _, _} -> Enum.slice(e, 1..-2//1) |> Enum.join(".") end)

    rows =
      for {name, evs} <- by_name do
        durs = Enum.map(evs, fn {_, m, _} -> m.duration end)
        total_us = Enum.sum(durs) |> System.convert_time_unit(:native, :microsecond)
        count = length(evs)

        avg_us =
          if count > 0,
            do: div(total_us, count),
            else: 0

        {name, count, total_us, avg_us}
      end
      |> Enum.sort_by(fn {_, _, total, _} -> -total end)

    IO.puts("\n=== Summary (sorted by total time) ===")

    IO.puts(
      "  #{String.pad_trailing("event", 30)} #{String.pad_leading("count", 6)}  #{String.pad_leading("total ms", 10)}  #{String.pad_leading("avg ms", 10)}"
    )

    for {name, count, total_us, avg_us} <- rows do
      IO.puts(
        "  #{String.pad_trailing(name, 30)} #{String.pad_leading(to_string(count), 6)}  #{String.pad_leading(Float.round(total_us / 1000, 2) |> to_string(), 10)}  #{String.pad_leading(Float.round(avg_us / 1000, 2) |> to_string(), 10)}"
      )
    end
  end
end
