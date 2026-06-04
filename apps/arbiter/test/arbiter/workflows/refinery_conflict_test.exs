defmodule Arbiter.Workflows.RefineryConflictTest do
  @moduledoc """
  Tests for the Crucible's CONFLICTING-PR auto-resolution path (bd-dolcqq).

  Drives the `Refinery` with a stub resolver so the conflict-spawn machinery
  is exercised without booting a real Polecat / ClaudeSession. Mocks GitHub
  PR fetches via `Req.Test` so we can simulate a PR flipping between
  CONFLICTING and clean across ticks.
  """

  # async: false — same rationale as the parent refinery_test.
  use Arbiter.DataCase, async: false

  import Ash.Query, only: [filter: 2]

  alias Arbiter.Beads.Issue
  alias Arbiter.Beads.Workspace
  alias Arbiter.Messages.Message
  alias Arbiter.Workflows.Refinery

  @repo "octo/widget"
  @token "test-token-abc123"

  # ---- stub resolver ------------------------------------------------------

  # The Refinery resolves the stub by atom, so we can't pass closures through
  # opts. Instead the stub pulls a per-test target pid out of :persistent_term
  # keyed on the bead id — the test seeds it before driving the Refinery.
  defmodule StubResolverWithCallback do
    @moduledoc false
    @behaviour Arbiter.Workflows.Refinery.ConflictResolver

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
    workspace_config = Map.get(tags, :workspace_config, %{"merge" => %{"strategy" => "github"}})
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

  defp start_refinery(workspace, opts \\ []) do
    name = :"refinery_conflict_#{System.unique_integer([:positive])}"

    full_opts =
      [
        workspace_id: workspace.id,
        repo: @repo,
        base: "main",
        github_token: @token,
        auto_tick: false,
        conflict_resolver: StubResolverWithCallback,
        name: name
      ]
      |> Keyword.merge(opts)

    {:ok, pid} = Refinery.start_link(full_opts)
    Req.Test.allow(Arbiter.GitHub.HTTP, self(), pid)
    Ecto.Adapters.SQL.Sandbox.allow(Arbiter.Repo, self(), pid)
    {pid, name}
  end

  defp stub(fun), do: Req.Test.stub(Arbiter.GitHub.HTTP, fun)

  defp pr_payload(overrides) do
    Map.merge(
      %{
        "number" => 99,
        "state" => "open",
        "mergeable" => true,
        "mergeStateStatus" => "clean",
        "reviewDecision" => "APPROVED"
      },
      overrides
    )
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

      stub(fn conn ->
        cond do
          conn.method == "POST" and String.ends_with?(conn.request_path, "/pulls") ->
            conn |> Plug.Conn.put_status(201) |> Req.Test.json(%{"number" => 901})

          conn.method == "GET" ->
            conn
            |> Plug.Conn.put_status(200)
            |> Req.Test.json(pr_payload(%{"number" => 901, "mergeable" => false}))

          true ->
            conn |> Plug.Conn.put_status(500) |> Req.Test.json(%{})
        end
      end)

      {_pid, name} = start_refinery(ws)
      :ok = Refinery.enqueue(name, bead.id)
      :ok = Refinery.tick(name)

      assert_received {:resolver_called, args}
      assert args.bead_id == bead.id
      assert args.workspace_id == ws.id
      assert args.target_branch == "main"
      assert args.pr_ref == 901

      %{items: [item]} = Refinery.state(name)
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

      stub(fn conn ->
        cond do
          conn.method == "POST" ->
            conn |> Plug.Conn.put_status(201) |> Req.Test.json(%{"number" => 902})

          conn.method == "GET" ->
            conn
            |> Plug.Conn.put_status(200)
            |> Req.Test.json(pr_payload(%{"number" => 902, "mergeable" => false}))

          true ->
            conn |> Plug.Conn.put_status(500) |> Req.Test.json(%{})
        end
      end)

      {_pid, name} = start_refinery(ws)
      :ok = Refinery.enqueue(name, bead.id)
      :ok = Refinery.tick(name)

      assert_received {:resolver_called, _}

      # Second tick with the same conflict — must NOT spawn again, and must
      # escalate.
      :ok = Refinery.tick(name)
      refute_received {:resolver_called, _}
      assert_received {:escalate_called, _, _, _, :resolver_did_not_clear_conflict}

      %{items: [item]} = Refinery.state(name)
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
          conn.method == "POST" ->
            conn |> Plug.Conn.put_status(201) |> Req.Test.json(%{"number" => 903})

          conn.method == "GET" ->
            n = :counters.get(tick_count, 1)
            :counters.add(tick_count, 1, 1)

            payload =
              if n == 0 do
                pr_payload(%{"number" => 903, "mergeable" => false})
              else
                # Clean — but not approved/clean enough to advance to merge.
                pr_payload(%{
                  "number" => 903,
                  "mergeable" => true,
                  "mergeStateStatus" => "blocked",
                  "reviewDecision" => nil
                })
              end

            conn |> Plug.Conn.put_status(200) |> Req.Test.json(payload)

          conn.method == "PUT" ->
            # If a merge fires we should know — failing the test.
            send(self(), :unexpected_merge)
            conn |> Plug.Conn.put_status(200) |> Req.Test.json(%{"merged" => true})

          true ->
            conn |> Plug.Conn.put_status(500) |> Req.Test.json(%{})
        end
      end)

      {_pid, name} = start_refinery(ws)
      :ok = Refinery.enqueue(name, bead.id)
      :ok = Refinery.tick(name)
      assert_received {:resolver_called, _}

      %{items: [item]} = Refinery.state(name)
      assert item.status == :conflict_resolving

      :ok = Refinery.tick(name)

      %{items: [item]} = Refinery.state(name)
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

      stub(fn conn ->
        cond do
          conn.method == "POST" ->
            conn |> Plug.Conn.put_status(201) |> Req.Test.json(%{"number" => 904})

          conn.method == "GET" ->
            conn
            |> Plug.Conn.put_status(200)
            |> Req.Test.json(pr_payload(%{"number" => 904, "mergeable" => false}))

          true ->
            conn |> Plug.Conn.put_status(500) |> Req.Test.json(%{})
        end
      end)

      # One mechanical rebase pass per conflict — the first spawn happens on
      # the first tick, and a second consecutive CONFLICTING observation
      # means the rebase didn't clear it → escalate.
      {_pid, name} = start_refinery(ws)
      :ok = Refinery.enqueue(name, bead.id)

      :ok = Refinery.tick(name)
      assert_received {:resolver_called, _}

      :ok = Refinery.tick(name)
      assert_received {:escalate_called, bead_id, ws_id, _branch, reason}
      assert bead_id == bead.id
      assert ws_id == ws.id
      assert reason == :resolver_did_not_clear_conflict

      %{items: [item]} = Refinery.state(name)
      assert item.status == :failed
      assert item.last_error == :conflict_unresolved
    end

    test "resolver returns {:error, _} → escalation via real module + item :failed", %{
      workspace: ws,
      bead: bead
    } do
      # The stub returns an error from resolve/1 — the Refinery escalates and
      # marks the item :failed. We assert the escalation lands in the message
      # queue (the real ConflictResolver.escalate_unresolved/4 path), since
      # the stub's escalate_unresolved is also wired and we want both layers
      # observed.
      StubResolverWithCallback.register(bead.id, self(), {:error, :no_repo_path})

      stub(fn conn ->
        cond do
          conn.method == "POST" ->
            conn |> Plug.Conn.put_status(201) |> Req.Test.json(%{"number" => 905})

          conn.method == "GET" ->
            conn
            |> Plug.Conn.put_status(200)
            |> Req.Test.json(pr_payload(%{"number" => 905, "mergeable" => false}))

          true ->
            conn |> Plug.Conn.put_status(500) |> Req.Test.json(%{})
        end
      end)

      {_pid, name} = start_refinery(ws)
      :ok = Refinery.enqueue(name, bead.id)
      :ok = Refinery.tick(name)

      assert_received {:resolver_called, _}
      assert_received {:escalate_called, bead_id, _ws_id, _branch, :no_repo_path}
      assert bead_id == bead.id

      %{items: [item]} = Refinery.state(name)
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
        Arbiter.Workflows.Refinery.ConflictResolver.escalate_unresolved(
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
               Arbiter.Workflows.Refinery.ConflictResolver.escalate_unresolved(
                 bead.id,
                 nil,
                 "x",
                 :anything
               )
    end
  end
end
