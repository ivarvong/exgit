defmodule Exgit.Error do
  @moduledoc """
  Canonical error shape for exgit.

  Library callers pattern-match errors across many modules. Having a
  single shape — `%Exgit.Error{code: atom(), context: map()}` —
  makes that ergonomic; ad-hoc `{:error, atom()}` vs
  `{:error, {atom(), details}}` variants force defensive wrapping
  in every consumer.

  Functions that have stable ad-hoc shapes today (e.g.
  `{:error, :not_found}`) continue to return those for backward
  compatibility. New error paths SHOULD construct `%Exgit.Error{}`
  and emit `{:error, %Exgit.Error{}}`. v1.0 may coalesce all error
  paths onto this struct.

  ## Codes

  Each error carries an atom `:code` that names the kind of failure.
  Well-known codes:

    * `:not_found` — object, ref, or path missing.
    * `:invalid_ref_name` — ref name failed `Exgit.RefName.valid?/1`.
    * `:invalid_hex_header` — a commit/tag header expected 40-char
      hex and got something else.
    * `:malformed_tree_entry` — tree decode failed structurally.
    * `:tree_entry_name_*` — tree entry name rejected for path
      traversal reasons (see `Exgit.Object.Tree.decode/1`).
    * `:sha_mismatch` — content-addressed verification failed.
    * `:zlib_error` — zlib decompression failed on untrusted input.
    * `:resolved_too_large`, `:object_too_large`, `:pack_too_large` —
      pack parser resource-limit trip.
    * `:invalid_ref_name` — defensive ref name validation tripped.
    * `:http_error` — non-2xx response from a transport.
    * `:compare_and_swap_failed` — ref store CAS check failed.

  ## Fields

    * `:code` — the atom code.
    * `:context` — a map of additional structured data (e.g. the
      SHA, the ref name, the declared-vs-actual size). Stable keys
      per code are part of the SemVer public API; ad-hoc debug
      context keys (prefix `_`) are not.
    * `:message` — optional human-readable summary.
  """

  @enforce_keys [:code]
  defstruct code: nil, context: %{}, message: nil

  @type t :: %__MODULE__{
          code: atom(),
          context: map(),
          message: String.t() | nil
        }

  @spec new(atom(), keyword() | map()) :: t()
  def new(code, context \\ %{})

  def new(code, context) when is_map(context) do
    %__MODULE__{code: code, context: context}
  end

  def new(code, context) when is_list(context) do
    {message, ctx} = Keyword.pop(context, :message)
    %__MODULE__{code: code, context: Map.new(ctx), message: message}
  end
end
