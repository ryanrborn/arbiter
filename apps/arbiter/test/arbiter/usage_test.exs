defmodule Arbiter.UsageTest do
  # DataCase + async: false — the polecat path under test writes via Ash from
  # a GenServer process under the DynamicSupervisor; that process needs to
  # find the same sandbox connection. The Run-persistence test makes the same
  # call.
  use Arbiter.DataCase, async: false

  alias Arbiter.Polecat
  alias Arbiter.Usage
  alias Arbiter.Usage.Event
  require Ash.Query

  defp create_event!(attrs) do
    base = %{
      bead_id: "bd-usage-#{System.unique_integer([:positive])}",
      rig: "arbiter",
      workspace_id: "ws-usage",
      step: :work,
      occurred_at: DateTime.utc_now()
    }

    {:ok, ev} = Ash.create(Event, Map.merge(base, attrs))
    ev
  end

  describe "Event resource" do
    test "persists the structured usage fields" do
      ev =
        create_event!(%{
          model: "claude-opus-4-7",
          provider: "claude",
          tokens_in: 1234,
          tokens_out: 567,
          cache_creation_tokens: 10,
          cache_read_tokens: 20,
          cost_usd: 0.4321,
          duration_ms: 12_500,
          exit_status: 0,
          session_id: "sess-abc",
          raw: %{"type" => "result", "subtype" => "success"}
        })

      assert ev.model == "claude-opus-4-7"
      assert ev.provider == "claude"
      assert ev.tokens_in == 1234
      assert ev.cost_usd == 0.4321
      assert ev.step == :work
    end

    test "missing cost/tokens are allowed (graceful degradation)" do
      ev = create_event!(%{model: "echo", provider: "other"})
      assert ev.cost_usd == nil
      assert ev.tokens_in == nil
      assert ev.duration_ms == nil
    end

    test "review step is valid" do
      ev = create_event!(%{step: :review, bead_id: "bd-xyz#review"})
      assert ev.step == :review
    end

    test "rejects an unknown step" do
      assert {:error, _} =
               Ash.create(Event, %{
                 bead_id: "bd-bad",
                 rig: "arbiter",
                 step: :sideways,
                 occurred_at: DateTime.utc_now()
               })
    end
  end

  describe "summarize/1" do
    setup do
      day1 = ~U[2026-06-01 12:00:00.000000Z]
      day2 = ~U[2026-06-02 09:00:00.000000Z]

      bead_a = "bd-#{System.unique_integer([:positive])}"
      bead_b = "bd-#{System.unique_integer([:positive])}"

      # Two work sessions on bead_a (rework!) + one review.
      create_event!(%{
        bead_id: bead_a,
        step: :work,
        model: "claude-opus-4-7",
        provider: "claude",
        cost_usd: 1.50,
        tokens_in: 1000,
        tokens_out: 500,
        duration_ms: 600_000,
        occurred_at: day1
      })

      create_event!(%{
        bead_id: bead_a,
        step: :work,
        model: "claude-opus-4-7",
        provider: "claude",
        cost_usd: 1.80,
        tokens_in: 1200,
        tokens_out: 600,
        duration_ms: 720_000,
        occurred_at: day2
      })

      create_event!(%{
        bead_id: bead_a <> "#review",
        step: :review,
        model: "claude-sonnet-4-6",
        provider: "claude",
        cost_usd: 0.40,
        tokens_in: 800,
        tokens_out: 100,
        duration_ms: 90_000,
        occurred_at: day2
      })

      # One unrelated bead in a different workspace.
      create_event!(%{
        bead_id: bead_b,
        workspace_id: "ws-other",
        step: :work,
        model: "claude-opus-4-7",
        provider: "claude",
        cost_usd: 0.25,
        tokens_in: 200,
        tokens_out: 50,
        duration_ms: 30_000,
        occurred_at: day2
      })

      {:ok, %{bead_a: bead_a, bead_b: bead_b, day1: day1, day2: day2}}
    end

    test "by day buckets by occurred_at date in chronological order" do
      {:ok, rollups} = Usage.summarize(by: :day, workspace_id: "ws-usage")

      groups = Enum.map(rollups, & &1.group)
      assert "2026-06-01" in groups
      assert "2026-06-02" in groups
      assert groups == Enum.sort(groups), "by :day should be chronologically sorted"
    end

    test "by bead groups review under the #review id and surfaces rework", %{bead_a: a} do
      {:ok, rollups} = Usage.summarize(by: :bead, workspace_id: "ws-usage")

      a_rollup = Enum.find(rollups, &(&1.group == a))
      assert a_rollup.rows == 2, "two :work rows on the same bead = rework visibility"
      # 1.50 + 1.80 = 3.30
      assert_in_delta a_rollup.total_cost_usd, 3.30, 0.001

      review_rollup = Enum.find(rollups, &(&1.group == a <> "#review"))
      assert review_rollup
      assert_in_delta review_rollup.total_cost_usd, 0.40, 0.001
    end

    test "by step splits work vs review" do
      {:ok, rollups} = Usage.summarize(by: :step, workspace_id: "ws-usage")
      by_step = Map.new(rollups, &{&1.group, &1})

      assert by_step["work"].rows == 2
      assert by_step["review"].rows == 1
      assert_in_delta by_step["work"].total_cost_usd, 3.30, 0.001
      assert_in_delta by_step["review"].total_cost_usd, 0.40, 0.001
    end

    test "by model rolls cross-bead cost up per model" do
      {:ok, rollups} = Usage.summarize(by: :model, workspace_id: "ws-usage")
      by_model = Map.new(rollups, &{&1.group, &1})

      # opus rows: bead_a's two :work rows = 1.50 + 1.80 = 3.30
      assert_in_delta by_model["claude-opus-4-7"].total_cost_usd, 3.30, 0.001
      assert_in_delta by_model["claude-sonnet-4-6"].total_cost_usd, 0.40, 0.001
    end

    test "since filter drops earlier rows", %{day2: day2} do
      {:ok, rollups} = Usage.summarize(by: :bead, workspace_id: "ws-usage", since: day2)
      # Only the day2 rows survive: bead_a's second :work + the review.
      total = Enum.reduce(rollups, 0.0, &(&1.total_cost_usd + &2))
      assert_in_delta total, 1.80 + 0.40, 0.001
    end

    test "workspace_id scopes the query" do
      {:ok, rollups} = Usage.summarize(by: :workspace)
      groups = MapSet.new(Enum.map(rollups, & &1.group))
      assert MapSet.member?(groups, "ws-usage")
      assert MapSet.member?(groups, "ws-other")
    end

    test "limit caps results", %{bead_a: _a} do
      {:ok, [_only_one]} =
        Usage.summarize(by: :bead, workspace_id: "ws-usage", limit: 1)
    end

    test "missing by errors" do
      assert {:error, :missing_grouping} = Usage.summarize([])
    end

    test "invalid by errors" do
      assert {:error, {:invalid_grouping, :nonsense}} = Usage.summarize(by: :nonsense)
    end
  end

  describe "polecat session exit writes a usage row" do
    @fixture Path.expand("../fixtures/echo_with_done.sh", __DIR__)

    setup do
      # Recreate the sanity check from claude_session_test — same fixture.
      unless File.exists?(@fixture) and File.stat!(@fixture).mode |> Bitwise.band(0o100) > 0 do
        flunk("fixture missing or not executable: #{@fixture}")
      end

      :ok
    end

    defp tmp_dir!(tag) do
      dir = Path.join(System.tmp_dir!(), "#{tag}-#{System.unique_integer([:positive])}")
      File.mkdir_p!(dir)
      on_exit(fn -> File.rm_rf(dir) end)
      dir
    end

    defp stream_json_command(dir, events) do
      path = Path.join(dir, "events-#{System.unique_integer([:positive])}.jsonl")
      body = events |> Enum.map_join("\n", &Jason.encode!/1)
      File.write!(path, body <> "\n")
      ["cat", path]
    end

    defp wait_until(fun, timeout_ms \\ 2_000, step_ms \\ 20) do
      deadline = System.monotonic_time(:millisecond) + timeout_ms
      do_wait(fun, deadline, step_ms)
    end

    defp do_wait(fun, deadline, step_ms) do
      case fun.() do
        nil ->
          if System.monotonic_time(:millisecond) >= deadline do
            flunk("wait_until timed out")
          else
            Process.sleep(step_ms)
            do_wait(fun, deadline, step_ms)
          end

        false ->
          if System.monotonic_time(:millisecond) >= deadline do
            flunk("wait_until timed out")
          else
            Process.sleep(step_ms)
            do_wait(fun, deadline, step_ms)
          end

        truthy ->
          truthy
      end
    end

    test "captures tokens + cost + model from stream-json result event" do
      bead_id = "bd-cs-usage-#{System.unique_integer([:positive])}"

      {:ok, pid} =
        Polecat.start(bead_id: bead_id, rig: "arbiter", workspace_id: "ws-usage")

      on_exit(fn -> if Process.alive?(pid), do: GenServer.stop(pid, :normal) end)

      cwd = tmp_dir!("usage-result")

      events = [
        %{
          "type" => "system",
          "subtype" => "init",
          "model" => "claude-opus-4-7",
          "session_id" => "sess-1"
        },
        %{
          "type" => "assistant",
          "message" => %{"content" => [%{"type" => "text", "text" => "doing work"}]}
        },
        %{
          "type" => "result",
          "subtype" => "success",
          "is_error" => false,
          "duration_ms" => 4321,
          "total_cost_usd" => 0.7777,
          "usage" => %{
            "input_tokens" => 1500,
            "output_tokens" => 600,
            "cache_creation_input_tokens" => 50,
            "cache_read_input_tokens" => 100
          },
          "result" => "ok"
        }
      ]

      {:ok, _port} =
        Arbiter.Polecat.ClaudeSession.start(
          owner: pid,
          worktree_path: cwd,
          command: stream_json_command(cwd, events)
        )

      # The polecat persists a usage row on the port :exit_status. Wait for it.
      ev =
        wait_until(fn ->
          case Event
               |> Ash.Query.filter(bead_id == ^bead_id)
               |> Ash.read!() do
            [row] -> row
            _ -> nil
          end
        end)

      assert ev.model == "claude-opus-4-7"
      assert ev.provider == "claude"
      assert ev.tokens_in == 1500
      assert ev.tokens_out == 600
      assert ev.cache_creation_tokens == 50
      assert ev.cache_read_tokens == 100
      assert_in_delta ev.cost_usd, 0.7777, 0.0001
      assert ev.duration_ms == 4321
      assert ev.session_id == "sess-1"
      assert ev.step == :work
      assert ev.workspace_id == "ws-usage"
      assert is_map(ev.raw)
    end

    test "session without a result event still writes a row with nil cost (graceful)" do
      bead_id = "bd-cs-nores-#{System.unique_integer([:positive])}"

      {:ok, pid} =
        Polecat.start(bead_id: bead_id, rig: "arbiter", workspace_id: "ws-usage")

      on_exit(fn -> if Process.alive?(pid), do: GenServer.stop(pid, :normal) end)

      cwd = tmp_dir!("usage-nores")

      # An echo with no JSON — falls through the raw-line path; no usage data.
      command = ["sh", "-c", "echo hello; echo arb done"]

      {:ok, _port} =
        Arbiter.Polecat.ClaudeSession.start(
          owner: pid,
          worktree_path: cwd,
          command: command
        )

      ev =
        wait_until(fn ->
          case Event
               |> Ash.Query.filter(bead_id == ^bead_id)
               |> Ash.read!() do
            [row] -> row
            _ -> nil
          end
        end)

      assert ev.cost_usd == nil
      assert ev.tokens_in == nil
      assert ev.model == nil
      assert ev.step == :work
    end

    test "tribunal reviewer session writes a :review row" do
      reviewer_id = "bd-reviewer-#{System.unique_integer([:positive])}#review"

      {:ok, pid} =
        Polecat.start(
          bead_id: reviewer_id,
          rig: "arbiter",
          workspace_id: nil,
          meta: %{role: :reviewer, reviews: "bd-author"}
        )

      on_exit(fn -> if Process.alive?(pid), do: GenServer.stop(pid, :normal) end)

      cwd = tmp_dir!("usage-review")

      events = [
        %{
          "type" => "system",
          "subtype" => "init",
          "model" => "claude-sonnet-4-6",
          "session_id" => "sess-rev"
        },
        %{
          "type" => "result",
          "subtype" => "success",
          "is_error" => false,
          "duration_ms" => 1500,
          "total_cost_usd" => 0.15,
          "usage" => %{"input_tokens" => 300, "output_tokens" => 80},
          "result" => "VERDICT: APPROVE"
        }
      ]

      {:ok, _port} =
        Arbiter.Polecat.ClaudeSession.start(
          owner: pid,
          worktree_path: cwd,
          command: stream_json_command(cwd, events)
        )

      ev =
        wait_until(fn ->
          case Event
               |> Ash.Query.filter(bead_id == ^reviewer_id)
               |> Ash.read!() do
            [row] -> row
            _ -> nil
          end
        end)

      assert ev.step == :review
      assert ev.model == "claude-sonnet-4-6"
      assert_in_delta ev.cost_usd, 0.15, 0.001
    end
  end
end
