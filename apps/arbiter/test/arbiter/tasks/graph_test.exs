defmodule Arbiter.Tasks.GraphTest do
  use Arbiter.DataCase, async: false

  alias Arbiter.Tasks.Graph
  alias Arbiter.Tasks.GraphMember
  alias Arbiter.Tasks.Issue
  alias Arbiter.Tasks.Workspace

  setup do
    {:ok, ws} = Ash.create(Workspace, %{name: "graph-ws", prefix: "grph"})
    {:ok, a} = Ash.create(Issue, %{title: "issue A", workspace_id: ws.id})
    {:ok, b} = Ash.create(Issue, %{title: "issue B", workspace_id: ws.id})
    {:ok, ws: ws, a: a, b: b}
  end

  describe "Graph.create/2" do
    test "creates a graph with minimal attrs (defaults to draft)", %{ws: ws} do
      {:ok, graph} = Ash.create(Graph, %{name: "release-1.0", workspace_id: ws.id})

      assert graph.name == "release-1.0"
      assert graph.run_state == :draft
      assert graph.workspace_id == ws.id
      # description not passed → NULL in DB (Ash-level default applies on changeset read)
      assert graph.description in [nil, ""]
      assert %DateTime{} = graph.created_at
    end

    test "creates with description", %{ws: ws} do
      {:ok, graph} =
        Ash.create(Graph, %{
          name: "hotfix-flow",
          description: "Emergency patch sequence",
          workspace_id: ws.id
        })

      assert graph.description == "Emergency patch sequence"
    end

    test "accepts each valid run_state on create", %{ws: ws} do
      for state <- Graph.run_states() do
        assert {:ok, g} =
                 Ash.create(Graph, %{
                   name: "graph-#{state}",
                   run_state: state,
                   workspace_id: ws.id
                 }),
               "expected create to succeed for run_state #{state}"

        assert g.run_state == state
      end
    end

    test "rejects an invalid run_state", %{ws: ws} do
      assert {:error, %Ash.Error.Invalid{}} =
               Ash.create(Graph, %{
                 name: "bad-state",
                 run_state: :flying,
                 workspace_id: ws.id
               })
    end

    test "rejects missing name", %{ws: ws} do
      assert {:error, %Ash.Error.Invalid{}} =
               Ash.create(Graph, %{workspace_id: ws.id})
    end

    test "rejects missing workspace_id" do
      assert {:error, %Ash.Error.Invalid{}} =
               Ash.create(Graph, %{name: "no-ws"})
    end

    test "rejects nonexistent workspace_id" do
      assert {:error, _} =
               Ash.create(Graph, %{
                 name: "ghost-ws",
                 workspace_id: Ash.UUIDv7.generate()
               })
    end
  end

  describe "Graph.update/2" do
    test "updates run_state", %{ws: ws} do
      {:ok, graph} = Ash.create(Graph, %{name: "exec-unit", workspace_id: ws.id})
      assert graph.run_state == :draft

      {:ok, updated} = Ash.update(graph, %{run_state: :running})
      assert updated.run_state == :running

      {:ok, paused} = Ash.update(updated, %{run_state: :paused})
      assert paused.run_state == :paused

      {:ok, drained} = Ash.update(paused, %{run_state: :drained})
      assert drained.run_state == :drained
    end

    test "updates name and description", %{ws: ws} do
      {:ok, graph} = Ash.create(Graph, %{name: "old-name", workspace_id: ws.id})

      {:ok, updated} = Ash.update(graph, %{name: "new-name", description: "better desc"})
      assert updated.name == "new-name"
      assert updated.description == "better desc"
    end
  end

  describe "Graph.read/0" do
    test "reads all graphs", %{ws: ws} do
      {:ok, g1} = Ash.create(Graph, %{name: "g1", workspace_id: ws.id})
      {:ok, g2} = Ash.create(Graph, %{name: "g2", workspace_id: ws.id})

      graphs = Ash.read!(Graph)
      ids = Enum.map(graphs, & &1.id)
      assert g1.id in ids
      assert g2.id in ids
    end

    test "reads a single graph by id", %{ws: ws} do
      {:ok, graph} = Ash.create(Graph, %{name: "specific", workspace_id: ws.id})

      fetched = Ash.get!(Graph, graph.id)
      assert fetched.id == graph.id
      assert fetched.name == "specific"
    end

    test "loads members relationship", %{ws: ws, a: a, b: b} do
      {:ok, graph} = Ash.create(Graph, %{name: "with-members", workspace_id: ws.id})
      {:ok, _} = Ash.create(GraphMember, %{graph_id: graph.id, issue_id: a.id})
      {:ok, _} = Ash.create(GraphMember, %{graph_id: graph.id, issue_id: b.id})

      loaded = Ash.load!(graph, :members)
      member_issue_ids = Enum.map(loaded.members, & &1.issue_id) |> MapSet.new()
      assert MapSet.equal?(member_issue_ids, MapSet.new([a.id, b.id]))
    end
  end

  describe "Graph.destroy/1" do
    test "deletes a graph and cascades to members", %{ws: ws, a: a} do
      {:ok, graph} = Ash.create(Graph, %{name: "to-delete", workspace_id: ws.id})
      {:ok, member} = Ash.create(GraphMember, %{graph_id: graph.id, issue_id: a.id})

      :ok = Ash.destroy(graph)

      assert {:error, _} = Ash.get(Graph, graph.id)
      # cascade delete: member row is gone
      assert {:error, _} = Ash.get(GraphMember, member.id)
    end
  end

  describe "Graph.run_states/0" do
    test "returns the 4 valid run-state atoms" do
      assert Graph.run_states() == ~w(draft running paused drained)a
    end
  end

  describe "GraphMember.create/2" do
    test "adds a directive to a graph", %{ws: ws, a: a} do
      {:ok, graph} = Ash.create(Graph, %{name: "exec", workspace_id: ws.id})

      {:ok, member} = Ash.create(GraphMember, %{graph_id: graph.id, issue_id: a.id})

      assert member.graph_id == graph.id
      assert member.issue_id == a.id
      assert %DateTime{} = member.created_at
    end

    test "a directive may belong to multiple graphs", %{ws: ws, a: a} do
      {:ok, g1} = Ash.create(Graph, %{name: "g1", workspace_id: ws.id})
      {:ok, g2} = Ash.create(Graph, %{name: "g2", workspace_id: ws.id})

      assert {:ok, _} = Ash.create(GraphMember, %{graph_id: g1.id, issue_id: a.id})
      assert {:ok, _} = Ash.create(GraphMember, %{graph_id: g2.id, issue_id: a.id})
    end

    test "rejects duplicate membership (same directive in same graph)", %{ws: ws, a: a} do
      {:ok, graph} = Ash.create(Graph, %{name: "dup-test", workspace_id: ws.id})

      {:ok, _} = Ash.create(GraphMember, %{graph_id: graph.id, issue_id: a.id})

      assert {:error, %Ash.Error.Invalid{}} =
               Ash.create(GraphMember, %{graph_id: graph.id, issue_id: a.id})
    end

    test "rejects nonexistent issue_id", %{ws: ws} do
      {:ok, graph} = Ash.create(Graph, %{name: "bad-issue", workspace_id: ws.id})

      assert {:error, _} =
               Ash.create(GraphMember, %{graph_id: graph.id, issue_id: "grph-000000"})
    end

    test "rejects nonexistent graph_id", %{a: a} do
      assert {:error, _} =
               Ash.create(GraphMember, %{
                 graph_id: Ash.UUIDv7.generate(),
                 issue_id: a.id
               })
    end
  end

  describe "GraphMember.destroy/1" do
    test "removes a directive from a graph", %{ws: ws, a: a} do
      {:ok, graph} = Ash.create(Graph, %{name: "remove-test", workspace_id: ws.id})
      {:ok, member} = Ash.create(GraphMember, %{graph_id: graph.id, issue_id: a.id})

      :ok = Ash.destroy(member)

      loaded = Ash.load!(graph, :members)
      assert loaded.members == []
    end

    test "removing one member leaves others intact", %{ws: ws, a: a, b: b} do
      {:ok, graph} = Ash.create(Graph, %{name: "partial-remove", workspace_id: ws.id})
      {:ok, ma} = Ash.create(GraphMember, %{graph_id: graph.id, issue_id: a.id})
      {:ok, _mb} = Ash.create(GraphMember, %{graph_id: graph.id, issue_id: b.id})

      :ok = Ash.destroy(ma)

      loaded = Ash.load!(graph, :members)
      assert length(loaded.members) == 1
      assert hd(loaded.members).issue_id == b.id
    end
  end
end
