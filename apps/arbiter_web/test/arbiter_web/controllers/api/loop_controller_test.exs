defmodule ArbiterWeb.Api.LoopControllerTest do
  # async: false — the pass reads via raw SQL on the sandbox connection and we
  # swap the :output_log_root app env.
  use ArbiterWeb.ConnCase, async: false

  alias Arbiter.Workers.Run
  alias Arbiter.Usage.Event
  alias Arbiter.Worker.OutputLog

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
  end
end
