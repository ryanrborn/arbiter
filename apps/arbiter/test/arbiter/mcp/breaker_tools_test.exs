defmodule Arbiter.MCP.BreakerToolsTest do
  @moduledoc """
  Acceptance 1 and 5 of bd-5jr49o: the coordinator can inspect breaker state
  and re-arm a tripped breaker over MCP, and the call-site registry is visible
  even when nothing has tripped (the freshly-restarted-server case).
  """
  use Arbiter.DataCase, async: false

  alias Arbiter.CircuitBreaker
  alias Arbiter.MCP.{Catalog, Scope, Tools}
  alias Arbiter.Tasks.Workspace

  setup do
    CircuitBreaker.reset_all()
    on_exit(&CircuitBreaker.reset_all/0)

    {:ok, ws} =
      Ash.create(Workspace, %{
        name: "breaker-tools-#{System.unique_integer([:positive])}",
        prefix: "bkt#{System.unique_integer([:positive])}"
      })

    {:ok, ws: ws, coordinator: %Scope{tier: :coordinator, workspace_id: ws.id}}
  end

  defp trip(ws, kind \\ :coordinator_escalation) do
    opts = [workspace_id: ws.id, limit: 1, window_ms: 60_000, escalate: false]
    CircuitBreaker.check(kind, "a runaway condition", opts)
    CircuitBreaker.check(kind, "a runaway condition", opts)
  end

  describe "breaker_list/2" do
    test "lists the registered call sites on a server where nothing has tripped", ctx do
      assert {:ok, data} = Tools.breaker_list(ctx.coordinator, %{})

      assert data.breakers == []
      assert data.open_count == 0

      kinds = Enum.map(data.call_sites, & &1.kind)

      for kind <- ~w(pr_patrol_follow_up watchdog_merge_escalation preflight_auth_failed
                     dispatch_queue_redispatch coordinator_escalation) do
        assert kind in kinds
      end

      assert Enum.all?(data.call_sites, &(is_integer(&1.limit) and is_integer(&1.window_ms)))
    end

    test "reports a tripped breaker with its counts, window and timestamps", ctx do
      trip(ctx.ws)

      assert {:ok, data} = Tools.breaker_list(ctx.coordinator, %{})
      assert [entry] = data.breakers
      assert data.open_count == 1
      assert entry.open == true
      assert entry.count == 2
      assert entry.limit == 1
      assert entry.suppressed == 1
      assert entry.kind == "coordinator_escalation"
      assert {:ok, _, _} = DateTime.from_iso8601(entry.tripped_at)
    end

    test "filters by kind, and rejects an unregistered kind", ctx do
      trip(ctx.ws)

      assert {:ok, %{breakers: [_]}} =
               Tools.breaker_list(ctx.coordinator, %{"kind" => "coordinator_escalation"})

      assert {:ok, %{breakers: []}} =
               Tools.breaker_list(ctx.coordinator, %{"kind" => "pr_patrol_follow_up"})

      assert {:error, {:invalid, _}} =
               Tools.breaker_list(ctx.coordinator, %{"kind" => "not_a_kind"})
    end

    test "open_only hides a breaker that is merely counting", ctx do
      CircuitBreaker.check(:coordinator_escalation, "quiet",
        workspace_id: ctx.ws.id,
        limit: 9,
        escalate: false
      )

      assert {:ok, %{breakers: [_]}} = Tools.breaker_list(ctx.coordinator, %{})
      assert {:ok, %{breakers: []}} = Tools.breaker_list(ctx.coordinator, %{"open_only" => true})
    end
  end

  describe "breaker_reset/2" do
    test "closing a breaker by signature lets the suppressed action run again", ctx do
      assert {:suppress, info} = trip(ctx.ws)

      assert {:ok, %{reset: 1}} =
               Tools.breaker_reset(ctx.coordinator, %{"signature" => info.signature})

      assert :allow =
               CircuitBreaker.check(:coordinator_escalation, "a runaway condition",
                 workspace_id: ctx.ws.id,
                 limit: 1,
                 escalate: false
               )
    end

    test "an unknown signature is reported, not silently accepted", ctx do
      assert {:error, {:not_found, _}} =
               Tools.breaker_reset(ctx.coordinator, %{"signature" => "nope"})
    end

    test "reset with neither a signature nor `all` is refused", ctx do
      assert {:error, {:invalid, message}} = Tools.breaker_reset(ctx.coordinator, %{})
      assert message =~ "signature"
    end

    test "`all` scoped to this workspace closes its breakers", ctx do
      trip(ctx.ws)
      trip(ctx.ws, :pr_patrol_follow_up)

      assert {:ok, %{reset: 2}} = Tools.breaker_reset(ctx.coordinator, %{"all" => true})
      assert {:ok, %{breakers: []}} = Tools.breaker_list(ctx.coordinator, %{})
    end
  end

  # bd-21bmdh: the auth-shaped dispatch hold's operator surface rides the same
  # two verbs.
  describe "auth holds" do
    setup do
      {:ok, _} = Arbiter.Agents.AuthHold.reset(:all)
      Arbiter.Agents.CredentialWatchdog.reset()

      on_exit(fn ->
        {:ok, _} = Arbiter.Agents.AuthHold.reset(:all)
        Arbiter.Agents.CredentialWatchdog.reset()
      end)
    end

    defp open_claude_hold do
      reason = %Arbiter.Worker.StopReason{
        category: :auth_expired,
        summary: "401",
        remediation: nil,
        exit_status: 1,
        signal: nil
      }

      :counted = Arbiter.Agents.AuthHold.record_death(Arbiter.Agents.Claude, reason)
      :opened = Arbiter.Agents.AuthHold.record_death(Arbiter.Agents.Claude, reason)
    end

    test "breaker_list reports an open auth hold", ctx do
      assert {:ok, %{auth_holds: []}} = Tools.breaker_list(ctx.coordinator, %{})

      open_claude_hold()

      assert {:ok, %{auth_holds: [hold]}} = Tools.breaker_list(ctx.coordinator, %{})
      assert hold.provider == "claude"
      assert hold.open == true
      assert hold.deaths == 2
      assert hold.threshold == 2
      assert {:ok, _, _} = DateTime.from_iso8601(hold.opened_at)
    end

    test "breaker_reset with `provider` clears the hold and lets dispatch through", ctx do
      open_claude_hold()
      assert Arbiter.Agents.AuthHold.open?(Arbiter.Agents.Claude)

      assert {:ok, %{reset: 1, auth_hold: "claude"}} =
               Tools.breaker_reset(ctx.coordinator, %{"provider" => "claude"})

      refute Arbiter.Agents.AuthHold.open?(Arbiter.Agents.Claude)
    end

    test "an unknown provider is refused, not silently accepted", ctx do
      assert {:error, {:invalid, message}} =
               Tools.breaker_reset(ctx.coordinator, %{"provider" => "clawd"})

      assert message =~ "unknown provider"
    end
  end

  describe "end-to-end through the catalog dispatch the MCP transport uses" do
    test "breaker_list then breaker_reset, by name, as a coordinator scope", ctx do
      assert {:suppress, info} = trip(ctx.ws)

      assert {:ok, listed} = Catalog.call(ctx.coordinator, "breaker_list", %{})
      assert listed.open_count == 1

      assert {:ok, %{reset: 1}} =
               Catalog.call(ctx.coordinator, "breaker_reset", %{"signature" => info.signature})

      assert {:ok, %{open_count: 0}} = Catalog.call(ctx.coordinator, "breaker_list", %{})
    end

    test "a worker scope may not call either tool", ctx do
      worker = %Scope{tier: :worker, workspace_id: ctx.ws.id, task_id: "bd-1"}

      assert {:rpc_error, _, message} = Catalog.call(worker, "breaker_list", %{})
      assert message =~ "not permitted for a worker scope"

      assert {:rpc_error, _, _} = Catalog.call(worker, "breaker_reset", %{"all" => true})
    end
  end

  describe "catalog registration" do
    test "both tools are coordinator-only and invisible to a worker" do
      worker = %Scope{tier: :worker, workspace_id: "w", task_id: "bd-1"}
      coordinator = %Scope{tier: :coordinator, workspace_id: "w"}

      worker_names = worker |> Catalog.visible() |> Enum.map(& &1.name)
      coord_names = coordinator |> Catalog.visible() |> Enum.map(& &1.name)

      for tool <- ["breaker_list", "breaker_reset"] do
        assert tool in coord_names
        refute tool in worker_names
      end
    end
  end
end
