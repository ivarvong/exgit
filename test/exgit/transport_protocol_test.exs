defmodule Exgit.TransportProtocolTest do
  use ExUnit.Case, async: true

  @moduledoc """
  Exgit.Transport must be invocable via a protocol so third-party
  transports (e.g. SSH, in-memory mock, filesystem) can implement it
  without exgit's own modules having to be edited.

  Prior to this change, dispatch was done via `transport.__struct__.fn(...)`
  — which forced us to hardcode the set of transport modules in
  `lib/exgit.ex`.
  """

  defmodule FakeTransport do
    # Minimal transport that records calls into an agent.
    defstruct [:agent]

    def new do
      {:ok, agent} = Agent.start_link(fn -> [] end)
      %__MODULE__{agent: agent}
    end

    def calls(%__MODULE__{agent: agent}), do: Agent.get(agent, &Enum.reverse/1)

    defimpl Exgit.Transport do
      def capabilities(%Exgit.TransportProtocolTest.FakeTransport{agent: a}) do
        Agent.update(a, &[{:capabilities} | &1])
        {:ok, %{"fetch" => "", :version => 2}}
      end

      def ls_refs(%Exgit.TransportProtocolTest.FakeTransport{agent: a}, opts) do
        Agent.update(a, &[{:ls_refs, opts} | &1])
        {:ok, [], %{}}
      end

      def fetch(%Exgit.TransportProtocolTest.FakeTransport{agent: a}, wants, opts) do
        Agent.update(a, &[{:fetch, wants, opts} | &1])
        {:ok, <<>>, %{objects: 0}}
      end

      def push(%Exgit.TransportProtocolTest.FakeTransport{agent: a}, updates, pack, opts) do
        Agent.update(a, &[{:push, updates, pack, opts} | &1])
        {:ok, %{ref_results: []}}
      end
    end
  end

  test "Exgit.Transport dispatches to a user-defined transport via the protocol" do
    t = FakeTransport.new()

    assert {:ok, _caps} = Exgit.Transport.capabilities(t)
    assert {:ok, [], %{}} = Exgit.Transport.ls_refs(t, prefix: ["refs/heads/"])
    assert {:ok, _, _} = Exgit.Transport.fetch(t, [:crypto.strong_rand_bytes(20)], [])
    assert {:ok, _} = Exgit.Transport.push(t, [{"refs/heads/main", nil, nil}], <<>>, [])

    calls = FakeTransport.calls(t)
    assert Enum.any?(calls, &match?({:capabilities}, &1))
    assert Enum.any?(calls, &match?({:ls_refs, _}, &1))
    assert Enum.any?(calls, &match?({:fetch, _, _}, &1))
    assert Enum.any?(calls, &match?({:push, _, _, _}, &1))
  end
end
