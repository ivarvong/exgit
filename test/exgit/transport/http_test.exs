defmodule Exgit.Transport.HttpTest do
  use ExUnit.Case, async: true

  alias Exgit.PktLine
  alias Exgit.Transport.HTTP

  describe "parse_capabilities/1 atom safety (P0.1)" do
    test "does not leak the atom table when the server advertises unknown capabilities" do
      # Warm up Req/Mint/TLS code paths so their one-time atom allocations
      # don't pollute the measurement window.
      warm_body = IO.iodata_to_binary([PktLine.encode("version 2\n"), PktLine.flush()])

      warm_server(warm_body, fn port ->
        _ = HTTP.capabilities(HTTP.new("http://127.0.0.1:#{port}"))
      end)

      # Simulate a malicious server: send version 2, then 2000 unique
      # capability lines that the client has never seen before. If the
      # client calls String.to_atom/1 on server input it will mint 2000
      # fresh atoms.
      before_count = :erlang.system_info(:atom_count)

      unique_tag = "exgit_evilcap_#{System.unique_integer([:positive])}"

      body =
        IO.iodata_to_binary([
          PktLine.encode("version 2\n"),
          for(i <- 1..2_000, do: PktLine.encode("#{unique_tag}_#{i}\n")),
          PktLine.flush()
        ])

      # parse_capabilities is private; exercise via the public behaviour by
      # spinning up a tiny test server on localhost.
      {:ok, listener} =
        :gen_tcp.listen(0, [:binary, active: false, reuseaddr: true, packet: :raw])

      {:ok, port} = :inet.port(listener)

      task =
        Task.async(fn ->
          {:ok, sock} = :gen_tcp.accept(listener, 5_000)
          # Minimal HTTP response
          _ = recv_request(sock)

          resp =
            "HTTP/1.1 200 OK\r\n" <>
              "Content-Type: application/x-git-upload-pack-advertisement\r\n" <>
              "Content-Length: #{byte_size(body)}\r\n" <>
              "Connection: close\r\n\r\n" <> body

          :ok = :gen_tcp.send(sock, resp)
          :gen_tcp.close(sock)
        end)

      t = HTTP.new("http://127.0.0.1:#{port}")
      _ = HTTP.capabilities(t)

      Task.await(task, 5_000)
      :gen_tcp.close(listener)

      after_count = :erlang.system_info(:atom_count)

      # Allow a small slack for infrastructure-minted atoms but it must be
      # nowhere near 2000.
      assert after_count - before_count < 200,
             "atom table grew by #{after_count - before_count} — server input is reaching String.to_atom/1"
    end
  end

  describe "hostile server bytes surface as error values" do
    test "capabilities/1 returns an error tuple on garbage bytes" do
      garbage = "ZZZZ" <> :binary.copy(<<0xFF>>, 32)

      warm_server(garbage, fn port ->
        t = HTTP.new("http://127.0.0.1:#{port}")

        assert {:error, {:malformed_response, {:malformed_pkt_line, _}}} =
                 HTTP.capabilities(t)
      end)
    end

    test "push/4 returns an error tuple when the report-status body is garbage" do
      warm_server("ZZZZnot-a-pkt-line", fn port ->
        t = HTTP.new("http://127.0.0.1:#{port}")
        update = {"refs/heads/main", nil, :binary.copy(<<1>>, 20)}

        assert {:error, {:malformed_response, {:malformed_pkt_line, _}}} =
                 HTTP.push(t, [update], "PACK")
      end)
    end
  end

  describe "ls-refs ref cap (:max_refs)" do
    test "exceeding the cap surfaces as {:error, {:too_many_refs, cap}}" do
      lines =
        for i <- 1..5 do
          sha = Base.encode16(:binary.copy(<<i>>, 20), case: :lower)
          PktLine.encode("#{sha} refs/heads/b#{i}\n")
        end

      body = IO.iodata_to_binary([lines, PktLine.flush()])

      warm_server(body, fn port ->
        t = HTTP.new("http://127.0.0.1:#{port}", max_refs: 3)
        assert {:error, {:too_many_refs, 3}} = HTTP.ls_refs(t)
      end)
    end

    test "under the cap the same response lists all refs" do
      lines =
        for i <- 1..5 do
          sha = Base.encode16(:binary.copy(<<i>>, 20), case: :lower)
          PktLine.encode("#{sha} refs/heads/b#{i}\n")
        end

      body = IO.iodata_to_binary([lines, PktLine.flush()])

      warm_server(body, fn port ->
        t = HTTP.new("http://127.0.0.1:#{port}", max_refs: 5)
        assert {:ok, refs, _meta} = HTTP.ls_refs(t)
        assert length(refs) == 5
      end)
    end
  end

  defp warm_server(body, fun) do
    {:ok, listener} = :gen_tcp.listen(0, [:binary, active: false, reuseaddr: true, packet: :raw])
    {:ok, port} = :inet.port(listener)

    task =
      Task.async(fn ->
        {:ok, sock} = :gen_tcp.accept(listener, 5_000)
        _ = recv_request(sock)

        resp =
          "HTTP/1.1 200 OK\r\nContent-Type: x\r\nContent-Length: #{byte_size(body)}\r\nConnection: close\r\n\r\n" <>
            body

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
