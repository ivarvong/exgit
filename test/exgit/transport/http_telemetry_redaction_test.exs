defmodule Exgit.Transport.HttpTelemetryRedactionTest do
  use ExUnit.Case, async: true

  alias Exgit.PktLine
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

  test "push telemetry redacts a token embedded in the URL" do
    m = marker()
    t = HTTP.new("https://x-access-token:#{@token}@127.0.0.1:1/#{m}.git")
    update = {"refs/heads/main", nil, <<0::160>>}

    meta =
      capture_start_meta([:exgit, :transport, :push], m, fn ->
        HTTP.push(t, [update], "PACK")
      end)

    refute meta.url =~ @token, "token leaked into push telemetry: #{meta.url}"
    assert meta.url =~ "***"
  end

  test "ref_rejected security telemetry redacts a token embedded in the source URL" do
    # `[:exgit, :security, :ref_rejected]` fires while parsing an ls-refs
    # response, so the dead-port trick isn't enough — serve one hostile
    # ref name from a local socket and let `keep_ref?` reject it.
    m = marker()
    hostile_ref = "refs/heads/../../escape"
    sha = Base.encode16(:binary.copy(<<1>>, 20), case: :lower)
    body = IO.iodata_to_binary([PktLine.encode("#{sha} #{hostile_ref}\n"), PktLine.flush()])

    handler = "redact-#{m}"
    test_pid = self()

    :telemetry.attach(
      handler,
      [:exgit, :security, :ref_rejected],
      fn _e, _measurements, meta, _cfg ->
        if is_binary(meta[:source]) and String.contains?(meta.source, m) do
          send(test_pid, {:sec_meta, meta})
        end
      end,
      nil
    )

    try do
      serve_once(body, fn port ->
        t = HTTP.new("http://x-access-token:#{@token}@127.0.0.1:#{port}/#{m}.git")
        _ = HTTP.ls_refs(t)
      end)

      assert_receive {:sec_meta, meta}, 2_000
      assert meta.ref == hostile_ref
      refute meta.source =~ @token, "token leaked into ref_rejected telemetry: #{meta.source}"
      assert meta.source =~ "***"
    after
      :telemetry.detach(handler)
    end
  end

  test "a URL without credentials passes through unchanged" do
    m = marker()
    t = HTTP.new("https://127.0.0.1:1/#{m}.git")
    meta = capture_start_meta([:exgit, :transport, :ls_refs], m, fn -> HTTP.ls_refs(t) end)

    assert meta.url == "https://127.0.0.1:1/#{m}.git"
    refute meta.url =~ "***"
  end

  # One-shot HTTP server (same shape as `warm_server` in HttpTest):
  # accept a single request, reply 200 with `body`, close.
  defp serve_once(body, fun) do
    {:ok, listener} = :gen_tcp.listen(0, [:binary, active: false, reuseaddr: true, packet: :raw])
    {:ok, port} = :inet.port(listener)

    task =
      Task.async(fn ->
        {:ok, sock} = :gen_tcp.accept(listener, 5_000)
        _ = recv_request(sock)

        resp =
          "HTTP/1.1 200 OK\r\n" <>
            "Content-Type: application/x-git-upload-pack-result\r\n" <>
            "Content-Length: #{byte_size(body)}\r\nConnection: close\r\n\r\n" <> body

        :ok = :gen_tcp.send(sock, resp)
        :gen_tcp.close(sock)
      end)

    try do
      fun.(port)
    after
      Task.await(task, 5_000)
      :gen_tcp.close(listener)
    end
  end

  defp recv_request(sock) do
    case :gen_tcp.recv(sock, 0, 2_000) do
      {:ok, data} ->
        if String.contains?(data, "\r\n\r\n"), do: data, else: data <> recv_request(sock)

      {:error, _} ->
        <<>>
    end
  end
end
