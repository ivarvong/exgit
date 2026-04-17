defmodule Exgit.Transport.HttpSecurityTest do
  use ExUnit.Case, async: true

  alias Exgit.Transport.HTTP

  describe "redirect auth leakage (P0.5)" do
    test "Authorization header is NOT forwarded to a different origin on 302" do
      # Spin up two local servers. Server A (origin) 302s to server B
      # (evil). We send a request to A with a Bearer token; assert server
      # B never sees that token.

      # Use a token with a unique marker so we can recognize it anywhere
      # in B's log.
      token = "exgit_redirect_test_token_#{System.unique_integer([:positive])}"

      {listener_b, port_b, received_b} = run_capture_server()

      origin_redirect = fn ->
        {:ok, listener_a} =
          :gen_tcp.listen(0, [:binary, active: false, reuseaddr: true, packet: :raw])

        {:ok, port_a} = :inet.port(listener_a)

        task_a =
          Task.async(fn ->
            {:ok, sock} = :gen_tcp.accept(listener_a, 5_000)
            _ = recv_request(sock)

            resp =
              "HTTP/1.1 302 Found\r\n" <>
                "Location: http://127.0.0.1:#{port_b}/stolen\r\n" <>
                "Content-Length: 0\r\n" <>
                "Connection: close\r\n\r\n"

            :gen_tcp.send(sock, resp)
            :gen_tcp.close(sock)
          end)

        {port_a, task_a, listener_a}
      end

      {port_a, task_a, listener_a} = origin_redirect.()

      t = HTTP.new("http://127.0.0.1:#{port_a}", auth: {:bearer, token})
      _ = HTTP.capabilities(t)

      Task.await(task_a, 5_000)
      :gen_tcp.close(listener_a)

      # Give server B a moment to receive anything (or not).
      Process.sleep(50)

      received = Agent.get(received_b, & &1)
      Agent.stop(received_b)
      :gen_tcp.close(listener_b)

      # The token must not appear in any request made to server B.
      for req <- received do
        refute String.contains?(req, token),
               "redirected request to different origin contained bearer token!\n#{inspect(req)}"
      end
    end
  end

  describe "timeouts (P2)" do
    test "a hung server does not block the caller forever" do
      # Start a server that accepts the connection but never responds.
      {:ok, listener} =
        :gen_tcp.listen(0, [:binary, active: false, reuseaddr: true, packet: :raw])

      {:ok, port} = :inet.port(listener)

      task =
        Task.async(fn ->
          case :gen_tcp.accept(listener, 5_000) do
            {:ok, sock} ->
              # Never respond. Just hold the socket open for a bit.
              Process.sleep(3_000)
              :gen_tcp.close(sock)

            _ ->
              :ok
          end
        end)

      t = HTTP.new("http://127.0.0.1:#{port}", receive_timeout: 500)

      parent = self()

      worker =
        spawn(fn ->
          result = HTTP.capabilities(t)
          send(parent, {:done, result})
        end)

      received =
        receive do
          {:done, r} -> r
        after
          2_500 ->
            Process.exit(worker, :kill)
            :timeout
        end

      Task.shutdown(task, :brutal_kill)
      :gen_tcp.close(listener)

      # Result should be a structured error, not a timeout at our test layer
      # (which would indicate the client ignored our timeout).
      assert received != :timeout,
             "HTTP.capabilities did not respect :receive_timeout — client hung"
    end
  end

  # --- helpers ---

  defp run_capture_server do
    {:ok, listener} = :gen_tcp.listen(0, [:binary, active: false, reuseaddr: true, packet: :raw])
    {:ok, port} = :inet.port(listener)
    {:ok, agent} = Agent.start_link(fn -> [] end)

    spawn_link(fn ->
      accept_loop(listener, agent)
    end)

    {listener, port, agent}
  end

  defp accept_loop(listener, agent) do
    case :gen_tcp.accept(listener, 30_000) do
      {:ok, sock} ->
        req = recv_request(sock)
        Agent.update(agent, fn acc -> [req | acc] end)

        resp =
          "HTTP/1.1 200 OK\r\nContent-Length: 0\r\nConnection: close\r\n\r\n"

        :gen_tcp.send(sock, resp)
        :gen_tcp.close(sock)
        accept_loop(listener, agent)

      _ ->
        :ok
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
