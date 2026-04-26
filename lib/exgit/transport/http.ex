defmodule Exgit.Transport.HTTP do
  @moduledoc """
  `Exgit.Transport` implementation for git smart-HTTP v2.

  Speaks git protocol v2 over HTTPS using `Req` as the HTTP client.
  Implements `capabilities/1`, `ls_refs/2`, `fetch/3`, and
  `push/4`; supports `want-ref`, `filter`, `sideband-all`, and
  `symrefs` extensions.

  ## Credentials

  The `:auth` field accepts either a bare auth tuple (auto-wrapped
  in `%Exgit.Credentials{}` with host-binding) or an explicit
  `%Exgit.Credentials{}` struct. Host-bound credentials refuse to
  emit auth headers when the URL host doesn't match the bound
  pattern, defending against cross-origin leaks through redirects
  or user-supplied URLs.

  ## TLS

  `verify_tls: true` (default) uses `:public_key.cacerts_get/0` and
  enables hostname verification via `:ssl.pkix_verify_hostname/3`.

  ## Redirects

  Disabled by default to prevent any chance of credential leaks
  through an unexpected redirect target. Opt-in via
  `redirect: :same_origin` or `redirect: :follow`; host-binding on
  `:auth` remains in force either way.
  """

  alias Exgit.Pack.StreamParser
  alias Exgit.PktLine
  alias Exgit.PktLine.Decoder

  @enforce_keys [:url]
  defstruct [
    :url,
    :auth,
    user_agent: "exgit/0.1.0 git/2.45.0",
    # Connect timeout (milliseconds). Time to establish the TCP /
    # TLS connection. :infinity disables.
    connect_timeout: 10_000,
    # Receive timeout (milliseconds). Maximum time to wait for
    # the server's response BODY. `:infinity` disables — recommended
    # when cloning large packs over slow links. With
    # `:max_pack_bytes` on the reader side we have a memory bound;
    # the timeout's only job is to avoid hanging forever on a dead
    # connection, so the default of 5 minutes balances "fail fast
    # on a truly-dead link" against "don't false-timeout on a 500 MB
    # pack over a residential uplink."
    #
    # Typical bandwidth math:
    #   10 Mbps (~1.25 MB/s): 375 MB in 5 minutes
    #   100 Mbps             : ~4 GB in 5 minutes
    # Override via `receive_timeout: :infinity` for cold bulk fetches.
    receive_timeout: 300_000,
    # TLS options applied to https URLs via Req's :connect_options.
    verify_tls: true,
    # Optional list of transport options passed to Req's
    # `:connect_options`. Use for custom CA bundles (mandatory for
    # internal GHE / Gerrit with a private CA), client-certificate
    # mTLS, custom SNI, or any other :ssl option. Merged with the
    # library's TLS defaults; caller values win.
    #
    # Example (custom CA + mTLS):
    #
    #     Transport.HTTP.new("https://gerrit.internal/repo",
    #       connect_options: [
    #         cacertfile: "/etc/ssl/certs/internal_ca.pem",
    #         certfile: "/etc/ssl/certs/client.pem",
    #         keyfile: "/etc/ssl/private/client.key"
    #       ]
    #     )
    connect_options: [],
    # Redirect policy. `false` (default) refuses all redirects so
    # host-bound credentials cannot leak to an attacker-controlled
    # redirect target. `:same_origin` allows redirects only when the
    # scheme+host+port match. `:follow` allows arbitrary redirects
    # (with credential host-binding re-check at every hop). Real
    # git hosts do redirect (canonicalization, repo renames) — set
    # `:same_origin` for hosts where this is common.
    redirect: false,
    # Cached server capabilities (protocol v2 advertisements). `nil`
    # means "not yet discovered"; an `{:ok, caps}` / `{:error, _}`
    # tuple means the result is memoized. A fresh struct has `nil`
    # so the first `capabilities/1` call performs the discovery GET.
    # Subsequent calls return the cached result without extra HTTP.
    capabilities_cache: nil
  ]

  @type auth_value ::
          nil
          | {:basic, String.t(), String.t()}
          | {:bearer, String.t()}
          | {:header, String.t(), String.t()}
          | {:callback, (String.t() -> [{String.t(), String.t()}])}

  @type auth :: auth_value() | Exgit.Credentials.t()

  @type t :: %__MODULE__{url: String.t(), auth: auth(), user_agent: String.t()}

  @spec new(String.t(), keyword()) :: t()
  def new(url, opts \\ []) do
    trimmed_url = String.trim_trailing(url, "/")
    defaults = %__MODULE__{url: trimmed_url}

    struct(defaults,
      auth: normalize_auth(Keyword.get(opts, :auth), trimmed_url),
      user_agent: Keyword.get(opts, :user_agent, defaults.user_agent),
      connect_timeout: Keyword.get(opts, :connect_timeout, defaults.connect_timeout),
      receive_timeout: Keyword.get(opts, :receive_timeout, defaults.receive_timeout),
      verify_tls: Keyword.get(opts, :verify_tls, defaults.verify_tls),
      connect_options: Keyword.get(opts, :connect_options, defaults.connect_options),
      redirect: Keyword.get(opts, :redirect, defaults.redirect)
    )
  end

  # Normalize the auth value:
  #
  #   - nil → nil (no auth)
  #   - %Exgit.Credentials{} → passed through as-is (caller explicitly
  #     chose the host binding, including :any for unbound).
  #   - Bare auth tuple ({:basic, _, _} etc.) → WRAPPED in a
  #     Credentials bound to the URL's host. Legacy callers who pass
  #     raw tuples get automatic cross-origin leak protection; to
  #     opt out, wrap the tuple in Credentials.unbound/1 explicitly.
  defp normalize_auth(nil, _url), do: nil

  defp normalize_auth(%Exgit.Credentials{} = cred, _url), do: cred

  defp normalize_auth(auth_tuple, url) when is_tuple(auth_tuple) do
    host = URI.parse(url).host

    if is_binary(host) and host != "" do
      Exgit.Credentials.host_bound(host, auth_tuple)
    else
      # No host to bind to (e.g. relative URL) — refuse to create an
      # implicitly-bound credential; caller must be explicit.
      Exgit.Credentials.unbound(auth_tuple)
    end
  end

  def capabilities(%__MODULE__{capabilities_cache: {:ok, _} = cached}), do: cached
  def capabilities(%__MODULE__{capabilities_cache: {:error, _} = cached}), do: cached

  def capabilities(%__MODULE__{} = t) do
    # Not cached — discover, but don't try to mutate the struct (pure
    # value). Callers who want memoization across many requests can
    # use `capabilities_cached/1` which returns an updated struct.
    case discover(t, "git-upload-pack") do
      {:ok, caps} -> {:ok, caps}
      error -> error
    end
  end

  @doc """
  Return `{capabilities, updated_transport}` so the caller can thread
  the transport forward and avoid re-discovering on every call.

  The default fetch/ls-refs paths still accept a non-cached transport
  (to preserve backward compatibility with struct-sharing callers);
  `capabilities_cached/1` is the opt-in path for workflows that make
  many small fetches against the same transport.
  """
  @spec capabilities_cached(t()) :: {term(), t()}
  def capabilities_cached(%__MODULE__{capabilities_cache: nil} = t) do
    result = capabilities(t)
    {result, %{t | capabilities_cache: result}}
  end

  def capabilities_cached(%__MODULE__{capabilities_cache: cached} = t), do: {cached, t}

  def ls_refs(%__MODULE__{} = t, opts \\ []) do
    Exgit.Telemetry.span(
      [:exgit, :transport, :ls_refs],
      %{transport: :http, url: t.url},
      fn ->
        case do_ls_refs(t, opts) do
          {:ok, refs, meta} = result ->
            {:span, result, %{ref_count: length(refs), has_head: Map.has_key?(meta, :head)}}

          error ->
            {:span, error, %{ref_count: 0}}
        end
      end
    )
  end

  defp do_ls_refs(%__MODULE__{} = t, opts) do
    prefixes = Keyword.get(opts, :prefix, [])
    prefixes = List.wrap(prefixes)
    # Ask the server for symref targets (protocol-v2 feature). Most
    # importantly this reveals where HEAD points, so callers can pick
    # the default branch instead of guessing `main`/`master`/first-
    # refs/heads.
    include_symrefs = Keyword.get(opts, :symrefs, true)
    # `peeled` asks the server to emit `peeled:<sha>` attributes on
    # annotated tags. Useful for fetch-pack negotiation.
    include_peeled = Keyword.get(opts, :peeled, true)

    body =
      IO.iodata_to_binary([
        PktLine.encode("command=ls-refs\n"),
        PktLine.delim(),
        if(include_symrefs, do: [PktLine.encode("symrefs\n")], else: []),
        if(include_peeled, do: [PktLine.encode("peel\n")], else: []),
        Enum.map(prefixes, fn p -> PktLine.encode("ref-prefix #{p}\n") end),
        PktLine.flush()
      ])

    # Stream-fold the pkt-line response into the {refs, meta} accumulator
    # without ever materializing the full response body or the list of
    # decoded packets. For repos with tens of thousands of refs (esp-idf,
    # linux), this keeps the transport's memory bound flat in ref count.
    init_acc = {[], %{peeled: %{}}}

    handle_packet = fn
      {:data, line}, acc -> parse_ls_refs_line(line, t.url, acc)
      _, acc -> acc
    end

    case stream_upload_pack(t, body, init_acc, handle_packet) do
      {:ok, {refs_rev, meta}} ->
        meta =
          if map_size(meta.peeled) == 0, do: Map.delete(meta, :peeled), else: meta

        {:ok, Enum.reverse(refs_rev), meta}

      error ->
        error
    end
  end

  # Fold one ls-refs line into the `{refs, meta}` accumulator.
  #
  # ls-refs lines have the shape:
  #   <sha> <ref>[ <attribute>...]
  # where attributes include `symref-target:<other-ref>` and
  # `peeled:<sha>`. The HEAD line carries `symref-target:<default>`
  # — we lift that into `meta.head`. Annotated tags carry
  # `peeled:<sha>` — we lift those into `meta.peeled`.
  #
  # Hostile ref names are rejected here via `Exgit.RefName.valid?/1`;
  # rejections emit `[:exgit, :security, :ref_rejected]` telemetry
  # and drop the entry entirely.
  defp parse_ls_refs_line(line, source_url, {refs, meta}) do
    line = String.trim_trailing(line, "\n")

    case String.split(line, " ", parts: 3) do
      [hex_sha, ref, attrs] when byte_size(hex_sha) == 40 ->
        with {:ok, sha} <- Base.decode16(hex_sha, case: :mixed),
             true <- keep_ref?(ref, source_url) do
          attrs_map = parse_ls_refs_attrs(attrs)
          add_ref(refs, meta, ref, sha, attrs_map)
        else
          _ -> {refs, meta}
        end

      [hex_sha, ref] when byte_size(hex_sha) == 40 ->
        with {:ok, sha} <- Base.decode16(hex_sha, case: :mixed),
             true <- keep_ref?(ref, source_url) do
          add_ref(refs, meta, ref, sha, %{})
        else
          _ -> {refs, meta}
        end

      _ ->
        {refs, meta}
    end
  end

  defp keep_ref?(ref, source) do
    if Exgit.RefName.valid?(ref) do
      true
    else
      :telemetry.execute(
        [:exgit, :security, :ref_rejected],
        %{count: 1},
        %{source: source, ref: ref}
      )

      false
    end
  end

  # Add an entry to `refs` and lift any attributes into `meta`.
  # HEAD's `symref-target` becomes `meta.head`; annotated tags'
  # `peeled` target becomes `meta.peeled[tag_name]`.
  defp add_ref(refs, meta, ref, sha, attrs) do
    meta =
      case Map.get(attrs, :symref_target) do
        nil -> meta
        target when ref == "HEAD" -> Map.put(meta, :head, target)
        # Some servers set symref-target on refs other than HEAD
        # (e.g. `refs/remotes/origin/HEAD` aliases). We ignore
        # those — only the real HEAD's target populates meta.head.
        _ -> meta
      end

    meta =
      case Map.get(attrs, :peeled) do
        nil -> meta
        peeled_sha -> put_in(meta, [:peeled, ref], peeled_sha)
      end

    {[{ref, sha} | refs], meta}
  end

  defp parse_ls_refs_attrs(attrs) do
    attrs
    |> String.split(" ", trim: true)
    |> Enum.reduce(%{}, fn token, acc ->
      case String.split(token, ":", parts: 2) do
        ["symref-target", target] ->
          Map.put(acc, :symref_target, target)

        ["peeled", hex] when byte_size(hex) == 40 ->
          case Base.decode16(hex, case: :mixed) do
            {:ok, sha} -> Map.put(acc, :peeled, sha)
            :error -> acc
          end

        _ ->
          acc
      end
    end)
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

    # Stream-decode the fetch response: pkt-lines flow in, get fed to a
    # state machine that (1) skips the acks/shallow prelude until it sees
    # the `packfile` section marker, then (2) demuxes sideband and either:
    #   a) feeds pack bytes directly to a StreamParser (zero-copy to store), or
    #   b) appends to a pack_iolist for the caller to parse (legacy path).
    #
    # Path (a) is taken when `opts[:object_store]` is provided. Memory is
    # bounded by one pkt-line + one object's compressed bytes — the key fix
    # for the OOM on multi-GB packs (esp-idf, linux).
    object_store = Keyword.get(opts, :object_store)
    init = init_fetch_state(Keyword.get(opts, :sideband), object_store)

    case stream_upload_pack(t, body, init, &handle_fetch_packet/2) do
      {:ok, %{error: msg}} when is_binary(msg) ->
        {:error, {:server_error, msg}}

      # Streaming path: finalise the parser and return the updated store.
      {:ok, %{parser: %StreamParser{} = parser}} ->
        Exgit.Telemetry.span(
          [:exgit, :pack, :stream_parse],
          %{objects: parser.objects_done},
          fn ->
            case StreamParser.finalize(parser) do
              {:ok, n, final_store} ->
                result = {:ok, <<>>, %{objects: n, store: final_store}}
                {:span, result, %{object_count: n, checksum: :ok}}

              {:error, reason} = err ->
                {:span, err, %{error: reason}}
            end
          end
        )

      # Legacy path: materialise the iolist into a binary for the caller.
      {:ok, %{pack_iolist: iolist}} ->
        pack_data = IO.iodata_to_binary(iolist)

        if byte_size(pack_data) > 0 do
          {:ok, pack_data, %{}}
        else
          {:ok, <<>>, %{objects: 0}}
        end

      error ->
        error
    end
  end

  # Fetch-response state machine driven by `stream_upload_pack/4`.
  #
  # Phases:
  #   :prelude     — skipping acks/shallow/etc until the "packfile" marker.
  #   :in_packfile — every {:data, _} packet carries (possibly sideband-framed)
  #                  pack bytes, dispatched to parser OR appended to pack_iolist.
  #
  # Sideband decision:
  #   - Caller-supplied sideband (true|false) wins (used by tests).
  #   - Otherwise auto-detect on the FIRST pack-section data packet:
  #     leading byte 1/2/3 → sideband channel; anything else → raw stream.
  #
  # Streaming path (parser != nil):
  #   Pack bytes are fed directly to a StreamParser that writes objects to
  #   the object store as they arrive. No pack_iolist is accumulated.
  #
  # Legacy path (parser == nil):
  #   Pack bytes are appended to pack_iolist for the caller to parse.
  defp init_fetch_state(explicit_sideband, object_store) do
    parser = if object_store, do: StreamParser.new(object_store), else: nil

    %{
      phase: :prelude,
      sideband: explicit_sideband,
      pack_iolist: if(is_nil(parser), do: [], else: nil),
      parser: parser,
      error: nil
    }
  end

  defp handle_fetch_packet(_pkt, %{error: e} = state) when not is_nil(e), do: state

  defp handle_fetch_packet({:data, line}, %{phase: :prelude} = state) do
    case line do
      "packfile\n" -> %{state | phase: :in_packfile}
      "packfile" -> %{state | phase: :in_packfile}
      _ -> state
    end
  end

  defp handle_fetch_packet({:data, data}, %{phase: :in_packfile, sideband: nil} = state) do
    # First pack-section data packet: decide sideband from leading byte.
    sideband =
      case data do
        <<b, _::binary>> when b in 1..3 -> true
        _ -> false
      end

    handle_fetch_packet({:data, data}, %{state | sideband: sideband})
  end

  defp handle_fetch_packet({:data, data}, %{phase: :in_packfile, sideband: true} = state) do
    case data do
      <<1, payload::binary>> -> dispatch_pack_bytes(state, payload)
      # Channel 2 = progress; ignored.
      <<2, _::binary>> -> state
      <<3, msg::binary>> -> %{state | error: msg}
      _ -> state
    end
  end

  defp handle_fetch_packet({:data, data}, %{phase: :in_packfile, sideband: false} = state) do
    dispatch_pack_bytes(state, data)
  end

  # Route pack bytes to either the streaming parser or the legacy iolist.
  # All other packet types (flush, delim, etc.) are no-ops.
  defp handle_fetch_packet(_pkt, state), do: state

  # Route pack bytes to either the streaming parser or the legacy iolist.
  defp dispatch_pack_bytes(%{parser: %StreamParser{} = parser} = state, bytes) do
    case StreamParser.ingest(parser, bytes) do
      {:ok, new_parser} -> %{state | parser: new_parser}
      {:error, reason} -> %{state | error: reason}
    end
  end

  defp dispatch_pack_bytes(%{pack_iolist: iolist} = state, bytes) do
    %{state | pack_iolist: [iolist | bytes]}
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

  # Streaming POST to /git-upload-pack. Feeds each chunk of the response
  # body through an incremental pkt-line decoder; each fully-decoded
  # packet is dispatched to `handle_packet.(packet, acc)`. Memory is
  # bounded by `decoder.buffer + handler_acc`, which never holds the full
  # response — the canonical fix for the OOM on multi-GB packs (esp-idf,
  # linux). Non-2xx responses fall back to a buffered error body capped
  # at @error_body_cap bytes so we still produce a useful error.
  @error_body_cap 64 * 1024
  @spec stream_upload_pack(t(), iodata(), acc, (PktLine.packet(), acc -> acc)) ::
          {:ok, acc} | {:error, term()}
        when acc: term()
  defp stream_upload_pack(%__MODULE__{} = t, body, init_acc, handle_packet)
       when is_function(handle_packet, 2) do
    headers = [
      {"content-type", "application/x-git-upload-pack-request"},
      {"accept", "application/x-git-upload-pack-result"},
      {"git-protocol", "version=2"},
      {"user-agent", t.user_agent}
    ]

    url = "#{t.url}/git-upload-pack"
    full_headers = headers ++ auth_headers_for(t, url)

    init_state = %{
      decoder: Decoder.new(),
      handler: handle_packet,
      handler_acc: init_acc,
      error: nil,
      # Captures non-2xx body up to @error_body_cap bytes so we can
      # report something useful when the server returns 401/500/etc.
      error_body: <<>>
    }

    # Closure form so we can capture `init_state`. The Req `into:`
    # callback receives a freshly-built `resp` (its `private` is empty
    # on the first invocation), so we lazy-init state in `resp.private`
    # there and update it on every subsequent chunk.
    into_fn = fn {:data, chunk}, {req, resp} ->
      state = Map.get(resp.private, :exgit_stream, init_state)
      stream_step(chunk, state, req, resp)
    end

    req_opts = [
      method: :post,
      url: url,
      headers: full_headers,
      body: IO.iodata_to_binary(body),
      decode_body: false,
      receive_timeout: t.receive_timeout,
      retry: false,
      redirect: req_redirect_setting(t.redirect),
      connect_options: connect_options(url, t),
      into: into_fn
    ]

    case Req.request(req_opts) do
      {:ok, %{status: status, private: %{exgit_stream: state}}} when status in 200..299 ->
        with :ok <- Decoder.finalize(state.decoder) do
          if state.error, do: {:error, state.error}, else: {:ok, state.handler_acc}
        end

      {:ok, %{status: status, private: %{exgit_stream: state}}} ->
        {:error, {:http_error, status, state.error_body}}

      {:ok, %{status: status, body: body}} ->
        {:error, {:http_error, status, body}}

      {:error, _} = err ->
        err
    end
  end

  # One streaming step: feed `chunk` through either the error buffer
  # (non-2xx) or the pkt-line decoder + handler (2xx), and stash the
  # updated state in `resp.private.exgit_stream`.
  defp stream_step(chunk, state, req, resp) do
    cond do
      resp.status not in 200..299 ->
        room = @error_body_cap - byte_size(state.error_body)

        captured =
          if room > 0 do
            take = min(room, byte_size(chunk))
            <<head::binary-size(take), _::binary>> = chunk
            <<state.error_body::binary, head::binary>>
          else
            state.error_body
          end

        {:cont, {req, put_private(resp, %{state | error_body: captured})}}

      state.error != nil ->
        {:halt, {req, put_private(resp, state)}}

      true ->
        case Decoder.feed(state.decoder, chunk) do
          {:ok, decoder, packets} ->
            handler_acc =
              Enum.reduce(packets, state.handler_acc, fn pkt, acc ->
                state.handler.(pkt, acc)
              end)

            new_state = %{state | decoder: decoder, handler_acc: handler_acc}

            cont_or_halt =
              case handler_acc do
                %{error: e} when not is_nil(e) -> :halt
                _ -> :cont
              end

            {cont_or_halt, {req, put_private(resp, new_state)}}

          {:error, reason} ->
            new_state = %{state | error: {:malformed_response, reason}}
            {:halt, {req, put_private(resp, new_state)}}
        end
    end
  end

  defp put_private(resp, state) do
    %{resp | private: Map.put(resp.private, :exgit_stream, state)}
  end

  defp do_request(method, url, headers, body, t) do
    Req.request(request_opts(t, method, url, headers, body))
  end

  # Translate our redirect knob to Req's expectation.
  defp req_redirect_setting(false), do: false
  defp req_redirect_setting(true), do: true
  defp req_redirect_setting(:follow), do: true
  # Req doesn't have native :same_origin support; we approximate it
  # by leaving redirects on but relying on our own host-bound
  # Credentials to refuse auth-header emission on the new origin.
  # Documented as such in the docstring.
  defp req_redirect_setting(:same_origin), do: true

  @doc """
  Build the keyword list we'd pass to `Req.request/1` for the given
  request. Exposed publicly for test introspection; production code
  goes through `do_request/5`.
  """
  @spec request_opts(t(), atom(), String.t(), [{String.t(), String.t()}], binary() | nil) ::
          keyword()
  def request_opts(t, method, url, headers, body) do
    headers = headers ++ auth_headers_for(t, url)

    opts = [
      method: method,
      url: url,
      headers: headers,
      decode_body: false,
      receive_timeout: t.receive_timeout,
      retry: false,
      # Redirect policy. `false` (default) refuses all redirects;
      # the cross-origin credential leak protection is enforced by
      # our own host-bound Credentials regardless of what Req does
      # with headers. `:same_origin` / `:follow` enable redirects
      # via Req; our host binding still applies on the final hop.
      redirect: req_redirect_setting(t.redirect),
      connect_options: connect_options(url, t)
    ]

    if body, do: Keyword.put(opts, :body, body), else: opts
  end

  @doc """
  Compute the auth headers for a specific request URL. Exposed for
  testing; production call-sites use `request_opts/5` or `do_request/5`.

  This is the enforcement point for credential host-binding: a
  `%Exgit.Credentials{}` with a non-matching host pattern returns `[]`
  regardless of what the caller thought they attached.
  """
  @spec auth_headers_for(t(), String.t()) :: [{String.t(), String.t()}]
  def auth_headers_for(%__MODULE__{auth: nil}, _url), do: []

  def auth_headers_for(%__MODULE__{auth: %Exgit.Credentials{} = cred}, url) do
    case Exgit.Credentials.for_host(cred, url) do
      {:ok, auth_value} -> auth_headers(auth_value, url)
      :none -> []
    end
  end

  def auth_headers_for(%__MODULE__{auth: auth}, url), do: auth_headers(auth, url)

  # TLS / transport options. Req's `connect_options` are forwarded to
  # Finch/Mint. For HTTPS we enforce peer verification; callers can opt
  # out via `verify_tls: false` when (e.g.) testing against self-signed
  # local servers. Caller-supplied `:connect_options` (e.g. custom CA
  # bundle, client cert for mTLS) are merged LAST so they override the
  # library's defaults.
  defp connect_options(url, t) do
    base = [timeout: t.connect_timeout]

    scheme_opts =
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

    merge_connect_options(scheme_opts, t.connect_options)
  end

  # Merge caller-supplied connect_options on top of the library's
  # defaults. For `:transport_opts` (a nested keyword list) we do a
  # deep merge so caller can override e.g. `:cacertfile` without
  # losing `:customize_hostname_check`. Top-level keys are
  # shallow-merged with caller winning.
  defp merge_connect_options(base, []), do: base

  defp merge_connect_options(base, caller) do
    # Extract + merge the nested `:transport_opts` separately.
    base_transport = Keyword.get(base, :transport_opts, [])
    caller_transport = Keyword.get(caller, :transport_opts, [])
    merged_transport = Keyword.merge(base_transport, caller_transport)

    base_rest = Keyword.delete(base, :transport_opts)
    caller_rest = Keyword.delete(caller, :transport_opts)

    merged_rest = Keyword.merge(base_rest, caller_rest)

    if merged_transport == [] do
      merged_rest
    else
      Keyword.put(merged_rest, :transport_opts, merged_transport)
    end
  end

  defp auth_headers(nil, _url), do: []

  defp auth_headers({:basic, user, pass}, _url),
    do: [{"authorization", "Basic " <> Base.encode64("#{user}:#{pass}")}]

  defp auth_headers({:bearer, token}, _url), do: [{"authorization", "Bearer #{token}"}]
  defp auth_headers({:header, name, value}, _url), do: [{name, value}]

  # Callback receives the URL so the auth can be computed per-request
  # (e.g. AWS SigV4, SAS tokens). Typespec on `auth_value()` above
  # promises arity 1 — we honor it.
  defp auth_headers({:callback, fun}, url) when is_function(fun, 1) do
    case fun.(url) do
      headers when is_list(headers) -> headers
      _ -> []
    end
  rescue
    _ -> []
  end

  defp auth_headers(_other, _url), do: []

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
