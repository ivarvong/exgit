defmodule Exgit.RefName do
  @moduledoc """
  Validation of git ref names per [`git check-ref-format`][1] rules.

  Ref names come from the wire protocol on fetch (`ls-refs` response) and
  must be validated **at the transport boundary** before being joined
  into any filesystem path. A hostile or compromised server can
  advertise a ref name containing `..`, an absolute path, a control
  character, or other garbage; without validation, that name would
  escape the repository root when used in `Path.join(root, ref)`.

  Exgit rejects unsafe names at the transport layer (ls_refs/fetch
  return) and never lets them reach the ref store.

  ## Rules (matching git's C implementation)

  * No component may start with `.`
  * No component may end with `.lock` or `.`
  * No empty component (forbids `//` or leading/trailing `/`)
  * No `..` anywhere
  * No ASCII control chars (< 0x20), DEL (0x7F)
  * No space, `~`, `^`, `:`, `?`, `*`, `[`, `\\`, or `@{`
  * No bare `@`
  * Single-component names are rejected unless they are well-known
    (`HEAD`, `FETCH_HEAD`, `ORIG_HEAD`, `MERGE_HEAD`, `CHERRY_PICK_HEAD`)

  [1]: https://git-scm.com/docs/git-check-ref-format
  """

  @well_known_singletons ~w(HEAD FETCH_HEAD ORIG_HEAD MERGE_HEAD CHERRY_PICK_HEAD)

  @doc "Return true iff `name` is a safe git ref name."
  @spec valid?(term()) :: boolean()
  def valid?(name) when is_binary(name) do
    passes_structural_checks?(name) and
      not has_forbidden_byte?(name) and
      valid_components?(name) and
      (not single_component?(name) or name in @well_known_singletons)
  end

  def valid?(_), do: false

  # Cheap byte-level / structural checks — no iteration over the
  # name's characters, just substring tests. Split out of `valid?/1`
  # so the top-level function stays under Credo's complexity bound.
  defp passes_structural_checks?(""), do: false
  defp passes_structural_checks?("@"), do: false

  defp passes_structural_checks?(name) do
    not String.starts_with?(name, "/") and
      not String.ends_with?(name, "/") and
      not String.ends_with?(name, ".") and
      not String.contains?(name, "..") and
      not String.contains?(name, "@{") and
      not String.contains?(name, "//")
  end

  # --- Internal ---

  # Per git's rules: space, ~, ^, :, ?, *, [, \, and any byte < 0x20
  # or == 0x7F are forbidden.
  defp has_forbidden_byte?(name) do
    Enum.any?(:binary.bin_to_list(name), fn c ->
      c < 0x20 or c == 0x7F or c in ~c" ~^:?*[\\"
    end)
  end

  defp valid_components?(name) do
    Enum.all?(String.split(name, "/"), &valid_component?/1)
  end

  defp valid_component?(""), do: false
  defp valid_component?("." <> _), do: false

  defp valid_component?(c) do
    not String.ends_with?(c, ".lock") and not String.ends_with?(c, ".")
  end

  defp single_component?(name), do: not String.contains?(name, "/")
end
