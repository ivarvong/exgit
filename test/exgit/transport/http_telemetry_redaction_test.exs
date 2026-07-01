defmodule Exgit.Transport.HttpTelemetryRedactionTest do
  use ExUnit.Case, async: true

  alias Exgit.Transport.HTTP

  # A token embedded in a remote URL must never reach telemetry metadata.
  # `Exgit.Telemetry.span/3` (via `:telemetry.span/3`) emits a `[..., :start]`
  # event carrying the metadata BEFORE it runs the network call — so we can
  # capture the URL metadata without a live git server: point the transport at
  # a dead port, let the request fail, and read the start event.
  @token "SECRET_TOKEN_do_not_leak_9f3a"

  # The telemetry handler is global and other async tests emit the same spans,
  # so filter on a unique per-test path marker (which survives redaction — only
  # the userinfo is stripped) to capture exactly this test's event.
  defp capture_start_meta(event, marker, run) do
    handler = "redact-#{marker}"
    test_pid = self()

    :telemetry.attach(
      handler,
      event ++ [:start],
      fn _e, _measurements, meta, _cfg ->
        if is_binary(meta[:url]) and String.contains?(meta.url, marker) do
          send(test_pid, {:tele_meta, meta})
        end
      end,
      nil
    )

    try do
      _ = run.()
      assert_receive {:tele_meta, meta}, 2_000
      meta
    after
      :telemetry.detach(handler)
    end
  end

  defp marker, do: "probe#{System.unique_integer([:positive])}"

  test "ls_refs telemetry redacts a token embedded in the URL" do
    m = marker()
    t = HTTP.new("https://x-access-token:#{@token}@127.0.0.1:1/#{m}.git")
    meta = capture_start_meta([:exgit, :transport, :ls_refs], m, fn -> HTTP.ls_refs(t) end)

    refute meta.url =~ @token, "token leaked into ls_refs telemetry: #{meta.url}"
    assert meta.url =~ "***"
  end

  test "fetch telemetry redacts a token embedded in the URL" do
    m = marker()
    t = HTTP.new("https://x-access-token:#{@token}@127.0.0.1:1/#{m}.git")

    meta =
      capture_start_meta([:exgit, :transport, :fetch], m, fn ->
        # `wants` are raw 20-byte shas; the call fails at the dead port, but
        # the span's :start event (with the URL metadata) fires first.
        HTTP.fetch(t, [<<0::160>>], [])
      end)

    refute meta.url =~ @token, "token leaked into fetch telemetry: #{meta.url}"
    assert meta.url =~ "***"
  end

  test "a URL without credentials passes through unchanged" do
    m = marker()
    t = HTTP.new("https://127.0.0.1:1/#{m}.git")
    meta = capture_start_meta([:exgit, :transport, :ls_refs], m, fn -> HTTP.ls_refs(t) end)

    assert meta.url == "https://127.0.0.1:1/#{m}.git"
    refute meta.url =~ "***"
  end
end
