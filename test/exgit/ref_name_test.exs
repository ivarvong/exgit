defmodule Exgit.RefNameTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  @moduletag :property

  alias Exgit.RefName

  describe "valid?/1 — git check-ref-format rules" do
    test "accepts canonical ref names" do
      assert RefName.valid?("refs/heads/main")
      assert RefName.valid?("refs/heads/feature/foo")
      assert RefName.valid?("refs/tags/v1.0.0")
      assert RefName.valid?("refs/remotes/origin/main")
      assert RefName.valid?("HEAD")
    end

    test "rejects empty and whitespace" do
      refute RefName.valid?("")
      refute RefName.valid?(" ")
      refute RefName.valid?("refs/heads/ with space")
    end

    test "rejects path traversal" do
      refute RefName.valid?("refs/heads/../../../../tmp/pwned")
      refute RefName.valid?("../escape")
      refute RefName.valid?("refs/heads/..")
      refute RefName.valid?("refs/..heads/main")
    end

    test "rejects leading / and trailing /" do
      refute RefName.valid?("/refs/heads/main")
      refute RefName.valid?("refs/heads/main/")
    end

    test "rejects double slashes" do
      refute RefName.valid?("refs//heads/main")
    end

    test "rejects components starting with ." do
      refute RefName.valid?("refs/heads/.hidden")
      refute RefName.valid?(".refs/heads/main")
    end

    test "rejects components ending with .lock" do
      refute RefName.valid?("refs/heads/main.lock")
      refute RefName.valid?("refs/heads/foo.lock/bar")
    end

    test "rejects components ending with ." do
      refute RefName.valid?("refs/heads/main.")
      refute RefName.valid?("refs./heads/main")
    end

    test "rejects forbidden characters" do
      refute RefName.valid?("refs/heads/foo~bar")
      refute RefName.valid?("refs/heads/foo^bar")
      refute RefName.valid?("refs/heads/foo:bar")
      refute RefName.valid?("refs/heads/foo?bar")
      refute RefName.valid?("refs/heads/foo*bar")
      refute RefName.valid?("refs/heads/foo[bar")
      refute RefName.valid?("refs/heads/foo\\bar")
    end

    test "rejects @{" do
      refute RefName.valid?("refs/heads/foo@{bar}")
    end

    test "rejects control characters" do
      refute RefName.valid?("refs/heads/foo\x00bar")
      refute RefName.valid?("refs/heads/foo\x01bar")
      refute RefName.valid?("refs/heads/foo\x1Fbar")
      refute RefName.valid?("refs/heads/foo\x7Fbar")
      refute RefName.valid?("refs/heads/foo\nbar")
    end

    test "rejects bare @ alone" do
      refute RefName.valid?("@")
    end

    test "single-component names other than well-known HEAD-like are rejected" do
      # Real git: a refname must include at least one '/' unless it's
      # a well-known singleton. We accept HEAD, FETCH_HEAD, ORIG_HEAD,
      # MERGE_HEAD, CHERRY_PICK_HEAD; everything else single-component
      # is suspicious.
      assert RefName.valid?("HEAD")
      assert RefName.valid?("FETCH_HEAD")
      assert RefName.valid?("ORIG_HEAD")
      refute RefName.valid?("main")
      refute RefName.valid?("random")
    end

    test "rejects non-string input" do
      refute RefName.valid?(nil)
      refute RefName.valid?(123)
      refute RefName.valid?(:main)
    end

    property "never crashes on arbitrary binary input" do
      check all(bytes <- binary(), max_runs: 500) do
        assert is_boolean(RefName.valid?(bytes))
      end
    end

    property "never validates a name that resolves to a path outside a given root" do
      check all(name <- binary(min_length: 1, max_length: 128), max_runs: 500) do
        if RefName.valid?(name) do
          # A valid ref name, joined to /tmp/root, must stay under /tmp/root.
          root = "/tmp/exgit_reftest_root"
          joined = Path.expand(Path.join(root, name))

          assert String.starts_with?(joined, root),
                 "valid ref #{inspect(name)} escaped root: #{joined}"
        end
      end
    end
  end
end
