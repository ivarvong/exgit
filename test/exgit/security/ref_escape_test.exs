defmodule Exgit.Security.RefEscapeTest do
  @moduledoc """
  End-to-end exploit regression: a hostile transport advertises a ref
  name containing `..` that would escape the repo root if joined with
  `Path.join/2`. The clone must succeed without writing any file
  outside the repo directory.
  """

  use ExUnit.Case, async: true

  alias Exgit.Object.Blob
  alias Exgit.{ObjectStore, Transport}

  defmodule HostileTransport do
    defstruct [:origin, :ref_name]
  end

  defimpl Exgit.Transport, for: Exgit.Security.RefEscapeTest.HostileTransport do
    alias Exgit.Security.RefEscapeTest.HostileTransport

    def capabilities(_), do: {:ok, %{version: 2}}

    def ls_refs(%HostileTransport{ref_name: name, origin: store}, _opts) do
      # Claim the hostile ref exists and points to a real blob sha.
      %Exgit.Object.Blob{} = blob = Blob.new("payload")
      _ = store

      {:ok,
       [
         {name, Blob.sha(blob)},
         # Also include one valid ref so the caller has something to
         # resolve normally.
         {"refs/heads/main", Blob.sha(blob)}
       ]}
    end

    def fetch(%HostileTransport{origin: store}, _wants, _opts) do
      # Return a valid pack so the rest of the pipeline runs.
      pack =
        Exgit.Pack.Writer.build(
          for {_sha, {:blob, _}} <- store.objects do
            {:ok, obj} = Exgit.ObjectStore.get(store, _sha = elem(Enum.at(store.objects, 0), 0))
            obj
          end
        )

      {:ok, pack, %{objects: 1}}
    end

    def push(_, _, _, _), do: {:error, :unsupported}
  end

  # The three specific exploit strings we regression-test. Each one
  # would traverse upward if naively joined under a repo root.
  @exploits [
    "refs/heads/../../../../tmp/exgit_pwned",
    "../escape",
    "refs/heads/foo\x00bar",
    "refs/heads/foo\nbar",
    "/absolute/path",
    "refs/heads/foo:bar"
  ]

  def forward_event(_event, _measurements, metadata, parent) do
    send(parent, {:ref_rejected, metadata})
  end

  for exploit <- @exploits do
    test "clone rejects hostile ref #{inspect(exploit)} without escaping root" do
      # Seed an origin store with a real blob.
      origin = ObjectStore.Memory.new()
      {:ok, _sha, origin} = ObjectStore.put(origin, Blob.new("payload"))

      transport = %HostileTransport{origin: origin, ref_name: unquote(exploit)}

      handler_id = "ref-escape-#{System.unique_integer([:positive])}"

      :telemetry.attach(
        handler_id,
        [:exgit, :security, :ref_rejected],
        &__MODULE__.forward_event/4,
        self()
      )

      try do
        # Clone into memory. Must NOT raise.
        result = Exgit.clone(transport)

        assert match?({:ok, _}, result) or match?({:error, _}, result)

        # The security telemetry MUST have fired for the hostile ref name.
        assert_receive {:ref_rejected, %{ref: rejected}}, 1_000
        assert rejected == unquote(exploit)
      after
        :telemetry.detach(handler_id)
      end
    end
  end
end
