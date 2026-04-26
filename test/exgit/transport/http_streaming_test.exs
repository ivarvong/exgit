defmodule Exgit.Transport.HttpStreamingTest do
  use ExUnit.Case, async: true

  alias Exgit.PktLine
  alias Exgit.Transport.HTTP

  describe "streaming fetch decode" do
    test "reassembles a sideband-framed response split across many packets" do
      # Build a synthetic pack delivered as ~5,000 sideband-framed pkt-lines.
      # Each chunk carries ~16 KB of pack bytes — exercises the per-packet
      # state machine and the iolist accumulator end-to-end.
      chunks =
        for i <- 1..5_000 do
          # Deterministic, distinguishable chunk content so we can assert
          # exact reassembly (no slicing-off-by-one in the demuxer).
          pad = :binary.copy(<<rem(i, 256)>>, 16_000)
          <<i::32-big, pad::binary>>
        end

      pack_bytes = IO.iodata_to_binary(chunks)

      body =
        IO.iodata_to_binary([
          PktLine.encode("packfile\n"),
          for(c <- chunks, do: PktLine.encode(<<1, c::binary>>)),
          PktLine.flush()
        ])

      {listener, port} = run_fetch_server(body)
      t = HTTP.new("http://127.0.0.1:#{port}")

      assert {:ok, got, _summary} = HTTP.fetch(t, [<<0::160>>], sideband: true)
      assert byte_size(got) == byte_size(pack_bytes)
      assert got == pack_bytes

      :gen_tcp.close(listener)
    end

    test "channel 3 (server error) on sideband aborts with :server_error" do
      body =
        IO.iodata_to_binary([
          PktLine.encode("packfile\n"),
          PktLine.encode(<<1, "PACKabc">>),
          PktLine.encode(<<3, "fatal: object missing">>),
          PktLine.flush()
        ])

      {listener, port} = run_fetch_server(body)
      t = HTTP.new("http://127.0.0.1:#{port}")

      assert {:error, {:server_error, "fatal: object missing"}} =
               HTTP.fetch(t, [<<0::160>>], sideband: true)

      :gen_tcp.close(listener)
    end

    @tag :memory
    test "process heap stays bounded relative to pack size (regression guard)" do
      # 8 MB of pack bytes split into 4 KB sideband packets. Old non-streaming
      # path would hold the full body + a list-of-tuples intermediate + the
      # final iolist — peaking near 3-4× pack size. Streaming holds at most
      # one pkt-line at a time + the growing iolist.
      pack_size = 8 * 1024 * 1024
      chunk_size = 4096
      n_chunks = div(pack_size, chunk_size)

      chunks = for i <- 1..n_chunks, do: :binary.copy(<<rem(i, 251)>>, chunk_size)
      pack_bytes = IO.iodata_to_binary(chunks)

      body =
        IO.iodata_to_binary([
          PktLine.encode("packfile\n"),
          for(c <- chunks, do: PktLine.encode(<<1, c::binary>>)),
          PktLine.flush()
        ])

      {listener, port} = run_fetch_server(body)
      t = HTTP.new("http://127.0.0.1:#{port}")

      :erlang.garbage_collect(self())
      {:memory, before_bytes} = :erlang.process_info(self(), :memory)

      {:ok, got, _} = HTTP.fetch(t, [<<0::160>>], sideband: true)

      {:memory, peak_bytes} = :erlang.process_info(self(), :memory)
      assert got == pack_bytes

      growth = peak_bytes - before_bytes

      # Allow up to 4× pack size as the regression bound. Streaming
      # typically uses ~1× (the final returned binary is unavoidable
      # while fetch/3's contract is binary-returning); the headroom is
      # for Erlang's per-process allocator slack, not architectural waste.
      assert growth < 4 * pack_size,
             "process memory grew by #{div(growth, 1024 * 1024)} MB for an " <>
               "#{div(pack_size, 1024 * 1024)} MB pack — streaming regression?"

      :gen_tcp.close(listener)
    end
  end

  defp run_fetch_server(body, opts \\ []) do
    status = Keyword.get(opts, :status, 200)
    status_text = if status == 200, do: "OK", else: "Server Error"

    {:ok, listener} =
      :gen_tcp.listen(0, [:binary, active: false, reuseaddr: true, packet: :raw])

    {:ok, port} = :inet.port(listener)

    spawn_link(fn ->
      case :gen_tcp.accept(listener, 10_000) do
        {:ok, sock} ->
          _ = recv_request(sock)

          resp =
            "HTTP/1.1 #{status} #{status_text}\r\n" <>
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

  defp recv_request(sock), do: recv_until_body_done(sock, <<>>)

  defp recv_until_body_done(sock, acc) do
    case :gen_tcp.recv(sock, 0, 2_000) do
      {:ok, data} ->
        full = acc <> data

        case :binary.match(full, "\r\n\r\n") do
          {pos, 4} ->
            headers = binary_part(full, 0, pos)

            case Regex.run(~r/[Cc]ontent-[Ll]ength:\s*(\d+)/, headers) do
              [_, len_str] ->
                len = String.to_integer(len_str)
                body_so_far = byte_size(full) - pos - 4

                if body_so_far >= len,
                  do: full,
                  else: recv_until_body_done(sock, full)

              _ ->
                full
            end

          _ ->
            recv_until_body_done(sock, full)
        end

      _ ->
        acc
    end
  end
end
