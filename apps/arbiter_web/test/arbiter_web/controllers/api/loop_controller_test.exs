defmodule ArbiterWeb.Api.LoopControllerTest do
  # async: false — the pass reads via raw SQL on the sandbox connection and we
  # swap the :output_log_root app env.
  use ArbiterWeb.ConnCase, async: false

  alias Arbiter.Loop
  alias Arbiter.Loop.PendingWrite
  alias Arbiter.ReviewGate.Round
  alias Arbiter.Tasks.{Issue, Workspace}
  alias Arbiter.Usage.Event
  alias Arbiter.Worker.OutputLog
  alias Arbiter.Workers.Run

  setup %{conn: conn} do
    prev = Application.get_env(:arbiter, :output_log_root)
    root = Path.join(System.tmp_dir!(), "loop-ctrl-test-#{System.unique_integer([:positive])}")
    File.mkdir_p!(root)
    Application.put_env(:arbiter, :output_log_root, root)

    on_exit(fn ->
      File.rm_rf(root)

      if prev,
        do: Application.put_env(:arbiter, :output_log_root, prev),
        else: Application.delete_env(:arbiter, :output_log_root)
    end)

    {:ok, conn: put_req_header(conn, "accept", "application/json"), root: root}
  end

  # `Issue.workspace_id` is required, so every fixture task needs a home.
  defp workspace! do
    n = System.unique_integer([:positive])
    {:ok, ws} = Ash.create(Workspace, %{name: "loop-ctrl-#{n}", prefix: "lc#{n}"})
    ws
  end

  defp run!(attrs) do
    base = %{
      task_id: "bd-ctrl",
      repo: "arbiter",
      worker_type: :main,
      status: :completed,
      model: "claude-sonnet-5",
      started_at: DateTime.utc_now()
    }

    {:ok, run} = Ash.create(Run, Map.merge(base, attrs))
    run
  end

  describe "GET /api/loop/analyze" do
    test "runs the pass over a window and returns the markdown report", %{conn: conn} do
      # A context-exhaustion run mislabelled as rate-limited.
      c88 =
        run!(%{
          task_id: "bd-dyfaq3",
          status: :failed,
          failure_reason: "agent was rate-limited / the API was overloaded"
        })

      {:ok, h} = OutputLog.open(c88.id)
      OutputLog.append(h, "Autocompact is thrashing: refilled within 3 turns, 3 times in a row.")
      OutputLog.append(h, "⚙ claude session error · 523.8s · $4.61")
      OutputLog.close(h)

      conn = get(conn, ~p"/api/loop/analyze", %{since: "7d"})
      body = json_response(conn, 200)

      assert is_binary(body["markdown"])
      assert body["markdown"] =~ "Loop-analysis report"
      assert body["markdown"] =~ c88.id
      assert body["markdown"] =~ "context_exhaustion"
      assert body["summary"]["totals"]["failed"] >= 1
      # The pass recorded its own cost row.
      assert body["usage_event_id"]
    end

    test "the pass writes only its own-cost usage row (report-only)", %{conn: conn} do
      _ = run!(%{task_id: "bd-ctrl-2", status: :completed})
      before = Event |> Ash.read!() |> length()

      conn = get(conn, ~p"/api/loop/analyze", %{since: "24h"})
      assert %{"usage_event_id" => uid} = json_response(conn, 200)
      assert uid

      after_count = Event |> Ash.read!() |> length()
      assert after_count == before + 1

      {:ok, ev} = Ash.get(Event, uid)
      assert ev.step == :other
      assert ev.model == "loop-analysis-pass"
    end

    test "rejects a malformed since with 4xx", %{conn: conn} do
      conn = get(conn, ~p"/api/loop/analyze", %{since: "not-a-date"})
      assert response(conn, 400) || json_response(conn, 400)
    end

    test "the response body carries no :proposals key without the opt-in", %{conn: conn} do
      _ = run!(%{task_id: "bd-ctrl-3", status: :completed})

      conn = get(conn, ~p"/api/loop/analyze", %{since: "24h"})
      body = json_response(conn, 200)

      refute Map.has_key?(body, "proposals")
      assert Ash.read!(PendingWrite) == []
    end
  end

  describe "POST /api/loop/propose" do
    test "queues the proposals the report implies and applies nothing", %{conn: conn} do
      {:ok, issue} =
        Ash.create(Issue, %{title: "ctrl inert", difficulty: 1, workspace_id: workspace!().id})

      run =
        run!(%{
          task_id: issue.id,
          status: :failed,
          model: "claude-haiku-4-5",
          failure_reason: ":review_gate_rejected"
        })

      {:ok, _} =
        Ash.create(Round, %{
          task_id: issue.id,
          run_id: run.id,
          round: 2,
          role: :review,
          verdict: :request_changes,
          converged: false,
          findings: "Green tests but the new path is never executed at runtime — inert."
        })

      conn = post(conn, ~p"/api/loop/propose", %{since: "24h"})
      body = json_response(conn, 200)

      assert is_list(body["proposals"])
      assert body["proposals"] != []
      assert Enum.all?(body["proposals"], &(&1["state"] in ["proposed", "hypothesis"]))

      # Nothing was applied: the task's difficulty is untouched.
      {:ok, reloaded} = Ash.get(Issue, issue.id)
      assert reloaded.difficulty == 1
    end

    # `arb loop analyze --propose --limit N` parses `limit` with OptionParser as
    # an integer and posts it in a JSON body, so it never arrives as the string
    # the query-string routes see.
    test "accepts an integer limit from the JSON body", %{conn: conn} do
      _ = run!(%{task_id: "bd-ctrl-limit", status: :completed})

      conn = post(conn, ~p"/api/loop/propose", %{since: "24h", limit: 50})
      body = json_response(conn, 200)

      assert is_binary(body["markdown"])
      assert is_list(body["proposals"])
    end

    test "rejects a non-positive or non-numeric limit with a 400", %{conn: conn} do
      assert json_response(post(conn, ~p"/api/loop/propose", %{limit: 0}), 400)
      assert json_response(post(conn, ~p"/api/loop/propose", %{limit: "lots"}), 400)
      assert json_response(get(conn, ~p"/api/loop/analyze", %{limit: "-3"}), 400)
    end
  end

  describe "POST /api/loop/propose/repo_doc_patch" do
    test "hand-authors a :repo_doc_patch proposal", %{conn: conn} do
      ws = workspace!()

      conn =
        post(conn, ~p"/api/loop/propose/repo_doc_patch", %{
          repo: "myrepo",
          lesson: "this repo's tests need FLAG=1 set",
          workspace_id: ws.id
        })

      body = json_response(conn, 200)

      assert body["pending"]["kind"] == "repo_doc_patch"
      assert body["pending"]["state"] == "proposed"
      assert body["pending"]["payload"]["lesson"] == "this repo's tests need FLAG=1 set"
    end

    test "400s when `repo` is missing", %{conn: conn} do
      conn = post(conn, ~p"/api/loop/propose/repo_doc_patch", %{lesson: "some lesson"})
      assert json_response(conn, 400)
    end

    test "400s when `lesson` is missing", %{conn: conn} do
      conn = post(conn, ~p"/api/loop/propose/repo_doc_patch", %{repo: "myrepo"})
      assert json_response(conn, 400)
    end
  end

  describe "the pending queue" do
    setup do
      row = proposed_row()
      %{row: row}
    end

    test "GET /api/loop/pending lists live states with the evidence bar", %{
      conn: conn,
      row: row
    } do
      conn = get(conn, ~p"/api/loop/pending")
      body = json_response(conn, 200)

      summary = Enum.find(body["pending"], &(&1["id"] == row.id))
      assert summary
      assert body["evidence_bar"]["min_incidents"] == 3
      assert body["evidence_bar"]["min_distinct_tasks"] == 2
      # Amendment D: `arb loop pending` renders the recurring context price
      # straight off this summary shape, so it travels even when it is zero.
      assert summary["context_cost_tokens"] == row.context_cost_tokens
      # The summary shape stays compact — the diff is on the detail route.
      refute Map.has_key?(hd(body["pending"]), "diff")
    end

    test "GET /api/loop/pending rejects an unknown state rather than returning nothing", %{
      conn: conn
    } do
      conn = get(conn, ~p"/api/loop/pending", %{state: "propsed"})
      assert json_response(conn, 400)
    end

    test "GET /api/loop/pending/:id returns the full row including the diff", %{
      conn: conn,
      row: row
    } do
      conn = get(conn, ~p"/api/loop/pending/#{row.id}")
      body = json_response(conn, 200)

      assert body["pending"]["diff"] =~ "+difficulty: 3"
      assert body["pending"]["fingerprint"] == row.fingerprint
      assert body["pending"]["applicable"] == true
    end

    test "GET /api/loop/pending/:id 404s on an unknown id", %{conn: conn} do
      conn = get(conn, ~p"/api/loop/pending/#{Ecto.UUID.generate()}")
      assert json_response(conn, 404)
    end

    test "POST .../apply applies through the domain API and marks the row applied", %{
      conn: conn,
      row: row
    } do
      conn = post(conn, ~p"/api/loop/pending/#{row.id}/apply", %{})
      body = json_response(conn, 200)

      assert body["applied"] == true
      assert body["pending"]["state"] == "applied"

      {:ok, issue} = Ash.get(Issue, row.target)
      assert issue.difficulty == 3
    end

    test "POST .../apply refuses a hypothesis, naming what it still needs", %{conn: conn} do
      # Fleet scope, one incident: below the bar, so it lands as a hypothesis.
      hyp =
        proposed_row(%{
          kind: :skill_patch,
          scope: :fleet,
          incident_refs: ["one"],
          task_refs: ["bd-solo"]
        })

      assert hyp.state == :hypothesis

      conn = post(conn, ~p"/api/loop/pending/#{hyp.id}/apply", %{})
      body = json_response(conn, 400)

      assert inspect(body) =~ "1 incident"
      {:ok, unchanged} = Loop.get_pending(hyp.id)
      assert unchanged.state == :hypothesis
    end

    test "POST .../reject is soft and records the reason", %{conn: conn, row: row} do
      conn = post(conn, ~p"/api/loop/pending/#{row.id}/reject", %{reason: "handled by hand"})
      body = json_response(conn, 200)

      assert body["rejected"] == true
      assert body["pending"]["state"] == "rejected"
      assert body["pending"]["rejection_reason"] == "handled by hand"

      # Soft: the row is still there.
      assert {:ok, _} = Loop.get_pending(row.id)
    end
  end

  # A task-scoped difficulty bump: applicable immediately (blast radius 1), and
  # its apply path lands on a real Issue.
  defp proposed_row(attrs \\ %{}) do
    n = System.unique_integer([:positive])

    {:ok, issue} =
      Ash.create(Issue, %{title: "ctrl target #{n}", difficulty: 2, workspace_id: workspace!().id})

    base = %{
      kind: :difficulty_override,
      scope: :task,
      gist: "raise difficulty on #{issue.id}: D2 → D3",
      category: "difficulty misestimate (rework)",
      target: issue.id,
      difficulty: 2,
      repo: "arbiter",
      incident_refs: [issue.id],
      task_refs: [issue.id],
      payload: %{"task_id" => issue.id, "difficulty" => 3},
      diff: "--- a/task\n+++ b/task\n@@ Issue.difficulty @@\n-difficulty: 2\n+difficulty: 3\n"
    }

    {:ok, row} = Loop.record(Map.merge(base, attrs))
    row
  end
end
