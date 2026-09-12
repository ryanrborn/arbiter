defmodule Arbiter.Usage.SourceTest do
  @moduledoc """
  bd-adyhvn: `usage_events.task_id` is nullable and every row carries a
  `source` discriminator, so spend that belongs to no task (quota probes,
  auth pre-flights, coordinator/terminal sessions) is recordable and
  groupable without polluting the task-shaped rollups.
  """
  use Arbiter.DataCase, async: false

  alias Arbiter.Usage
  alias Arbiter.Usage.Event

  defp create_event!(attrs) do
    base = %{
      workspace_id: "ws-source",
      step: :work,
      occurred_at: DateTime.utc_now()
    }

    {:ok, ev} = Ash.create(Event, Map.merge(base, attrs))
    ev
  end

  describe "the source discriminator" do
    test "defaults to :task so every existing writer keeps its meaning" do
      ev = create_event!(%{task_id: "bd-source-1"})
      assert ev.source == :task
    end

    test "enumerates every caller the ledger has to serve" do
      assert Enum.sort(Event.sources()) ==
               Enum.sort([
                 :task,
                 :probe,
                 :preflight,
                 :coordinator_session,
                 :terminal_session,
                 :maintenance
               ])
    end

    test "a probe row persists with a nil task_id and real token counts" do
      ev =
        create_event!(%{
          task_id: nil,
          source: :probe,
          provider: "claude",
          tokens_in: 4,
          tokens_out: 7,
          cache_creation_tokens: 11,
          cache_read_tokens: 57_062,
          cost_usd: 0.018
        })

      assert ev.task_id == nil
      assert ev.source == :probe
      assert ev.cache_read_tokens == 57_062
    end

    test "a coordinator session attributes by session_id alone (bd-cyxzvq)" do
      ev =
        create_event!(%{
          task_id: nil,
          source: :coordinator_session,
          session_id: "sess-coord-1",
          tokens_in: 100
        })

      assert ev.task_id == nil
      assert ev.session_id == "sess-coord-1"
      assert ev.source == :coordinator_session
    end

    test "rejects a source outside the enumerated set" do
      assert {:error, _} =
               Ash.create(Event, %{
                 task_id: nil,
                 source: :nonsense,
                 step: :work,
                 occurred_at: DateTime.utc_now()
               })
    end
  end

  describe "summarize/1 --by source" do
    test "rolls task-less spend up under its own group" do
      create_event!(%{task_id: "bd-source-a", cost_usd: 1.0, tokens_in: 10})
      create_event!(%{task_id: nil, source: :probe, cost_usd: 0.02, tokens_in: 5})
      create_event!(%{task_id: nil, source: :probe, cost_usd: 0.02, tokens_in: 5})
      create_event!(%{task_id: nil, source: :preflight, cost_usd: 0.01, tokens_in: 3})

      assert :source in Usage.valid_groupings()
      {:ok, rollups} = Usage.summarize(by: :source, workspace_id: "ws-source")

      by_group = Map.new(rollups, &{&1.group, &1})
      assert by_group["probe"].rows == 2
      assert_in_delta by_group["probe"].total_cost_usd, 0.04, 0.0001
      assert by_group["preflight"].rows == 1
      assert by_group["task"].rows == 1
    end
  end

  describe "summarize/1 --by task with task-less rows present" do
    test "excludes probe/preflight rows instead of inventing a phantom task" do
      create_event!(%{task_id: "bd-source-real", cost_usd: 1.0})
      create_event!(%{task_id: nil, source: :probe, cost_usd: 0.02})
      create_event!(%{task_id: nil, source: :preflight, cost_usd: 0.01})

      {:ok, rollups} = Usage.summarize(by: :task, workspace_id: "ws-source")
      groups = Enum.map(rollups, & &1.group)

      assert groups == ["bd-source-real"]
      refute nil in groups
      refute "probe" in groups
      refute "loop-analyze" in groups
    end

    test "--by day still counts task-less spend (nothing is lost)" do
      create_event!(%{task_id: "bd-source-day", cost_usd: 1.0})
      create_event!(%{task_id: nil, source: :probe, cost_usd: 0.02})

      {:ok, rollups} = Usage.summarize(by: :day, workspace_id: "ws-source")
      total = Enum.reduce(rollups, 0.0, &(&2 + &1.total_cost_usd))
      assert_in_delta total, 1.02, 0.0001
    end

    test "--by epic tolerates a nil task_id" do
      create_event!(%{task_id: nil, source: :probe, cost_usd: 0.02})

      {:ok, rollups} = Usage.summarize(by: :epic, workspace_id: "ws-source")
      assert Enum.any?(rollups, &(&1.group == "(no_epic)"))
    end
  end
end
