defmodule Exgit.Transport.HttpNegotiationTest do
  use ExUnit.Case, async: true

  alias Exgit.Transport.HTTP
  alias Exgit.PktLine

  describe "fetch negotiation (P0.19)" do
    test "fetch sends 'have <sha>' lines when haves are supplied" do
      # Intercept the outgoing request body so we can inspect what the
      # client would send to the server.
      {listener, port, request_ref} = run_capture_server()

      want = :crypto.hash(:sha, "w")
      have = :crypto.hash(:sha, "h")

      t = HTTP.new("http://127.0.0.1:#{port}")

      # We don't care about the response — just that our request contains
      # `have` lines.
      _ = HTTP.fetch(t, [want], haves: [have])

      # Pull the recorded request.
      assert_receive {^request_ref, request}, 5_000

      assert String.contains?(request, "have #{Base.encode16(have, case: :lower)}"),
             "fetch request omitted `have <sha>` line for incremental negotiation"

      :gen_tcp.close(listener)
    end
  end

  defp run_capture_server do
    {:ok, listener} = :gen_tcp.listen(0, [:binary, active: false, reuseaddr: true, packet: :raw])
    {:ok, port} = :inet.port(listener)

    parent = self()
    ref = make_ref()

    spawn_link(fn ->
      # First the client will do a discovery GET (capabilities).
      case :gen_tcp.accept(listener, 5_000) do
        {:ok, sock} ->
          _ = recv_all(sock, 1_500)

          # Respond with minimal capabilities advertisement.
          caps_body =
            IO.iodata_to_binary([
              PktLine.encode("# service=git-upload-pack\n"),
              PktLine.flush(),
              PktLine.encode("version 2\n"),
              PktLine.encode("fetch=shallow\n"),
              PktLine.flush()
            ])

          resp1 =
            "HTTP/1.1 200 OK\r\nContent-Type: application/x-git-upload-pack-advertisement\r\nContent-Length: #{byte_size(caps_body)}\r\nConnection: close\r\n\r\n" <>
              caps_body

          :gen_tcp.send(sock, resp1)
          :gen_tcp.close(sock)

        _ ->
          :ok
      end

      # Then the POST fetch.
      case :gen_tcp.accept(listener, 5_000) do
        {:ok, sock} ->
          body = recv_post_body(sock)
          send(parent, {ref, body})

          # Send an empty OK response.
          resp2 =
            "HTTP/1.1 200 OK\r\nContent-Type: application/x-git-upload-pack-result\r\nContent-Length: 0\r\nConnection: close\r\n\r\n"

          :gen_tcp.send(sock, resp2)
          :gen_tcp.close(sock)

        _ ->
          :ok
      end
    end)

    {listener, port, ref}
  end

  defp recv_all(sock, timeout) do
    case :gen_tcp.recv(sock, 0, timeout) do
      {:ok, data} ->
        if String.contains?(data, "\r\n\r\n"), do: data, else: data <> recv_all(sock, timeout)

      _ ->
        <<>>
    end
  end

  defp recv_post_body(sock) do
    headers_and_body = recv_all(sock, 1_500)

    case :binary.match(headers_and_body, "\r\n\r\n") do
      {pos, 4} ->
        binary_part(headers_and_body, pos + 4, byte_size(headers_and_body) - pos - 4)

      _ ->
        <<>>
    end
  end
end
