defprotocol Exgit.Transport do
  @moduledoc """
  Protocol for git transports — HTTP, file, and user-defined (e.g. SSH
  or in-memory). Any struct that implements this protocol can be used
  interchangeably with `Exgit.clone/2`, `Exgit.fetch/3`, and
  `Exgit.push/3`.

  ## Required callbacks

  * `capabilities/1` — returns the server's advertised capability map.
  * `ls_refs/2` — lists refs with optional `prefix:` filters.
  * `fetch/3` — returns `{:ok, pack_bytes, summary}` given `wants` and
    optional `haves:`/`depth:`.
  * `push/4` — performs ref updates and sends the given pack.
  """

  @type ref_entry :: {ref :: String.t(), sha :: binary()}
  @type ref_update :: {ref :: String.t(), old_sha :: binary() | nil, new_sha :: binary() | nil}

  @spec capabilities(t) :: {:ok, map()} | {:error, term()}
  def capabilities(transport)

  @spec ls_refs(t, keyword()) :: {:ok, [ref_entry()]} | {:error, term()}
  def ls_refs(transport, opts)

  @spec fetch(t, [binary()], keyword()) :: {:ok, binary(), map()} | {:error, term()}
  def fetch(transport, wants, opts)

  @spec push(t, [ref_update()], binary(), keyword()) :: {:ok, map()} | {:error, term()}
  def push(transport, updates, pack, opts)
end
