defmodule Exgit.Transport.HttpSidebandTest do
  use ExUnit.Case, async: true

  alias Exgit.Transport.HTTP
  alias Exgit.PktLine

  describe "sideband demuxing (P0.18)" do
    test "fetch response WITHOUT sideband framing is not demuxed" do
      # Build a fetch response with:
      #   - pkt "packfile\n" (section marker)
      #   - pkt containing raw pack bytes (no channel byte)
      # The client must NOT strip the first byte of the pack data.

      # Use a recognizable pack byte pattern that happens to start with 0x01
      # — which would otherwise be interpreted as "channel 1 pack data".
      # If the client strips it, the output will be one byte short.
      fake_pack =
        <<"PACK", 2::32-big, 0::32-big>> <> :crypto.hash(:sha, <<"PACK", 2::32-big, 0::32-big>>)

      body =
        IO.iodata_to_binary([
          PktLine.encode("packfile\n"),
          PktLine.encode(fake_pack),
          PktLine.flush()
        ])

      {listener, port} = run_fetch_server(body)

      t = HTTP.new("http://127.0.0.1:#{port}")
      wants = [:binary.copy(<<0>>, 20)]

      # Note: HTTP.fetch triggers a POST to /git-upload-pack. Our server
      # will respond with the body above regardless of request.
      # Disable sideband so the response body is treated as raw pack data.
      case HTTP.fetch(t, wants, sideband: false) do
        {:ok, pack_bytes, _} ->
          # The exact pack bytes must round-trip — no first byte stripped.
          assert pack_bytes == fake_pack,
                 "pack bytes corrupted by unconditional sideband demux — " <>
                   "got #{byte_size(pack_bytes)} bytes, expected #{byte_size(fake_pack)}"

        other ->
          flunk("unexpected fetch response: #{inspect(other)}")
      end

      :gen_tcp.close(listener)
    end
  end

  defp run_fetch_server(body) do
    {:ok, listener} = :gen_tcp.listen(0, [:binary, active: false, reuseaddr: true, packet: :raw])
    {:ok, port} = :inet.port(listener)

    spawn_link(fn ->
      case :gen_tcp.accept(listener, 10_000) do
        {:ok, sock} ->
          _ = recv_request(sock)

          resp =
            "HTTP/1.1 200 OK\r\n" <>
              "Content-Type: application/x-git-upload-pack-result\r\n" <>
              "Content-Length: #{byte_size(body)}\r\n" <>
              "Connection: close\r\n\r\n" <> body

          :gen_tcp.send(sock, resp)
          :gen_tcp.close(sock)

        _ ->
          :ok
      end
    end)

    {listener, port}
  end

  defp recv_request(sock) do
    recv_until_body_done(sock, <<>>)
  end

  defp recv_until_body_done(sock, acc) do
    case :gen_tcp.recv(sock, 0, 2_000) do
      {:ok, data} ->
        full = acc <> data

        case :binary.match(full, "\r\n\r\n") do
          {pos, 4} ->
            # Headers done — try to read content-length's worth of body.
            headers = binary_part(full, 0, pos)

            case Regex.run(~r/[Cc]ontent-[Ll]ength:\s*(\d+)/, headers) do
              [_, len_str] ->
                len = String.to_integer(len_str)
                body_so_far = byte_size(full) - pos - 4

                if body_so_far >= len do
                  full
                else
                  recv_until_body_done(sock, full)
                end

              _ ->
                full
            end

          :nomatch ->
            recv_until_body_done(sock, full)
        end

      _ ->
        acc
    end
  end
end
