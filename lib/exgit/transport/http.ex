defmodule Exgit.Transport.HTTP do
  alias Exgit.PktLine

  @enforce_keys [:url]
  defstruct [
    :url,
    :auth,
    user_agent: "exgit/0.1.0 git/2.45.0",
    # Timeouts (milliseconds). :infinity disables. Defaults chosen so a
    # pathological server can't hang an agent loop indefinitely.
    connect_timeout: 10_000,
    receive_timeout: 60_000,
    # TLS options applied to https URLs via Req's :connect_options.
    verify_tls: true
  ]

  @type auth ::
          nil
          | {:basic, String.t(), String.t()}
          | {:bearer, String.t()}
          | {:header, String.t(), String.t()}
          | {:callback, (Req.Request.t() -> [{String.t(), String.t()}])}

  @type t :: %__MODULE__{url: String.t(), auth: auth(), user_agent: String.t()}

  @spec new(String.t(), keyword()) :: t()
  def new(url, opts \\ []) do
    defaults = %__MODULE__{url: String.trim_trailing(url, "/")}

    struct(defaults,
      auth: Keyword.get(opts, :auth),
      user_agent: Keyword.get(opts, :user_agent, defaults.user_agent),
      connect_timeout: Keyword.get(opts, :connect_timeout, defaults.connect_timeout),
      receive_timeout: Keyword.get(opts, :receive_timeout, defaults.receive_timeout),
      verify_tls: Keyword.get(opts, :verify_tls, defaults.verify_tls)
    )
  end

  def capabilities(%__MODULE__{} = t) do
    case discover(t, "git-upload-pack") do
      {:ok, caps} -> {:ok, caps}
      error -> error
    end
  end

  def ls_refs(%__MODULE__{} = t, opts \\ []) do
    Exgit.Telemetry.span(
      [:exgit, :transport, :ls_refs],
      %{transport: :http, url: t.url},
      fn ->
        case do_ls_refs(t, opts) do
          {:ok, refs} = result -> {:span, result, %{ref_count: length(refs)}}
          error -> {:span, error, %{ref_count: 0}}
        end
      end
    )
  end

  defp do_ls_refs(%__MODULE__{} = t, opts) do
    prefixes = Keyword.get(opts, :prefix, [])
    prefixes = List.wrap(prefixes)

    body =
      IO.iodata_to_binary([
        PktLine.encode("command=ls-refs\n"),
        PktLine.delim(),
        Enum.map(prefixes, fn p -> PktLine.encode("ref-prefix #{p}\n") end),
        PktLine.flush()
      ])

    case post_upload_pack(t, body) do
      {:ok, response_body} ->
        refs =
          response_body
          |> PktLine.decode_stream()
          |> Enum.flat_map(fn
            {:data, line} ->
              line = String.trim_trailing(line, "\n")

              case String.split(line, " ", parts: 2) do
                [hex_sha, ref] when byte_size(hex_sha) == 40 ->
                  [{ref, Base.decode16!(hex_sha, case: :mixed)}]

                _ ->
                  []
              end

            _ ->
              []
          end)

        {:ok, refs}

      error ->
        error
    end
  end

  def fetch(%__MODULE__{} = t, wants, opts \\ []) do
    Exgit.Telemetry.span(
      [:exgit, :transport, :fetch],
      %{transport: :http, url: t.url, wants_count: length(wants)},
      fn ->
        case do_fetch(t, wants, opts) do
          {:ok, pack_bytes, summary} = result ->
            {:span, result,
             %{
               result_bytes: byte_size(pack_bytes),
               object_count: Map.get(summary, :objects, 0)
             }}

          error ->
            {:span, error, %{result_bytes: 0, object_count: 0}}
        end
      end
    )
  end

  defp do_fetch(%__MODULE__{} = t, wants, opts) do
    # Negotiation rules:
    #   - For the REQUEST, only ask for features the server advertises.
    #     Sending an unadvertised capability can cause some servers to
    #     return an empty response.
    #   - For the RESPONSE, sideband framing is auto-detected regardless
    #     of what the client asked for (some servers always frame).
    {req_sideband, req_thin, req_ofs} = resolve_requested_features(t, opts)

    haves = Keyword.get(opts, :haves, [])
    depth = Keyword.get(opts, :depth)

    sideband = req_sideband
    thin_pack = req_thin
    ofs_delta = req_ofs

    want_lines = Enum.map(wants, fn sha -> PktLine.encode("want #{hex(sha)}\n") end)

    have_lines =
      if haves != [] do
        Enum.map(haves, fn sha -> PktLine.encode("have #{hex(sha)}\n") end)
      else
        []
      end

    depth_lines =
      if depth do
        [PktLine.encode("deepen #{depth}\n")]
      else
        []
      end

    filter_lines =
      case Keyword.get(opts, :filter) do
        nil -> []
        :none -> []
        spec -> [PktLine.encode("filter #{spec}\n")]
      end

    capability_lines =
      Enum.flat_map(
        [
          {sideband, "sideband-all\n"},
          {thin_pack, "thin-pack\n"},
          {ofs_delta, "ofs-delta\n"},
          {true, "no-progress\n"}
        ],
        fn
          {true, line} -> [PktLine.encode(line)]
          _ -> []
        end
      )

    # Git protocol v2 request format for `fetch`:
    #   - command=fetch\n
    #   - delim-pkt
    #   - arguments: want, have, capabilities (sideband-all, thin-pack,
    #     ofs-delta, no-progress, filter, etc.), done
    #   - flush-pkt
    body =
      IO.iodata_to_binary([
        PktLine.encode("command=fetch\n"),
        PktLine.delim(),
        capability_lines,
        want_lines,
        have_lines,
        depth_lines,
        filter_lines,
        PktLine.encode("done\n"),
        PktLine.flush()
      ])

    case post_upload_pack(t, body) do
      {:ok, response_body} ->
        # Sideband is auto-detected in the response regardless of what
        # the client asked for. The explicit `:sideband` kw overrides
        # (needed by test cases that simulate specific framings).
        parse_fetch_response(response_body, Keyword.take(opts, [:sideband]))

      error ->
        error
    end
  end

  # Returns `{sideband, thin_pack, ofs_delta}` for the REQUEST. Honors
  # explicit caller overrides; otherwise intersects with server's
  # advertised `fetch` features.
  defp resolve_requested_features(t, opts) do
    has_override? = fn key -> Keyword.has_key?(opts, key) end

    if has_override?.(:sideband) or has_override?.(:thin_pack) or has_override?.(:ofs_delta) do
      {Keyword.get(opts, :sideband, false), Keyword.get(opts, :thin_pack, false),
       Keyword.get(opts, :ofs_delta, false)}
    else
      case capabilities(t) do
        {:ok, caps} ->
          fetch_caps = String.split(Map.get(caps, "fetch", ""), " ", trim: true)

          {"sideband-all" in fetch_caps, "thin-pack" in fetch_caps, "ofs-delta" in fetch_caps}

        _ ->
          {false, false, false}
      end
    end
  end

  def push(%__MODULE__{} = t, updates, pack_bytes, opts \\ []) do
    Exgit.Telemetry.span(
      [:exgit, :transport, :push],
      %{
        transport: :http,
        url: t.url,
        update_count: length(updates),
        pack_bytes: byte_size(pack_bytes)
      },
      fn -> do_push(t, updates, pack_bytes, opts) end
    )
  end

  defp do_push(%__MODULE__{} = t, updates, pack_bytes, _opts) do
    # receive-pack uses the v1-style request body
    update_lines =
      Enum.map(updates, fn {ref, old_sha, new_sha} ->
        old = if old_sha, do: hex(old_sha), else: String.duplicate("0", 40)
        new = if new_sha, do: hex(new_sha), else: String.duplicate("0", 40)
        PktLine.encode("#{old} #{new} #{ref}\0 report-status\n")
      end)

    body = IO.iodata_to_binary([update_lines, PktLine.flush(), pack_bytes])

    headers = [
      {"content-type", "application/x-git-receive-pack-request"},
      {"git-protocol", "version=2"},
      {"user-agent", t.user_agent}
    ]

    url = "#{t.url}/git-receive-pack"

    case do_request(:post, url, headers, body, t) do
      {:ok, %{status: status, body: resp_body}} when status in 200..299 ->
        {:ok, parse_push_report(resp_body)}

      {:ok, %{status: status, body: resp_body}} ->
        {:error, {:http_error, status, resp_body}}

      {:error, _} = err ->
        err
    end
  end

  # --- Discovery ---

  defp discover(t, service) do
    url = "#{t.url}/info/refs?service=#{service}"

    headers = [
      {"git-protocol", "version=2"},
      {"user-agent", t.user_agent}
    ]

    case do_request(:get, url, headers, nil, t) do
      {:ok, %{status: 200, body: body}} ->
        parse_capabilities(body)

      {:ok, %{status: status}} ->
        {:error, {:discovery_failed, status}}

      {:error, _} = err ->
        err
    end
  end

  # Capabilities are stored under string keys to avoid atom-table DoS from
  # untrusted server input. Well-known capabilities additionally expose
  # structured values (e.g. :version -> integer).
  defp parse_capabilities(body) do
    packets = PktLine.decode_all(body)

    caps =
      packets
      |> Enum.flat_map(fn
        {:data, line} ->
          line = String.trim_trailing(line, "\n")
          parse_capability_line(line)

        _ ->
          []
      end)
      |> Map.new()

    if Map.get(caps, :version) == 2 do
      {:ok, caps}
    else
      {:error, :server_does_not_support_v2}
    end
  end

  defp parse_capability_line(""), do: []
  defp parse_capability_line("version 2"), do: [{:version, 2}]
  defp parse_capability_line("version 1"), do: [{:version, 1}]

  defp parse_capability_line(line) do
    case String.split(line, "=", parts: 2) do
      [name, value] -> [{name, value}]
      [name] -> [{name, true}]
    end
  end

  # --- Fetch response parsing ---

  defp parse_fetch_response(body, opts) do
    packets = PktLine.decode_all(body)

    # The fetch response has sections: acknowledgments, shallow info, then packfile
    {_before_pack, pack_packets} = split_at_packfile(packets)

    # Auto-detect sideband framing. Some servers (GitHub) apply it
    # regardless of client declaration. We check the first data pkt-line
    # of the pack section: if it starts with a channel byte (1-3)
    # AND the caller didn't explicitly disable sideband, demux.
    sideband = decide_sideband(pack_packets, opts)

    pack_data =
      pack_packets
      |> Enum.flat_map(&demux_pack_packet(&1, sideband))
      |> IO.iodata_to_binary()

    if byte_size(pack_data) > 0 do
      {:ok, pack_data, %{}}
    else
      {:ok, <<>>, %{objects: 0}}
    end
  catch
    {:server_error, msg} -> {:error, {:server_error, msg}}
  end

  defp decide_sideband(pack_packets, opts) do
    case Keyword.get(opts, :sideband) do
      nil ->
        # Auto-detect from the first data pkt-line. Sideband channel
        # bytes are 1, 2, or 3; a plain PACK stream never starts with
        # those inside a pkt-line.
        case Enum.find(pack_packets, &match?({:data, _}, &1)) do
          {:data, <<b, _::binary>>} when b in [1, 2, 3] -> true
          _ -> false
        end

      explicit ->
        explicit
    end
  end

  # When sideband framing is in effect, each pack pkt-line is prefixed
  # with a channel byte (1=pack, 2=progress, 3=error). Without sideband
  # the pkt-line contains the pack bytes directly and must not be
  # rewritten.
  defp demux_pack_packet({:data, <<1, data::binary>>}, true), do: [data]
  defp demux_pack_packet({:data, <<2, _progress::binary>>}, true), do: []
  defp demux_pack_packet({:data, <<3, error::binary>>}, true), do: throw({:server_error, error})
  defp demux_pack_packet({:data, data}, false), do: [data]
  defp demux_pack_packet(_, _), do: []

  defp split_at_packfile(packets) do
    case Enum.split_while(packets, fn
           {:data, "packfile\n"} -> false
           {:data, "packfile"} -> false
           _ -> true
         end) do
      {before, [{:data, _} | after_pack]} -> {before, after_pack}
      {before, []} -> {before, []}
    end
  end

  # --- Push response parsing ---

  defp parse_push_report(body) do
    packets = PktLine.decode_all(body)

    ref_results =
      packets
      |> Enum.flat_map(fn
        {:data, "unpack ok\n"} -> []
        {:data, <<"ok ", ref::binary>>} -> [{String.trim(ref), :ok}]
        {:data, <<"ng ", rest::binary>>} -> [{String.trim(rest), :error}]
        _ -> []
      end)

    %{ref_results: ref_results}
  end

  # --- HTTP helpers ---

  defp post_upload_pack(t, body) do
    headers = [
      {"content-type", "application/x-git-upload-pack-request"},
      {"accept", "application/x-git-upload-pack-result"},
      {"git-protocol", "version=2"},
      {"user-agent", t.user_agent}
    ]

    url = "#{t.url}/git-upload-pack"

    case do_request(:post, url, headers, body, t) do
      {:ok, %{status: status, body: resp_body}} when status in 200..299 ->
        {:ok, resp_body}

      {:ok, %{status: status, body: resp_body}} ->
        {:error, {:http_error, status, resp_body}}

      {:error, _} = err ->
        err
    end
  end

  defp do_request(method, url, headers, body, t) do
    headers = headers ++ auth_headers(t.auth)

    opts =
      [
        method: method,
        url: url,
        headers: headers,
        decode_body: false,
        receive_timeout: t.receive_timeout,
        retry: false,
        connect_options: connect_options(url, t)
      ]

    opts = if body, do: Keyword.put(opts, :body, body), else: opts

    Req.request(opts)
  end

  # TLS / transport options. Req's `connect_options` are forwarded to
  # Finch/Mint. For HTTPS we enforce peer verification; callers can opt
  # out via `verify_tls: false` when (e.g.) testing against self-signed
  # local servers.
  defp connect_options(url, t) do
    base = [timeout: t.connect_timeout]

    case URI.parse(url) do
      %URI{scheme: "https"} ->
        if t.verify_tls do
          base ++
            [
              transport_opts: [
                verify: :verify_peer,
                cacerts: :public_key.cacerts_get(),
                depth: 3,
                customize_hostname_check: [
                  match_fun: :public_key.pkix_verify_hostname_match_fun(:https)
                ]
              ]
            ]
        else
          base ++ [transport_opts: [verify: :verify_none]]
        end

      _ ->
        base
    end
  end

  defp auth_headers(nil), do: []

  defp auth_headers({:basic, user, pass}),
    do: [{"authorization", "Basic " <> Base.encode64("#{user}:#{pass}")}]

  defp auth_headers({:bearer, token}), do: [{"authorization", "Bearer #{token}"}]
  defp auth_headers({:header, name, value}), do: [{name, value}]

  defp auth_headers({:callback, fun}) do
    fun.()
  end

  defp hex(sha) when byte_size(sha) == 20, do: Base.encode16(sha, case: :lower)
end

defimpl Inspect, for: Exgit.Transport.HTTP do
  import Inspect.Algebra

  # Credentials live on %HTTP{}. Default Inspect would dump them into any
  # crash log, SASL report, or IEx session. Always redact.
  def inspect(%Exgit.Transport.HTTP{} = t, opts) do
    redacted = %{t | auth: redact(t.auth)}
    Inspect.Any.inspect(redacted, opts)
  end

  defp redact(nil), do: nil
  defp redact({:basic, user, _pass}), do: {:basic, user, "***"}
  defp redact({:bearer, _}), do: {:bearer, "***"}
  defp redact({:header, name, _}), do: {:header, name, "***"}
  defp redact({:callback, _}), do: {:callback, :fun}
  defp redact(_), do: :redacted

  # Suppress unused-import warning from concat/2 et al — we keep the
  # import in case future formatting needs it.
  _ = &concat/2
end

defimpl Exgit.Transport, for: Exgit.Transport.HTTP do
  defdelegate capabilities(t), to: Exgit.Transport.HTTP
  defdelegate ls_refs(t, opts), to: Exgit.Transport.HTTP
  defdelegate fetch(t, wants, opts), to: Exgit.Transport.HTTP
  defdelegate push(t, updates, pack, opts), to: Exgit.Transport.HTTP
end
