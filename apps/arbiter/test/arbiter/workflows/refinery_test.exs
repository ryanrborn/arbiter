defmodule Arbiter.Workflows.RefineryTest do
  # async: false — DataCase sandbox can't be shared with the GenServer process
  # in async mode, and we mutate global :persistent_term GitHub rate-limit
  # cache via the stubs.
  use Arbiter.DataCase, async: false

  alias Arbiter.Beads.Issue
  alias Arbiter.Beads.Workspace
  alias Arbiter.Workflows.Refinery

  @repo "octo/widget"
  @token "test-token-abc123"

  # ---- setup helpers ------------------------------------------------------

  setup tags do
    workspace_config = Map.get(tags, :workspace_config, %{})
    ws_name = "ws-#{System.unique_integer([:positive])}"

    {:ok, workspace} =
      Ash.create(Workspace, %{
        name: ws_name,
        prefix: "rt#{System.unique_integer([:positive])}",
        config: workspace_config
      })

    {:ok, bead} =
      Ash.create(Issue, %{
        title: "merge me",
        description: "body",
        workspace_id: workspace.id
      })

    %{workspace: workspace, bead: bead}
  end

  defp start_refinery(workspace, opts \\ []) do
    name = :"refinery_#{System.unique_integer([:positive])}"

    full_opts =
      [
        workspace_id: workspace.id,
        repo: @repo,
        base: "main",
        github_token: @token,
        auto_tick: false,
        name: name
      ]
      |> Keyword.merge(opts)

    {:ok, pid} = Refinery.start_link(full_opts)
    # Allow the refinery process to use any Req.Test stub registered by the
    # test process for Arbiter.GitHub.HTTP.
    Req.Test.allow(Arbiter.GitHub.HTTP, self(), pid)
    # Allow it to use the Ecto sandbox connection too.
    Ecto.Adapters.SQL.Sandbox.allow(Arbiter.Repo, self(), pid)
    {pid, name}
  end

  defp stub(fun), do: Req.Test.stub(Arbiter.GitHub.HTTP, fun)

  defp pr_payload(overrides \\ %{}) do
    Map.merge(
      %{
        "number" => 42,
        "state" => "open",
        "mergeable" => true,
        "mergeStateStatus" => "clean",
        "reviewDecision" => "APPROVED"
      },
      overrides
    )
  end

  # Workspace configs used as test tags.
  @ws_pr %{"merge" => %{"strategy" => "pr"}}
  @ws_squash %{"merge" => %{"strategy" => "squash"}}
  @ws_merge %{"merge" => %{"strategy" => "merge"}}
  @ws_rebase %{"merge" => %{"strategy" => "rebase"}}
  @ws_direct %{"merge" => %{"strategy" => "direct"}}

  # ---- tests --------------------------------------------------------------

  describe "start_link/1" do
    test "starts with a workspace_id", %{workspace: ws} do
      {pid, _name} = start_refinery(ws)
      assert Process.alive?(pid)
    end

    test "raises without workspace_id" do
      assert_raise ArgumentError, ~r/workspace_id/, fn ->
        # start_link spawns the GenServer and init/1 raises; trap it.
        Process.flag(:trap_exit, true)
        {:error, {%ArgumentError{message: msg}, _}} = Refinery.start_link([])
        raise ArgumentError, msg
      end
    end
  end

  describe "enqueue/2 with merge_strategy=pr" do
    @tag workspace_config: @ws_pr
    test "opens a PR via GitHub.pr_open and queues with status :awaiting_approval", %{
      workspace: ws,
      bead: bead
    } do
      test_pid = self()

      stub(fn conn ->
        if conn.method == "POST" and String.ends_with?(conn.request_path, "/pulls") do
          send(test_pid, :pr_open_called)

          conn
          |> Plug.Conn.put_status(201)
          |> Req.Test.json(%{"number" => 101, "state" => "open"})
        else
          conn |> Plug.Conn.put_status(500) |> Req.Test.json(%{"message" => "unexpected"})
        end
      end)

      {_pid, name} = start_refinery(ws)
      assert :ok = Refinery.enqueue(name, bead.id)
      assert_received :pr_open_called

      %{items: [item]} = Refinery.state(name)
      assert item.bead_id == bead.id
      assert item.pr_number == 101
      assert item.status == :awaiting_approval
      assert item.strategy == "pr"
    end

    @tag workspace_config: @ws_pr
    test "records pr_number on the bead's pr_ref", %{workspace: ws, bead: bead} do
      stub(fn conn ->
        conn
        |> Plug.Conn.put_status(201)
        |> Req.Test.json(%{"number" => 77})
      end)

      {_pid, name} = start_refinery(ws)
      :ok = Refinery.enqueue(name, bead.id)

      reloaded = Ash.get!(Issue, bead.id)
      assert reloaded.pr_ref == "77"
    end

    @tag workspace_config: @ws_pr
    test "writes pr_ref even when tracker_ref is already set (issue ref preserved)", %{
      workspace: ws,
      bead: bead
    } do
      {:ok, bead} = Ash.update(bead, %{tracker_ref: "PRE-123"}, action: :update)

      stub(fn conn ->
        conn |> Plug.Conn.put_status(201) |> Req.Test.json(%{"number" => 77})
      end)

      {_pid, name} = start_refinery(ws)
      :ok = Refinery.enqueue(name, bead.id)

      reloaded = Ash.get!(Issue, bead.id)
      assert reloaded.tracker_ref == "PRE-123"
      assert reloaded.pr_ref == "77"
    end

    @tag workspace_config: @ws_pr
    test "GitHub.pr_open failure → status :failed; bead is not modified", %{
      workspace: ws,
      bead: bead
    } do
      stub(fn conn ->
        conn |> Plug.Conn.put_status(422) |> Req.Test.json(%{"message" => "Validation Failed"})
      end)

      {_pid, name} = start_refinery(ws)
      {:error, _} = Refinery.enqueue(name, bead.id)

      %{items: [item]} = Refinery.state(name)
      assert item.status == :failed
      reloaded = Ash.get!(Issue, bead.id)
      assert reloaded.status == :open
    end
  end

  describe "enqueue/2 no-duplicate-PR guard (bd-auma3z)" do
    # Any non-"direct" strategy takes the PR path; "github" is the valid
    # adapter-named strategy the Workspace config accepts.
    @tag workspace_config: %{"merge" => %{"strategy" => "github"}}
    test "adopts an existing open PR instead of opening a duplicate", %{
      workspace: ws,
      bead: bead
    } do
      # Simulate a resumed bead whose prior acolyte already opened PR #55.
      {:ok, bead} = Ash.update(bead, %{pr_ref: "55"}, action: :update)

      test_pid = self()

      stub(fn conn ->
        if conn.method == "POST" and String.ends_with?(conn.request_path, "/pulls") do
          send(test_pid, :pr_open_called)
        end

        conn |> Plug.Conn.put_status(201) |> Req.Test.json(%{"number" => 999})
      end)

      {_pid, name} = start_refinery(ws)
      assert :ok = Refinery.enqueue(name, bead.id)

      # No pr_open call — the existing PR was adopted, not duplicated.
      refute_received :pr_open_called

      %{items: [item]} = Refinery.state(name)
      assert item.pr_number == 55
      assert item.status == :awaiting_approval

      # The bead's pr_ref is unchanged (still the original PR, no overwrite).
      assert Ash.get!(Issue, bead.id).pr_ref == "55"
    end
  end

  describe "enqueue/2 PR remote-link on the upstream tracker" do
    @jira_env "GTE_REFINERY_JIRA_TOKEN"
    @ws_pr_jira %{
      "merge" => %{"strategy" => "github"},
      "tracker" => %{
        "type" => "jira",
        "config" => %{
          "host" => "leotechnologies.atlassian.net",
          "project_key" => "VR",
          "credentials_ref" => "env:GTE_REFINERY_JIRA_TOKEN",
          "email" => "tester@example.com"
        }
      }
    }

    setup do
      System.put_env(@jira_env, "test-jira-token")
      on_exit(fn -> System.delete_env(@jira_env) end)
      :ok
    end

    @tag workspace_config: @ws_pr_jira
    test "posts a Jira remote link pointing at the opened PR", %{workspace: ws} do
      {:ok, bead} =
        Ash.create(Issue, %{
          title: "jira-backed",
          tracker_type: :jira,
          tracker_ref: "VR-17585",
          skip_upstream_create: true,
          workspace_id: ws.id
        })

      test_pid = self()

      stub(fn conn ->
        conn
        |> Plug.Conn.put_status(201)
        |> Req.Test.json(%{
          "number" => 88,
          "html_url" => "https://github.com/octo/widget/pull/88"
        })
      end)

      Req.Test.stub(Arbiter.Trackers.Jira.HTTP, fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        send(test_pid, {:jira_remotelink, conn.request_path, Jason.decode!(body)})
        conn |> Plug.Conn.put_status(201) |> Req.Test.json(%{"id" => 1})
      end)

      {pid, name} = start_refinery(ws)
      Req.Test.allow(Arbiter.Trackers.Jira.HTTP, self(), pid)

      :ok = Refinery.enqueue(name, bead.id)

      assert_receive {:jira_remotelink, "/rest/api/3/issue/VR-17585/remotelink", payload}
      assert payload["object"]["url"] == "https://github.com/octo/widget/pull/88"
    end
  end

  describe "enqueue/2 with merge_strategy=direct" do
    @tag workspace_config: @ws_direct
    test "never calls GitHub APIs and closes the bead immediately", %{
      workspace: ws,
      bead: bead
    } do
      test_pid = self()

      stub(fn conn ->
        send(test_pid, {:unexpected_github_call, conn.method, conn.request_path})
        conn |> Plug.Conn.put_status(500) |> Req.Test.json(%{})
      end)

      {_pid, name} = start_refinery(ws)
      :ok = Refinery.enqueue(name, bead.id)

      refute_received {:unexpected_github_call, _, _}

      # Item was removed (status reached :done and a poll cycle would prune
      # it; we removed eagerly via close path → item still in queue but with
      # :done status until next poll). Verify the bead is closed.
      reloaded = Ash.get!(Issue, bead.id)
      assert reloaded.status == :closed
    end
  end

  describe ":tick polling" do
    @tag workspace_config: @ws_squash
    test "APPROVED + clean → merges with :squash and closes the bead", %{
      workspace: ws,
      bead: bead
    } do
      test_pid = self()

      stub(fn conn ->
        cond do
          conn.method == "POST" and String.ends_with?(conn.request_path, "/pulls") ->
            conn |> Plug.Conn.put_status(201) |> Req.Test.json(%{"number" => 50})

          conn.method == "GET" and String.contains?(conn.request_path, "/pulls/50") ->
            conn |> Plug.Conn.put_status(200) |> Req.Test.json(pr_payload())

          conn.method == "PUT" and String.ends_with?(conn.request_path, "/merge") ->
            {:ok, body, conn} = Plug.Conn.read_body(conn)
            decoded = Jason.decode!(body)
            send(test_pid, {:merge_called, decoded["merge_method"]})

            conn
            |> Plug.Conn.put_status(200)
            |> Req.Test.json(%{"merged" => true, "sha" => "deadbeef"})

          true ->
            conn |> Plug.Conn.put_status(500) |> Req.Test.json(%{})
        end
      end)

      {_pid, name} = start_refinery(ws)
      :ok = Refinery.enqueue(name, bead.id)

      %{items: [item]} = Refinery.state(name)
      assert item.status == :awaiting_approval

      :ok = Refinery.tick(name)

      assert_received {:merge_called, "squash"}

      # After tick, the item is removed (poll_all prunes :done items).
      %{items: items} = Refinery.state(name)
      assert items == []

      reloaded = Ash.get!(Issue, bead.id)
      assert reloaded.status == :closed
    end

    @tag workspace_config: @ws_pr
    test "CHANGES_REQUESTED → stays in :awaiting_approval and does not merge", %{
      workspace: ws,
      bead: bead
    } do
      test_pid = self()

      stub(fn conn ->
        cond do
          conn.method == "POST" and String.ends_with?(conn.request_path, "/pulls") ->
            conn |> Plug.Conn.put_status(201) |> Req.Test.json(%{"number" => 60})

          conn.method == "GET" ->
            conn
            |> Plug.Conn.put_status(200)
            |> Req.Test.json(
              pr_payload(%{
                "reviewDecision" => "CHANGES_REQUESTED",
                "mergeStateStatus" => "blocked"
              })
            )

          conn.method == "PUT" ->
            send(test_pid, :unexpected_merge)
            conn |> Plug.Conn.put_status(200) |> Req.Test.json(%{"merged" => true})

          true ->
            conn |> Plug.Conn.put_status(500) |> Req.Test.json(%{})
        end
      end)

      {_pid, name} = start_refinery(ws)
      :ok = Refinery.enqueue(name, bead.id)
      :ok = Refinery.tick(name)

      refute_received :unexpected_merge

      %{items: [item]} = Refinery.state(name)
      assert item.status == :awaiting_approval

      reloaded = Ash.get!(Issue, bead.id)
      assert reloaded.status == :open
    end

    @tag workspace_config: @ws_pr
    test "mergeable=false → stays in current state and does not call merge", %{
      workspace: ws,
      bead: bead
    } do
      test_pid = self()

      stub(fn conn ->
        cond do
          conn.method == "POST" and String.ends_with?(conn.request_path, "/pulls") ->
            conn |> Plug.Conn.put_status(201) |> Req.Test.json(%{"number" => 70})

          conn.method == "GET" ->
            conn
            |> Plug.Conn.put_status(200)
            |> Req.Test.json(
              pr_payload(%{
                "reviewDecision" => "APPROVED",
                "mergeStateStatus" => "dirty",
                "mergeable" => false
              })
            )

          conn.method == "PUT" ->
            send(test_pid, :unexpected_merge)
            conn |> Plug.Conn.put_status(200) |> Req.Test.json(%{})

          true ->
            conn |> Plug.Conn.put_status(500) |> Req.Test.json(%{})
        end
      end)

      {_pid, name} = start_refinery(ws)
      :ok = Refinery.enqueue(name, bead.id)
      :ok = Refinery.tick(name)

      refute_received :unexpected_merge

      %{items: [item]} = Refinery.state(name)
      assert item.status == :awaiting_approval
    end

    @tag workspace_config: @ws_pr
    test "pr_merge failure → status :failed; bead is NOT closed", %{workspace: ws, bead: bead} do
      stub(fn conn ->
        cond do
          conn.method == "POST" and String.ends_with?(conn.request_path, "/pulls") ->
            conn |> Plug.Conn.put_status(201) |> Req.Test.json(%{"number" => 80})

          conn.method == "GET" ->
            conn |> Plug.Conn.put_status(200) |> Req.Test.json(pr_payload())

          conn.method == "PUT" ->
            conn
            |> Plug.Conn.put_status(409)
            |> Req.Test.json(%{"message" => "Pull Request is not mergeable"})

          true ->
            conn |> Plug.Conn.put_status(500) |> Req.Test.json(%{})
        end
      end)

      {_pid, name} = start_refinery(ws)
      :ok = Refinery.enqueue(name, bead.id)
      :ok = Refinery.tick(name)

      %{items: [item]} = Refinery.state(name)
      assert item.status == :failed

      reloaded = Ash.get!(Issue, bead.id)
      assert reloaded.status == :open
    end
  end

  describe "merge strategy mapping" do
    @tag workspace_config: @ws_squash
    test "squash → pr_merge with :squash", %{workspace: ws, bead: bead} do
      assert_merge_method_called("squash", ws, bead)
    end

    @tag workspace_config: @ws_merge
    test "merge → pr_merge with :merge", %{workspace: ws, bead: bead} do
      assert_merge_method_called("merge", ws, bead)
    end

    @tag workspace_config: @ws_rebase
    test "rebase → pr_merge with :rebase", %{workspace: ws, bead: bead} do
      assert_merge_method_called("rebase", ws, bead)
    end

    defp assert_merge_method_called(expected_method, ws, bead) do
      test_pid = self()

      stub(fn conn ->
        cond do
          conn.method == "POST" and String.ends_with?(conn.request_path, "/pulls") ->
            conn |> Plug.Conn.put_status(201) |> Req.Test.json(%{"number" => 90})

          conn.method == "GET" ->
            conn |> Plug.Conn.put_status(200) |> Req.Test.json(pr_payload())

          conn.method == "PUT" ->
            {:ok, body, conn} = Plug.Conn.read_body(conn)
            decoded = Jason.decode!(body)
            send(test_pid, {:merge_method, decoded["merge_method"]})
            conn |> Plug.Conn.put_status(200) |> Req.Test.json(%{"merged" => true})

          true ->
            conn |> Plug.Conn.put_status(500) |> Req.Test.json(%{})
        end
      end)

      {_pid, name} = start_refinery(ws)
      :ok = Refinery.enqueue(name, bead.id)
      :ok = Refinery.tick(name)

      assert_received {:merge_method, ^expected_method}
    end
  end

  describe "PubSub" do
    @tag workspace_config: @ws_pr
    test "{:polecat_done, bead_id} message triggers enqueue", %{workspace: ws, bead: bead} do
      test_pid = self()

      stub(fn conn ->
        if conn.method == "POST" do
          send(test_pid, :pr_open_called)
          conn |> Plug.Conn.put_status(201) |> Req.Test.json(%{"number" => 111})
        else
          conn |> Plug.Conn.put_status(500) |> Req.Test.json(%{})
        end
      end)

      {pid, _name} = start_refinery(ws)
      send(pid, {:polecat_done, bead.id})

      assert_receive :pr_open_called, 500

      # Give the GenServer a moment to update its state.
      :sys.get_state(pid)
      %{items: [item]} = Refinery.state(pid)
      assert item.bead_id == bead.id
      assert item.pr_number == 111
    end

    @tag workspace_config: @ws_pr
    test "broadcasts {:bead_closed_by_refinery, bead_id} when merge lands", %{
      workspace: ws,
      bead: bead
    } do
      :ok = Phoenix.PubSub.subscribe(Arbiter.PubSub, "refinery:" <> ws.id)

      stub(fn conn ->
        cond do
          conn.method == "POST" ->
            conn |> Plug.Conn.put_status(201) |> Req.Test.json(%{"number" => 200})

          conn.method == "GET" ->
            conn |> Plug.Conn.put_status(200) |> Req.Test.json(pr_payload())

          conn.method == "PUT" ->
            conn |> Plug.Conn.put_status(200) |> Req.Test.json(%{"merged" => true})

          true ->
            conn |> Plug.Conn.put_status(500) |> Req.Test.json(%{})
        end
      end)

      {_pid, name} = start_refinery(ws)
      :ok = Refinery.enqueue(name, bead.id)
      :ok = Refinery.tick(name)

      bead_id = bead.id
      assert_receive {:bead_closed_by_refinery, ^bead_id}, 500
    end
  end
end
