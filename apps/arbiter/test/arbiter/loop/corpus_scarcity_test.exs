defmodule Arbiter.Loop.CorpusScarcityTest do
  @moduledoc """
  #1463 (epic #1011 Amendment E): the corpus must carry each run's draw on the
  binding 5h quota window, not only its imputed dollar cost.
  """
  use Arbiter.DataCase, async: false

  alias Arbiter.Loop.{Corpus, Scarcity}
  alias Arbiter.Quota.AnthropicQuota
  alias Arbiter.Tasks.Workspace
  alias Arbiter.Usage
  alias Arbiter.Workers.Run

  defp workspace!(config \\ %{}) do
    {:ok, ws} =
      Ash.create(Workspace, %{
        name: "scarcity-ws-#{System.unique_integer([:positive])}",
        prefix: "scar",
        config: config
      })

    ws
  end

  defp run!(attrs) do
    {:ok, run} =
      Ash.create(
        Run,
        Map.merge(
          %{
            task_id: "bd-scar-#{System.unique_integer([:positive])}",
            repo: "arbiter",
            status: :completed,
            started_at: DateTime.utc_now()
          },
          attrs
        )
      )

    run
  end

  defp usage!(run, ws, counts) do
    {:ok, ev} =
      Ash.create(
        Usage.Event,
        Map.merge(
          %{
            task_id: run.task_id,
            workspace_id: ws.id,
            step: :other,
            model: "claude-sonnet-5",
            provider: "claude",
            cost_usd: 1.0,
            worker_run_id: run.id,
            occurred_at: DateTime.utc_now()
          },
          counts
        )
      )

    ev
  end

  defp quota!(ws, attrs) do
    {:ok, q} =
      Ash.create(
        AnthropicQuota,
        Map.merge(%{workspace_id: ws.id, provider: "claude", captured_at: DateTime.utc_now()}, attrs)
      )

    q
  end

  describe "fetch/1 — quota-window enrichment" do
    test "each run carries its weighted token draw and its share of one 5h window" do
      ws = workspace!()
      quota!(ws, %{utilization_5h: 0.5, utilization_7d: 0.2})

      since = DateTime.add(DateTime.utc_now(), -3600, :second)
      until = DateTime.add(DateTime.utc_now(), 3600, :second)

      big = run!(%{task_id: "bd-scar-big"})
      small = run!(%{task_id: "bd-scar-small"})

      usage!(big, ws, %{tokens_in: 100_000, tokens_out: 20_000, cache_read_tokens: 500_000})
      usage!(small, ws, %{tokens_in: 10_000, tokens_out: 2_000, cache_read_tokens: 50_000})

      assert {:ok, rows, meta} = Corpus.fetch(since: since, until: until, workspace_id: ws.id)

      by_task = Map.new(rows, &{&1.task_id, &1})
      big_row = by_task["bd-scar-big"]
      small_row = by_task["bd-scar-small"]

      assert big_row.weighted_tokens ==
               Scarcity.weighted_tokens(%{
                 tokens_in: 100_000,
                 tokens_out: 20_000,
                 cache_read_tokens: 500_000
               })

      assert_in_delta big_row.weighted_tokens, 10 * small_row.weighted_tokens, 0.001

      assert meta.scarcity.calibration.status == :calibrated
      assert meta.scarcity.unit == :window_share_5h
      assert meta.scarcity.billing_mode == {:subscription, :inferred}

      assert is_float(big_row.window_share_5h)
      assert big_row.window_share_5h > small_row.window_share_5h

      # Capacity is calibrated off the same trailing window these two runs are
      # in, so together they account for the observed 50% utilization.
      assert_in_delta big_row.window_share_5h + small_row.window_share_5h, 0.5, 0.001
    end

    test "no quota snapshot leaves window share nil and says why, rather than reporting zero draw" do
      ws = workspace!()
      since = DateTime.add(DateTime.utc_now(), -3600, :second)
      until = DateTime.add(DateTime.utc_now(), 3600, :second)

      run = run!(%{task_id: "bd-scar-blind"})
      usage!(run, ws, %{tokens_in: 100_000, tokens_out: 20_000})

      assert {:ok, [row], meta} = Corpus.fetch(since: since, until: until, workspace_id: ws.id)

      assert row.weighted_tokens > 0.0
      assert row.window_share_5h == nil
      assert meta.scarcity.calibration.status == :uncalibrated
      assert meta.scarcity.calibration.reason == :no_snapshot
      assert meta.scarcity.unit == :cost_usd
      assert meta.scarcity.billing_mode == {:metered, :default}
    end

    test "workspace config can declare metered billing, keeping dollars primary" do
      ws = workspace!(%{"loop" => %{"billing_mode" => "metered"}})
      quota!(ws, %{utilization_5h: 0.5})

      since = DateTime.add(DateTime.utc_now(), -3600, :second)
      until = DateTime.add(DateTime.utc_now(), 3600, :second)

      run = run!(%{task_id: "bd-scar-metered"})
      usage!(run, ws, %{tokens_in: 100_000, tokens_out: 20_000})

      assert {:ok, [row], meta} = Corpus.fetch(since: since, until: until, workspace_id: ws.id)

      assert meta.scarcity.billing_mode == {:metered, :configured}
      assert meta.scarcity.unit == :cost_usd
      # The secondary unit is retained, not dropped.
      assert is_float(row.window_share_5h)
      assert row.cost_usd > 0.0
    end
  end

  describe "record_pass_cost/1 — the analyser's own draw" do
    test "the deterministic pass records an explicit zero-token quota draw" do
      ws = workspace!()
      id = Corpus.record_pass_cost(%{workspace_id: ws.id, rows_scanned: 3, duration_ms: 12})

      assert is_binary(id)
      {:ok, ev} = Ash.get(Usage.Event, id)

      assert ev.tokens_in == 0
      assert ev.tokens_out == 0
      assert Scarcity.weighted_tokens(ev) == 0.0
      assert ev.raw["quota_window_draw"] == "none"
    end
  end
end
