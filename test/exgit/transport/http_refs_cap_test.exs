defmodule Exgit.Transport.HttpRefsCapTest do
  @moduledoc """
  Exercises the `:max_refs` backstop on `Exgit.Transport.HTTP.ls_refs/2`
  against a server that streams the ls-refs response one pkt-line per
  chunk — the shape a hostile server would use to grow the client's
  ref list without bound.

  The cap must surface as `{:error, {:too_many_refs, cap}}`, not as a
  `{:truncated, _}` decode artifact: the client halts the body early
  when the cap trips, which legitimately leaves partial bytes in the
  pkt-line decoder, and the accumulated domain error has to win.

  Uses a raw `:gen_tcp` server (like `Exgit.Transport.HttpTest`)
  rather than Bypass: the cap test hangs up mid-response by design,
  which Bypass's plug monitoring reports as a `:shutdown` failure.
  """

  use ExUnit.Case, async: true

  alias Exgit.PktLine
  alias Exgit.Transport.HTTP

  describe "ls_refs/2 with :max_refs" do
    test "a server streaming 100 refs past a cap of 50 aborts with {:too_many_refs, 50}" do
      serve_chunked_ls_refs(100, fn port ->
        t = HTTP.new("http://127.0.0.1:#{port}", max_refs: 50)

        assert HTTP.ls_refs(t) == {:error, {:too_many_refs, 50}}
      end)
    end

    test "exactly cap refs succeeds with all refs present (boundary)" do
      serve_chunked_ls_refs(50, fn port ->
        t = HTTP.new("http://127.0.0.1:#{port}", max_refs: 50)

        assert {:ok, refs, _meta} = HTTP.ls_refs(t)
        assert length(refs) == 50
        assert Enum.map(refs, &elem(&1, 0)) == for(i <- 1..50, do: ref_name(i))
        assert {ref_name(50), sha(50)} == List.last(refs)
      end)
    end

    test "the default cap is the documented 1_000_000 backstop" do
      assert HTTP.new("http://localhost").max_refs == 1_000_000
    end
  end

  # Serve an ls-refs response over chunked transfer encoding, one
  # pkt-line per chunk, so the cap trips while bytes are still
  # arriving rather than on a fully-buffered body. Once the client's
  # cap trips it hangs up; send errors past that point are expected.
  defp serve_chunked_ls_refs(ref_count, fun) do
    {:ok, listener} = :gen_tcp.listen(0, [:binary, active: false, reuseaddr: true, packet: :raw])
    {:ok, port} = :inet.port(listener)

    task =
      Task.async(fn ->
        {:ok, sock} = :gen_tcp.accept(listener, 5_000)
        _ = recv_request(sock)

        head =
          "HTTP/1.1 200 OK\r\n" <>
            "Content-Type: application/x-git-upload-pack-result\r\n" <>
            "Transfer-Encoding: chunked\r\nConnection: close\r\n\r\n"

        :ok = :gen_tcp.send(sock, head)

        _ =
          1..ref_count
          |> Enum.map(&ref_line/1)
          |> Enum.concat([PktLine.flush(), :last])
          |> Enum.reduce_while(:ok, fn piece, :ok ->
            data = if piece == :last, do: "0\r\n\r\n", else: chunk(piece)

            case :gen_tcp.send(sock, data) do
              :ok -> {:cont, :ok}
              {:error, _closed_by_capped_client} -> {:halt, :ok}
            end
          end)

        :gen_tcp.close(sock)
      end)

    try do
      fun.(port)
    after
      Task.await(task, 5_000)
      :gen_tcp.close(listener)
    end
  end

  defp chunk(iodata) do
    data = IO.iodata_to_binary(iodata)
    Integer.to_string(byte_size(data), 16) <> "\r\n" <> data <> "\r\n"
  end

  defp recv_request(sock) do
    case :gen_tcp.recv(sock, 0, 2_000) do
      {:ok, data} ->
        if String.contains?(data, "\r\n\r\n"), do: data, else: data <> recv_request(sock)

      {:error, _} ->
        <<>>
    end
  end

  defp ref_line(i) do
    PktLine.encode("#{Base.encode16(sha(i), case: :lower)} #{ref_name(i)}\n")
  end

  defp ref_name(i), do: "refs/heads/branch-#{String.pad_leading(Integer.to_string(i), 3, "0")}"

  defp sha(i), do: :binary.copy(<<i>>, 20)
end
