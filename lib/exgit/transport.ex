defprotocol Exgit.Transport do
  @moduledoc """
  Protocol for git transports — HTTP, file, and user-defined (e.g. SSH
  or in-memory). Any struct that implements this protocol can be used
  interchangeably with `Exgit.clone/2`, `Exgit.fetch/3`, and
  `Exgit.push/3`.

  ## Required callbacks

  * `capabilities/1` — returns the server's advertised capability map.
  * `ls_refs/2` — lists refs with optional `prefix:` filters. Returns
    `{:ok, refs, meta}` where `refs` is always a list of
    `{ref_name, sha}` 2-tuples and `meta` carries protocol-v2 side-
    channel data (HEAD symref target, peeled tag targets, etc.).
  * `fetch/3` — returns `{:ok, pack_bytes, summary}` given `wants` and
    optional `haves:`/`depth:`.
  * `push/4` — performs ref updates and sends the given pack.
  """

  @type ref_entry :: {ref :: String.t(), sha :: binary()}
  @type ref_update :: {ref :: String.t(), old_sha :: binary() | nil, new_sha :: binary() | nil}

  @typedoc """
  Side-channel metadata from an `ls_refs/2` call. Keys:

    * `:head` — the ref name that HEAD symbolically points at
      (e.g. `"refs/heads/main"`), when the server advertises it via
      protocol-v2 `symrefs`. Absent for servers that don't, or for
      repositories with a detached HEAD.
    * `:peeled` — `%{tag_ref => peeled_target_sha}`. Only populated
      for annotated tags when the server sends `peeled:<sha>` in
      the ls-refs response. Useful for `have` negotiation.

  Additional keys may be added in future versions; consumers should
  treat the map as open.
  """
  @type ls_refs_meta :: %{
          optional(:head) => String.t(),
          optional(:peeled) => %{String.t() => binary()}
        }

  @spec capabilities(t) :: {:ok, map()} | {:error, term()}
  def capabilities(transport)

  @spec ls_refs(t, keyword()) :: {:ok, [ref_entry()], ls_refs_meta()} | {:error, term()}
  def ls_refs(transport, opts)

  @spec fetch(t, [binary()], keyword()) :: {:ok, binary(), map()} | {:error, term()}
  def fetch(transport, wants, opts)

  @spec push(t, [ref_update()], binary(), keyword()) :: {:ok, map()} | {:error, term()}
  def push(transport, updates, pack, opts)
end
