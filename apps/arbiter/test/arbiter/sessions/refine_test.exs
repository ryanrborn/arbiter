defmodule Arbiter.Sessions.RefineTest do
  @moduledoc """
  bd-1lszsc: the Refine entry point's server half — eligibility, one live
  session per issue, the issue-bound refine token, the read-only checkout, the
  rendered refine instructions and premium-not-flagship model routing.

  Acceptance 1 (eligibility, the half the UI renders from), 2 (launch /
  reopen / concurrent double-click), 3 (token tier and binding), 4 (the
  checkout), 5 (model routing) and 6 (the instructions variant).
  """
  use Arbiter.DataCase, async: false

  alias Arbiter.MCP.Catalog
  alias Arbiter.MCP.Scope
  alias Arbiter.Sessions
  alias Arbiter.Sessions.Layout
  alias Arbiter.Sessions.Refine
  alias Arbiter.Tasks.Dependencies
  alias Arbiter.Tasks.Issue
  alias Arbiter.Tasks.Workspace
  alias Arbiter.Test.SessionEnv
  alias Arbiter.Test.SessionRunnerStub

  setup do
    env = SessionEnv.sandbox("refine")
    SessionRunnerStub.reset()
    repo_dir = seed_repo!()

    {:ok, ws} =
      Ash.create(Workspace, %{
        name: "refine-ws",
        prefix: "rfn",
        config: %{
          "repo_paths" => %{"widget" => %{"path" => repo_dir, "target_branch" => "main"}}
        }
      })

    {:ok, issue} =
      Ash.create(Issue, %{
        title: "Make widgets faster",
        description: "the widgets are slow",
        workspace_id: ws.id,
        repo: "widget"
      })

    {:ok, ws: ws, issue: issue, repo_dir: repo_dir, sessions_root: env[:sessions_root]}
  end

  defp seed_repo! do
    dir = Path.join(System.tmp_dir!(), "refine-repo-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf(dir) end)

    git = fn args -> {_, 0} = System.cmd("git", ["-C", dir | args], stderr_to_stdout: true) end
    git.(["init", "--initial-branch=main", "--quiet"])
    git.(["config", "user.email", "test@example.com"])
    git.(["config", "user.name", "Test"])
    File.write!(Path.join(dir, "widget.ex"), "defmodule Widget do\nend\n")
    git.(["add", "."])
    git.(["commit", "--quiet", "-m", "seed"])
    dir
  end

  defp open!(issue, opts \\ []) do
    {:ok, result} = Refine.open(issue, Keyword.merge([runner: SessionRunnerStub], opts))
    result
  end

  defp launch_script!(session), do: File.read!(Layout.launch_script_path(session.id))

  describe "eligible?/1" do
    test "a Backlog issue can be refined", %{issue: issue} do
      assert Refine.eligible?(issue)
    end

    test "a refined issue cannot", %{issue: issue} do
      {:ok, issue} = Ash.update(issue, %{acceptance: "- ac"}, action: :update)
      {:ok, refined} = Ash.update(issue, %{}, action: :promote_to_ready)
      refute Refine.eligible?(refined)
    end

    test "a running issue cannot", %{issue: issue} do
      {:ok, running} = Ash.update(issue, %{status: :in_progress}, action: :update)
      refute Refine.eligible?(running)
    end

    test "a closed issue cannot", %{issue: issue} do
      {:ok, closed} = Ash.update(issue, %{reason: "no longer wanted"}, action: :close)
      refute Refine.eligible?(closed)
    end
  end

  describe "open/2 — binding and uniqueness" do
    test "launches a session bound to the issue and names it after it", %{
      issue: issue,
      ws: ws
    } do
      %{session: session, reopened?: false} = open!(issue)

      assert session.issue_id == issue.id
      assert session.workspace_id == ws.id
      assert session.name == "Refine #{issue.id}: Make widgets faster"
      assert session.can_dispatch == false
    end

    test "a second open reopens the same session, never a second one", %{issue: issue} do
      %{session: first, reopened?: false} = open!(issue)
      %{session: second, reopened?: true} = open!(issue)

      assert second.id == first.id
      assert [_one] = Enum.filter(Sessions.list(), &(&1.issue_id == issue.id))
    end

    test "a concurrent double-click still lands one session", %{issue: issue} do
      parent = self()

      results =
        1..2
        |> Enum.map(fn _ ->
          Task.async(fn ->
            Ecto.Adapters.SQL.Sandbox.allow(Arbiter.Repo, parent, self())
            Refine.open(issue, runner: SessionRunnerStub)
          end)
        end)
        |> Task.await_many(30_000)

      assert Enum.all?(results, &match?({:ok, _}, &1))
      ids = Enum.map(results, fn {:ok, %{session: s}} -> s.id end)
      assert [_single] = Enum.uniq(ids)
      assert [_one] = Enum.filter(Sessions.list(), &(&1.issue_id == issue.id))
    end

    # The backstop under `open/2`'s read-then-launch, proven directly rather
    # than only through the two-task test above: the sandbox serializes
    # everything through one connection, so a concurrent test can pass on the
    # fast path alone and say nothing about what happens when two writes
    # genuinely interleave. This asserts the write itself is refused.
    test "the database itself refuses a second live row for the issue", %{
      issue: issue,
      ws: ws
    } do
      %{session: _first} = open!(issue)

      second =
        try do
          Sessions.launch(
            issue_id: issue.id,
            workspace_id: ws.id,
            runner: SessionRunnerStub
          )
        rescue
          error -> {:error, error}
        end

      assert {:error, reason} = second
      assert %Ash.Error.Invalid{errors: [%Ash.Error.Changes.InvalidAttribute{} = error]} = reason
      assert error.field == :issue_id
      assert error.message =~ "already been taken"
      assert [_one] = Enum.filter(Sessions.list(), &(&1.issue_id == issue.id))
    end

    test "an ended refine session frees the issue for a new one", %{issue: issue} do
      %{session: first} = open!(issue)
      {:ok, _} = Sessions.mark_ended(first, "operator killed it")

      %{session: second, reopened?: false} = open!(issue)
      refute second.id == first.id
    end

    test "an ineligible issue is refused before anything is launched", %{issue: issue} do
      {:ok, closed} = Ash.update(issue, %{reason: "no longer wanted"}, action: :close)

      assert {:error, :not_refinable} = Refine.open(closed, runner: SessionRunnerStub)
      assert Sessions.list() == []
    end
  end

  describe "open/2 — the MCP token" do
    test "mints a refine-tier token bound to the issue, never a coordinator one", %{
      issue: issue,
      ws: ws
    } do
      %{session: session} = open!(issue)

      token = Sessions.mint_mcp_token(session)
      assert {:ok, scope} = Scope.from_token(token)

      assert scope.tier == :refine
      assert scope.issue_id == issue.id
      assert scope.workspace_id == ws.id
      assert scope.session_id == session.id
      refute scope.can_dispatch
    end

    test "a dispatch attempt from the session is refused", %{issue: issue} do
      %{session: session} = open!(issue)
      {:ok, scope} = Scope.from_token(Sessions.mint_mcp_token(session))

      assert {:rpc_error, -32003, message} =
               Catalog.call(scope, "worker_dispatch", %{"task_id" => issue.id})

      assert message =~ "refine session shapes work, it never starts it"
    end

    test "the on-disk .mcp.json carries that same refine token", %{issue: issue} do
      %{session: session} = open!(issue)

      config = session.cwd |> Path.join(".mcp.json") |> File.read!() |> Jason.decode!()

      token =
        get_in(config, ["mcpServers", Arbiter.MCP.server_name(), "headers", "Authorization"])

      assert {:ok, scope} = token |> String.replace_prefix("Bearer ", "") |> Scope.from_token()
      assert scope.tier == :refine
      assert scope.issue_id == issue.id
    end
  end

  describe "open/2 — the read-only checkout" do
    test "provisions one under the session root and tells the instructions about it", %{
      issue: issue
    } do
      %{session: session} = open!(issue)

      checkout = Layout.repo_checkout_dir(session.id)
      assert File.dir?(checkout)
      assert File.read!(Path.join(checkout, "widget.ex")) =~ "defmodule Widget"
      assert {:error, :eacces} = File.write(Path.join(checkout, "widget.ex"), "nope")

      instructions = File.read!(Path.join(session.cwd, "CLAUDE.md"))
      assert instructions =~ checkout
    end

    test "is removed when the session ends", %{issue: issue} do
      %{session: session} = open!(issue)
      checkout = Layout.repo_checkout_dir(session.id)
      assert File.dir?(checkout)

      {:ok, _} = Sessions.mark_ended(session, "done")

      refute File.exists?(checkout)
    end

    test "an issue with no repo launches anyway, and the instructions say so", %{ws: ws} do
      {:ok, issue} =
        Ash.create(Issue, %{title: "No repo here", workspace_id: ws.id, repo: nil})

      {:ok, issue} = Ash.update(issue, %{repo: nil}, action: :update)

      %{session: session} = open!(issue)

      refute File.exists?(Layout.repo_checkout_dir(session.id))
      instructions = File.read!(Path.join(session.cwd, "CLAUDE.md"))
      assert instructions =~ "No read-only checkout"
    end

    test "an unregistered repo is not a failed launch", %{ws: ws} do
      {:ok, issue} =
        Ash.create(Issue, %{title: "Unmapped repo", workspace_id: ws.id, repo: "widget"})

      {:ok, issue} = Ash.update(issue, %{repo: "nowhere"}, action: :update)

      %{session: session} = open!(issue)
      refute File.exists?(Layout.repo_checkout_dir(session.id))
    end
  end

  describe "open/2 — the instructions" do
    test "render child 2's refine variant with this issue's context", %{issue: issue, ws: ws} do
      {:ok, epic} =
        Ash.create(Issue, %{
          title: "The parent epic",
          workspace_id: ws.id,
          issue_type: :epic,
          repo: "widget"
        })

      {:ok, _} = Dependencies.add(epic.id, issue.id, :parent_of)

      %{session: session} = open!(issue)

      instructions = File.read!(Path.join(session.cwd, "CLAUDE.md"))
      assert instructions =~ "You are a **refine session**"
      assert instructions =~ issue.id
      assert instructions =~ "Make widgets faster"
      assert instructions =~ "the widgets are slow"
      assert instructions =~ epic.id
      assert instructions =~ ws.id

      # Written as both names, for non-Claude providers (child 2).
      assert File.read!(Path.join(session.cwd, "AGENTS.md")) == instructions
    end

    test "the coordinator instructions are not what a refine session gets", %{issue: issue} do
      %{session: session} = open!(issue)

      refute File.exists?(Layout.instructions_path(session.id))
    end
  end

  describe "open/2 — model routing" do
    test "launches on the premium tier at a high thinking level", %{issue: issue} do
      %{session: session} = open!(issue)

      script = launch_script!(session)
      assert script =~ "--model opus"
      assert script =~ "--effort high"
    end

    test "honours a workspace's premium tier_models override", %{issue: issue, ws: ws} do
      {:ok, ws} =
        Ash.update(
          ws,
          %{
            config:
              Map.merge(ws.config, %{
                "agent" => %{
                  "type" => "claude",
                  "config" => %{"tier_models" => %{"premium" => "opus-4-6"}}
                }
              })
          },
          action: :update
        )

      assert ws.config["agent"]["config"]["tier_models"]["premium"] == "opus-4-6"

      %{session: session} = open!(issue)
      assert launch_script!(session) =~ "--model opus-4-6"
    end

    test "never routes to the flagship tier, even when the workspace's rules would", %{
      issue: issue,
      ws: ws
    } do
      {:ok, _ws} =
        Ash.update(
          ws,
          %{
            config:
              Map.merge(ws.config, %{
                "agent" => %{
                  "type" => "claude",
                  "config" => %{
                    "tier_models" => %{"premium" => "opus", "flagship" => "fable"}
                  }
                },
                "routing" => %{
                  "policy" => "by_difficulty",
                  "rules" => %{
                    "D0" => %{"model_tier" => "flagship", "thinking" => "max"},
                    "D1" => %{"model_tier" => "flagship", "thinking" => "max"},
                    "D2" => %{"model_tier" => "flagship", "thinking" => "max"},
                    "D3" => %{"model_tier" => "flagship", "thinking" => "max"},
                    "D4" => %{"model_tier" => "flagship", "thinking" => "max"},
                    "D5" => %{"model_tier" => "flagship", "thinking" => "max"}
                  }
                }
              })
          },
          action: :update
        )

      %{session: session} = open!(issue)

      script = launch_script!(session)
      assert script =~ "--model opus"
      refute script =~ "fable"
      refute script =~ "--effort max"
    end
  end
end
