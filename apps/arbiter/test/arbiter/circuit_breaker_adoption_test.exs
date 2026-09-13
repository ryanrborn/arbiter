defmodule Arbiter.CircuitBreakerAdoptionTest do
  @moduledoc """
  Acceptance 2 and 4 of bd-5jr49o: every registered call site is really gated,
  identical repeated triggers produce at most K actions plus exactly one
  "breaker tripped" escalation, and the two named incident shapes stop at the
  bound.

  PRPatrol's adoption is covered in `workflows/pr_patrol_test.exs` and
  DispatchQueue's in `workflows/dispatch_queue_test.exs`, where the existing
  harnesses can drive the real tick / drain paths.
  """
  use Arbiter.DataCase, async: false

  alias Arbiter.CircuitBreaker
  alias Arbiter.Messages.{CoordinatorNotifier, Message}
  alias Arbiter.Tasks.Workspace
  alias Arbiter.Worker.{Dispatch, StopReason, Watchdog}

  require Ash.Query

  setup do
    CircuitBreaker.reset_all()
    on_exit(&CircuitBreaker.reset_all/0)

    {:ok, ws} =
      Ash.create(Workspace, %{
        name: "cb-adopt-#{System.unique_integer([:positive])}",
        prefix: "cba#{System.unique_integer([:positive])}"
      })

    {:ok, ws: ws}
  end

  # Tighten one kind's bound for the duration of a test so a flood can be
  # driven in a handful of calls instead of the production K.
  defp with_bound(kind, limit) do
    prior = Application.get_env(:arbiter, :circuit_breaker, [])

    Application.put_env(
      :arbiter,
      :circuit_breaker,
      Keyword.put(prior, kind, limit: limit, window_ms: 60_000)
    )

    on_exit(fn -> Application.put_env(:arbiter, :circuit_breaker, prior) end)
  end

  defp escalations(ws) do
    Message
    |> Ash.Query.filter(workspace_id == ^ws.id and kind == :escalation)
    |> Ash.read!()
  end

  defp trip_escalations(ws) do
    ws |> escalations() |> Enum.filter(&(&1.subject =~ "circuit breaker tripped"))
  end

  describe "Arbiter.Worker.Dispatch.escalate_preflight_failure/2 (bd-8lnnnt shape)" do
    test "at most K identical pre-flight refusals act, then one breaker escalation", %{ws: ws} do
      with_bound(:preflight_auth_failed, 2)

      snapshot = %{task_id: "bd-pfa001", workspace_id: ws.id, repo: "owner/repo", meta: %{}}

      reason = %StopReason{
        category: :quota_exhausted,
        summary: "5h usage limit reached",
        remediation: "wait for the window to reset"
      }

      results = for _ <- 1..14, do: Dispatch.escalate_preflight_failure(snapshot, reason)

      assert Enum.count(results, &(&1 == :ok)) == 2
      assert Enum.count(results, &(&1 == :suppressed)) == 12
      assert length(trip_escalations(ws)) == 1
    end

    test "a different task's refusal is not suppressed by the first task's breaker", %{ws: ws} do
      with_bound(:preflight_auth_failed, 2)

      reason = %StopReason{category: :auth_expired, summary: "expired", remediation: "re-auth"}
      snap = fn id -> %{task_id: id, workspace_id: ws.id, repo: "owner/repo", meta: %{}} end

      for _ <- 1..5, do: Dispatch.escalate_preflight_failure(snap.("bd-pfa002"), reason)

      assert :ok = Dispatch.escalate_preflight_failure(snap.("bd-pfa003"), reason)
    end

    test "the attempt counter in the summary does not defeat deduplication", %{ws: ws} do
      with_bound(:preflight_auth_failed, 2)

      snapshot = %{task_id: "bd-pfa004", workspace_id: ws.id, repo: "owner/repo", meta: %{}}

      results =
        for i <- 1..8 do
          reason = %StopReason{
            category: :quota_exhausted,
            summary: "5h usage limit reached (attempt #{i}, #{i * 37}s elapsed)",
            remediation: "wait"
          }

          Dispatch.escalate_preflight_failure(snapshot, reason)
        end

      assert Enum.count(results, &(&1 == :ok)) == 2
      assert length(trip_escalations(ws)) == 1
    end
  end

  describe "Arbiter.Worker.Watchdog merge escalations (bd-6bg54c shape)" do
    test "an auto-merge stall escalating every poll stops at the bound", %{ws: ws} do
      with_bound(:watchdog_merge_escalation, 3)

      snapshot = %{task_id: "bd-wd001", workspace_id: ws.id}

      # The Watchdog re-pages with a growing consecutive-failure count; the
      # count must not make each page look like a new signature.
      results =
        for attempts <- 1..30 do
          Watchdog.escalate_merge_stall(snapshot, "owner/repo#77", attempts, :unknown_state)
        end

      assert Enum.count(results, &(&1 == :ok)) == 3
      assert length(trip_escalations(ws)) == 1
    end

    test "an exhausted auto-resolve escalating repeatedly stops at the bound", %{ws: ws} do
      with_bound(:watchdog_merge_escalation, 3)

      snapshot = %{task_id: "bd-wd002", workspace_id: ws.id}

      results =
        for attempts <- 1..12 do
          Watchdog.escalate_merge_unresolved(snapshot, "owner/repo#88", :ci_failed, attempts, [])
        end

      assert Enum.count(results, &(&1 == :ok)) == 3
      assert length(trip_escalations(ws)) == 1
    end

    test "two different MRs do not share a budget", %{ws: ws} do
      with_bound(:watchdog_merge_escalation, 2)

      snapshot = %{task_id: "bd-wd003", workspace_id: ws.id}

      for i <- 1..6, do: Watchdog.escalate_merge_stall(snapshot, "owner/repo#90", i, :conflict)

      assert :ok = Watchdog.escalate_merge_stall(snapshot, "owner/repo#91", 1, :conflict)
    end
  end

  describe "CoordinatorNotifier escalation send path — last line of defence" do
    test "an undeduplicated escalation repeated forever stops at the bound", %{ws: ws} do
      with_bound(:coordinator_escalation, 3)

      snapshot = %{task_id: "bd-cn001", workspace_id: ws.id}

      for _ <- 1..20 do
        CoordinatorNotifier.tracker_sync_failed(snapshot, :dispatch, {:error, :boom})
      end

      sync = Enum.reject(escalations(ws), &(&1.subject =~ "circuit breaker tripped"))

      assert length(sync) == 3
      assert length(trip_escalations(ws)) == 1
    end

    test "bd-brwx7w replay: two pollers escalating the same condition stop at one bound",
         %{ws: ws} do
      with_bound(:coordinator_escalation, 4)

      snapshot = %{task_id: "bd-cn002", workspace_id: ws.id}

      # Two independent pollers, each re-detecting and paging the same condition
      # on its own cadence — the bd-brwx7w shape. The breaker is shared state,
      # so their budgets are one budget, not one each.
      poller = fn reason ->
        Task.async(fn ->
          for _ <- 1..15 do
            CoordinatorNotifier.merge_park_heartbeat(snapshot, "owner/repo#12", reason, 1)
          end
        end)
      end

      [poller.(:needs_approval), poller.(:needs_approval)]
      |> Task.await_many(15_000)

      pages = Enum.reject(escalations(ws), &(&1.subject =~ "circuit breaker tripped"))

      assert length(pages) <= 4,
             "two pollers must share one budget, got #{length(pages)} pages"

      assert length(trip_escalations(ws)) == 1
    end

    test "the breaker's own trip escalation is never itself suppressed", %{ws: ws} do
      with_bound(:coordinator_escalation, 1)

      snapshot = %{task_id: "bd-cn003", workspace_id: ws.id}

      for _ <- 1..10 do
        CoordinatorNotifier.tracker_sync_failed(snapshot, :dispatch, {:error, :boom})
      end

      assert [trip] = trip_escalations(ws)
      assert trip.body =~ "arb breaker reset"
      assert trip.body =~ "coordinator_escalation"
    end

    test "distinct escalation subjects keep distinct budgets", %{ws: ws} do
      with_bound(:coordinator_escalation, 2)

      for id <- ["bd-cn010", "bd-cn011", "bd-cn012"] do
        for _ <- 1..3 do
          CoordinatorNotifier.tracker_sync_failed(
            %{task_id: id, workspace_id: ws.id},
            :dispatch,
            {:error, :boom}
          )
        end
      end

      # Three subjects × 2 allowed each: the breaker must not have collapsed
      # three different tasks into one signature.
      pages = Enum.reject(escalations(ws), &(&1.subject =~ "circuit breaker tripped"))
      assert length(pages) == 6
    end
  end

  describe "registry coverage (acceptance 2)" do
    test "every registered kind is actually referenced by its owning module" do
      for %{kind: kind, module: module} <- CircuitBreaker.call_sites() do
        path = source_path(module)

        assert File.exists?(path), "no source found for #{inspect(module)} at #{path}"

        assert File.read!(path) =~ to_string(kind),
               "#{inspect(module)} is registered as the owner of the #{kind} breaker " <>
                 "but never references it — the registry has drifted from the code"
      end
    end
  end

  defp source_path(module) do
    module
    |> Module.split()
    |> Enum.map(&Macro.underscore/1)
    |> then(fn parts -> Path.join(["lib" | parts]) <> ".ex" end)
    |> then(&Path.join([__DIR__, "..", "..", &1]))
    |> Path.expand()
  end
end
