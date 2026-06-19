defmodule Arbiter.Workflows.MergeQueueConflictTest do
  @moduledoc """
  Tests for the merge queue's CONFLICTING-PR auto-resolution path (bd-dolcqq).

  Drives the `MergeQueue` with a stub resolver so the conflict-spawn machinery
  is exercised without booting a real Polecat / ClaudeSession. Mocks GitHub
  PR fetches via `Req.Test` so we can simulate a PR flipping between
  CONFLICTING and clean across ticks.
  """

  # async: false — same rationale as the parent merge_queue_test.
  use Arbiter.DataCase, async: false

  import Ash.Query, only: [filter: 2]

  alias Arbiter.Beads.Issue
  alias Arbiter.Beads.Workspace
  alias Arbiter.Messages.Message
  alias Arbiter.Workflows.MergeQueue

  @token "test-token-abc123"

  @ws_github %{
    "merge" => %{
      "strategy" => "github",
      "config" => %{
        "owner" => "octo",
        "repo" => "widget",
        "credentials_ref" => @token
      }
    }
  }

  # ---- stub resolver ------------------------------------------------------

  # The MergeQueue resolves the stub by atom, so we can't pass closures through
  # opts. Instead the stub pulls a per-test target pid out of :persistent_term
  # keyed on the bead id — the test seeds it before driving the MergeQueue.
  defmodule StubResolverWithCallback do
    @moduledoc false
    @behaviour Arbiter.Workflows.MergeQueue.ConflictResolver

    @impl true
    def resolve(args) do
      bead_id = Map.fetch!(args, :bead_id)

      case lookup(bead_id) do
        {pid, resolver_result} ->
          send(pid, {:resolver_called, args})

          case resolver_result do
            :ok -> {:ok, %{polecat_pid: pid, worktree_path: "/tmp/fake", branch: "x"}}
            err -> err
          end

        nil ->
          {:error, :no_callback_registered}
      end
    end

    @impl true
    def escalate_unresolved(bead_id, workspace_id, branch, reason) do
      case lookup(bead_id) do
        {pid, _} ->
          send(pid, {:escalate_called, bead_id, workspace_id, branch, reason})
          :ok

        nil ->
          :ok
      end
    end

    @impl true
    def notify_resolution(bead_id, workspace_id, branch) do
      case lookup(bead_id) do
        {pid, _} ->
          send(pid, {:notify_called, bead_id, workspace_id, branch})
          :ok

        nil ->
          :ok
      end
    end

    def register(bead_id, pid, resolver_result \\ :ok) do
      :persistent_term.put({__MODULE__, bead_id}, {pid, resolver_result})
    end

    def unregister(bead_id) do
      :persistent_term.erase({__MODULE__, bead_id})
    end

    defp lookup(bead_id) do
      :persistent_term.get({__MODULE__, bead_id}, nil)
    end
  end

  # ---- setup --------------------------------------------------------------

  setup tags do
    workspace_config = Map.get(tags, :workspace_config, @ws_github)
    ws_name = "ws-#{System.unique_integer([:positive])}"

    {:ok, workspace} =
      Ash.create(Workspace, %{
        name: ws_name,
        prefix: "rct#{System.unique_integer([:positive])}",
        config: workspace_config
      })

    {:ok, bead} =
      Ash.create(Issue, %{
        title: "conflict me",
        description: "bead under conflict test",
        workspace_id: workspace.id
      })

    on_exit(fn -> StubResolverWithCallback.unregister(bead.id) end)

    %{workspace: workspace, bead: bead}
  end

  defp start_merge_queue(workspace, opts \\ []) do
    name = :"merge_queue_conflict_#{System.unique_integer([:positive])}"

    full_opts =
      [
        workspace_id: workspace.id,
        base: "main",
        auto_tick: false,
        conflict_resolver: StubResolverWithCallback,
        name: name
      ]
      |> Keyword.merge(opts)

    {:ok, pid} = MergeQueue.start_link(full_opts)
    Req.Test.allow(Arbiter.Mergers.Github.HTTP, self(), pid)
    Ecto.Adapters.SQL.Sandbox.allow(Arbiter.Repo, self(), pid)
    {pid, name}
  end

  defp stub(fun), do: Req.Test.stub(Arbiter.Mergers.Github.HTTP, fun)

  defp pr_payload(overrides) do
    Map.merge(
      %{
        "number" => 99,
        "state" => "open",
        "mergeable" => true,
        "mergeStateStatus" => "clean",
        "html_url" => "https://github.com/octo/widget/pull/99"
      },
      overrides
    )
  end

  # Build a stub that serves PR open, PR get, reviews, and (optionally) merge.
  # `conflicting: true` → pr has `mergeable: false`; reviews always returns [].
  defp conflicting_stub(pr_number, extra_pr_overrides \\ %{}) do
    n = pr_number

    stub(fn conn ->
      cond do
        conn.method == "POST" and String.ends_with?(conn.request_path, "/pulls") ->
          conn
          |> Plug.Conn.put_status(201)
          |> Req.Test.json(%{
            "number" => n,
            "html_url" => "https://github.com/octo/widget/pull/#{n}"
          })

        conn.method == "GET" and String.ends_with?(conn.request_path, "/reviews") ->
          conn |> Plug.Conn.put_status(200) |> Req.Test.json([])

        conn.method == "GET" and String.contains?(conn.request_path, "/pulls/#{n}") ->
          conn
          |> Plug.Conn.put_status(200)
          |> Req.Test.json(
            pr_payload(Map.merge(%{"number" => n, "mergeable" => false}, extra_pr_overrides))
          )

        conn.method == "PUT" ->
          conn |> Plug.Conn.put_status(200) |> Req.Test.json(%{"merged" => true})

        true ->
          conn |> Plug.Conn.put_status(500) |> Req.Test.json(%{})
      end
    end)
  end

  # ---- conflict-detection helper ------------------------------------------

  describe "Arbiter.GitHub.conflicting?/1" do
    test "true when mergeable == false" do
      assert Arbiter.GitHub.conflicting?(%{"mergeable" => false})
    end

    test "true when mergeStateStatus == \"dirty\"" do
      assert Arbiter.GitHub.conflicting?(%{"mergeStateStatus" => "dirty"})
    end

    test "false on a clean payload" do
      refute Arbiter.GitHub.conflicting?(%{"mergeable" => true, "mergeStateStatus" => "clean"})
    end

    test "false when mergeable is nil (still computing)" do
      refute Arbiter.GitHub.conflicting?(%{"mergeable" => nil})
    end

    test "false on garbage input" do
      refute Arbiter.GitHub.conflicting?(nil)
      refute Arbiter.GitHub.conflicting?("not a map")
    end
  end

  # ---- auto-spawn ---------------------------------------------------------

  describe "CONFLICTING PR triggers auto-spawn" do
    test "first conflicting tick spawns the resolver and parks the item", %{
      workspace: ws,
      bead: bead
    } do
      StubResolverWithCallback.register(bead.id, self(), :ok)
      conflicting_stub(901)

      {_pid, name} = start_merge_queue(ws)
      :ok = MergeQueue.enqueue(name, bead.id)
      :ok = MergeQueue.tick(name)

      assert_received {:resolver_called, args}
      assert args.bead_id == bead.id
      assert args.workspace_id == ws.id
      assert args.target_branch == "main"
      assert args.pr_ref == "#901"

      %{items: [item]} = MergeQueue.state(name)
      assert item.status == :conflict_resolving
      assert %DateTime{} = item.resolver_spawned_at
      assert item.prior_status == :awaiting_approval
    end

    test "second conflicting tick does NOT re-spawn — escalates instead", %{
      workspace: ws,
      bead: bead
    } do
      # One mechanical rebase pass is all the resolver gets. If the next tick
      # still sees mergeable: false, the conflict is semantic — escalate
      # rather than spinning on more spawns.
      StubResolverWithCallback.register(bead.id, self(), :ok)
      conflicting_stub(902)

      {_pid, name} = start_merge_queue(ws)
      :ok = MergeQueue.enqueue(name, bead.id)
      :ok = MergeQueue.tick(name)

      assert_received {:resolver_called, _}

      # Second tick with the same conflict — must NOT spawn again, and must
      # escalate.
      :ok = MergeQueue.tick(name)
      refute_received {:resolver_called, _}
      assert_received {:escalate_called, _, _, _, :resolver_did_not_clear_conflict}

      %{items: [item]} = MergeQueue.state(name)
      assert item.status == :failed
      assert item.last_error == :conflict_unresolved
    end

    test "successful resolution (mergeable: true on next tick) restores prior status", %{
      workspace: ws,
      bead: bead
    } do
      bead_id = bead.id
      StubResolverWithCallback.register(bead.id, self(), :ok)

      # Toggle: first GET returns conflicting, second returns clean.
      tick_count = :counters.new(1, [:atomics])

      stub(fn conn ->
        cond do
          conn.method == "POST" and String.ends_with?(conn.request_path, "/pulls") ->
            conn
            |> Plug.Conn.put_status(201)
            |> Req.Test.json(%{
              "number" => 903,
              "html_url" => "https://github.com/octo/widget/pull/903"
            })

          conn.method == "GET" and String.ends_with?(conn.request_path, "/reviews") ->
            conn |> Plug.Conn.put_status(200) |> Req.Test.json([])

          conn.method == "GET" and String.contains?(conn.request_path, "/pulls/903") ->
            n = :counters.get(tick_count, 1)
            :counters.add(tick_count, 1, 1)

            payload =
              if n == 0 do
                pr_payload(%{"number" => 903, "mergeable" => false})
              else
                # Clean — but not approved/ci_clean enough to advance to merge.
                pr_payload(%{
                  "number" => 903,
                  "mergeable" => true,
                  "mergeStateStatus" => "blocked"
                })
              end

            conn |> Plug.Conn.put_status(200) |> Req.Test.json(payload)

          conn.method == "PUT" ->
            send(self(), :unexpected_merge)
            conn |> Plug.Conn.put_status(200) |> Req.Test.json(%{"merged" => true})

          true ->
            conn |> Plug.Conn.put_status(500) |> Req.Test.json(%{})
        end
      end)

      {_pid, name} = start_merge_queue(ws)
      :ok = MergeQueue.enqueue(name, bead.id)
      :ok = MergeQueue.tick(name)
      assert_received {:resolver_called, _}

      %{items: [item]} = MergeQueue.state(name)
      assert item.status == :conflict_resolving

      :ok = MergeQueue.tick(name)

      %{items: [item]} = MergeQueue.state(name)
      assert item.status == :awaiting_approval
      assert item.prior_status == nil
      assert item.resolver_spawned_at == nil

      # Acceptance criterion: Admiral / author is notified of the resolution.
      assert_received {:notify_called, ^bead_id, _ws_id, _branch}
    end
  end

  # ---- escalation ---------------------------------------------------------

  describe "escalation via mailbox" do
    test "second conflicting tick → escalation + item marked :failed", %{
      workspace: ws,
      bead: bead
    } do
      StubResolverWithCallback.register(bead.id, self(), :ok)
      conflicting_stub(904)

      # One mechanical rebase pass per conflict — the first spawn happens on
      # the first tick, and a second consecutive CONFLICTING observation
      # means the rebase didn't clear it → escalate.
      {_pid, name} = start_merge_queue(ws)
      :ok = MergeQueue.enqueue(name, bead.id)

      :ok = MergeQueue.tick(name)
      assert_received {:resolver_called, _}

      :ok = MergeQueue.tick(name)
      assert_received {:escalate_called, bead_id, ws_id, _branch, reason}
      assert bead_id == bead.id
      assert ws_id == ws.id
      assert reason == :resolver_did_not_clear_conflict

      %{items: [item]} = MergeQueue.state(name)
      assert item.status == :failed
      assert item.last_error == :conflict_unresolved
    end

    test "resolver returns {:error, _} → escalation via real module + item :failed", %{
      workspace: ws,
      bead: bead
    } do
      # The stub returns an error from resolve/1 — the MergeQueue escalates and
      # marks the item :failed. We assert the escalation lands in the message
      # queue (the real ConflictResolver.escalate_unresolved/4 path), since
      # the stub's escalate_unresolved is also wired and we want both layers
      # observed.
      StubResolverWithCallback.register(bead.id, self(), {:error, :no_repo_path})
      conflicting_stub(905)

      {_pid, name} = start_merge_queue(ws)
      :ok = MergeQueue.enqueue(name, bead.id)
      :ok = MergeQueue.tick(name)

      assert_received {:resolver_called, _}
      assert_received {:escalate_called, bead_id, _ws_id, _branch, :no_repo_path}
      assert bead_id == bead.id

      %{items: [item]} = MergeQueue.state(name)
      assert item.status == :failed
      assert match?({:resolver_spawn_failed, :no_repo_path}, item.last_error)
    end
  end

  # ---- ConflictResolver.escalate_unresolved/4 ----------------------------

  describe "ConflictResolver.escalate_unresolved/4" do
    test "creates an :escalation Message addressed to admiral", %{
      workspace: ws,
      bead: bead
    } do
      :ok =
        Arbiter.Workflows.MergeQueue.ConflictResolver.escalate_unresolved(
          bead.id,
          ws.id,
          "feature/" <> bead.id,
          :attempts_exhausted
        )

      messages =
        Message
        |> filter(workspace_id == ^ws.id and to_ref == "admiral" and kind == :escalation)
        |> Ash.read!()

      assert [msg] = messages
      assert msg.from_ref == bead.id
      assert msg.directive_ref == bead.id
      assert msg.body =~ "CONFLICTING"
      assert msg.body =~ bead.id
    end

    test "missing workspace_id is a no-op (does not raise)", %{bead: bead} do
      assert :ok =
               Arbiter.Workflows.MergeQueue.ConflictResolver.escalate_unresolved(
                 bead.id,
                 nil,
                 "x",
                 :anything
               )
    end
  end

  # ---- ConflictResolver.notify_resolution/3 ------------------------------

  describe "ConflictResolver.notify_resolution/3" do
    test "creates a :notification Message attributed to the bead", %{
      workspace: ws,
      bead: bead
    } do
      :ok =
        Arbiter.Workflows.MergeQueue.ConflictResolver.notify_resolution(
          bead.id,
          ws.id,
          "feature/" <> bead.id
        )

      messages =
        Message
        |> filter(workspace_id == ^ws.id and from_ref == ^bead.id and kind == :notification)
        |> Ash.read!()

      assert [msg] = messages
      assert msg.body =~ "auto-resolved"
      assert msg.body =~ bead.id
    end

    test "missing workspace_id is a no-op (does not raise)", %{bead: bead} do
      assert :ok =
               Arbiter.Workflows.MergeQueue.ConflictResolver.notify_resolution(
                 bead.id,
                 nil,
                 "x"
               )
    end
  end

  # ---- ConflictResolver.resolve/1 (the production path) ------------------

  # The block below exercises the real `resolve/1` against a fixture git
  # repo with an existing conflicting branch. This is the path the round-2
  # ReviewGate flagged as untested — every other test in this file uses a
  # stub that short-circuits `Worktree.attach` and `Polecat.start`. We bypass
  # the real `claude` invocation via `start_claude: false` (the resolver's
  # documented test escape) but still exercise the worktree-attach +
  # polecat-spawn pair where the two Major round-2 defects lived.
  describe "ConflictResolver.resolve/1 (production path)" do
    setup do
      tmp =
        Path.join(
          System.tmp_dir!(),
          "rct-prod-#{:erlang.unique_integer([:positive])}"
        )

      File.mkdir_p!(tmp)
      repo = Path.join(tmp, "repo")
      File.mkdir_p!(repo)

      {_, 0} = System.cmd("git", ["init", "-q", "-b", "main", repo])
      {_, 0} = System.cmd("git", ["-C", repo, "config", "user.email", "t@e.com"])
      {_, 0} = System.cmd("git", ["-C", repo, "config", "user.name", "T"])
      {_, 0} = System.cmd("git", ["-C", repo, "config", "commit.gpgsign", "false"])
      File.write!(Path.join(repo, "README.md"), "hello\n")
      {_, 0} = System.cmd("git", ["-C", repo, "add", "README.md"])
      {_, 0} = System.cmd("git", ["-C", repo, "commit", "-q", "-m", "i"])

      worktree_root = Path.join(tmp, "wt")
      File.mkdir_p!(worktree_root)

      prior_wt =
        case Application.fetch_env(:arbiter, :worktree_root) do
          {:ok, v} -> {:set, v}
          :error -> :unset
        end

      Application.put_env(:arbiter, :worktree_root, worktree_root)

      on_exit(fn ->
        case prior_wt do
          {:set, v} -> Application.put_env(:arbiter, :worktree_root, v)
          :unset -> Application.delete_env(:arbiter, :worktree_root)
        end

        File.rm_rf!(tmp)
      end)

      %{tmp: tmp, repo: repo}
    end

    test "attaches an EXISTING branch (does NOT use -b) and spawns a polecat under bead_id:conflict",
         %{workspace: ws, bead: bead, repo: repo} do
      # Pre-create the conflicting branch in the fixture repo. This is the
      # key precondition: the bead's branch already exists (the conflicting
      # PR is open against it), so `Worktree.create` (which uses -b) would
      # fail. `Worktree.attach` is the right tool.
      branch = Arbiter.Polecat.BranchNamer.derive(bead)
      {_, 0} = System.cmd("git", ["-C", repo, "branch", branch])

      # Pre-condition: no polecat registered yet under either slot.
      assert Arbiter.Polecat.whereis(bead.id) == nil
      assert Arbiter.Polecat.whereis(bead.id <> ":conflict") == nil

      {:ok, info} =
        Arbiter.Workflows.MergeQueue.ConflictResolver.resolve(%{
          bead_id: bead.id,
          workspace_id: ws.id,
          repo_path: repo,
          rig: "test/rig",
          start_claude: false
        })

      # The resolver returns a fresh polecat pid for the worktree it attached
      # to the existing branch.
      assert is_pid(info.polecat_pid)
      assert info.branch == branch
      assert is_binary(info.worktree_path)
      assert File.dir?(info.worktree_path)

      # Crucial: registry slot for the resolver is `bead_id:conflict`, NOT
      # `bead_id`. The bead_id slot stays open for the original work polecat.
      assert Arbiter.Polecat.whereis(bead.id <> ":conflict") == info.polecat_pid
      assert Arbiter.Polecat.whereis(bead.id) == nil

      # The polecat's meta carries the conflict-resolver role + the branch
      # being rebased — proves we built the polecat for this job, not
      # accidentally reused one from elsewhere.
      snap = Arbiter.Polecat.state(info.polecat_pid)
      assert snap.meta[:role] == :conflict_resolver
      assert snap.meta[:conflict_resolver_branch] == branch
      assert snap.meta[:target_branch] == "main"

      # Cleanup: the polecat was started under the DynamicSupervisor; tear it
      # down so the test doesn't leak processes.
      :ok = GenServer.stop(info.polecat_pid, :normal, 1_000)
    end

    test "a stale resolver polecat (already running for this bead) is surfaced, not papered over",
         %{workspace: ws, bead: bead, repo: repo} do
      # Simulate a previous resolver run that hasn't terminated by starting a
      # second polecat under the resolver's registry key. The resolver must
      # NOT silently return that pid — the round-2 finding was that the
      # `:already_started` shortcut hid a real wrong-process bug.
      branch = Arbiter.Polecat.BranchNamer.derive(bead)
      {_, 0} = System.cmd("git", ["-C", repo, "branch", branch])

      {:ok, prior} =
        Arbiter.Polecat.start(
          bead_id: bead.id,
          registry_key: bead.id <> ":conflict",
          rig: "test/rig",
          workspace_id: ws.id
        )

      result =
        Arbiter.Workflows.MergeQueue.ConflictResolver.resolve(%{
          bead_id: bead.id,
          workspace_id: ws.id,
          repo_path: repo,
          rig: "test/rig",
          start_claude: false
        })

      assert {:error, {:resolver_already_running, ^prior}} = result

      :ok = GenServer.stop(prior, :normal, 1_000)
    end

    test "no branch on the repo → {:error, {:worktree_failed, _}} (no silent -b creation)",
         %{workspace: ws, bead: bead, repo: repo} do
      # Deliberately do NOT pre-create the bead's branch. The resolver MUST
      # NOT silently fall back to `-b` and create a new branch; the contract
      # is "attach to the existing branch" — anything else risks shadowing
      # the PR's head ref.
      result =
        Arbiter.Workflows.MergeQueue.ConflictResolver.resolve(%{
          bead_id: bead.id,
          workspace_id: ws.id,
          repo_path: repo,
          rig: "test/rig",
          start_claude: false
        })

      assert {:error, {:worktree_failed, {:git_failed, _}}} = result
      # And no polecat got partially spawned.
      assert Arbiter.Polecat.whereis(bead.id <> ":conflict") == nil
    end
  end
end
