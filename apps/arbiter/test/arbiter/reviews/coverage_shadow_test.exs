defmodule Arbiter.Reviews.CoverageShadowTest do
  @moduledoc """
  P3 of `docs/review-coverage-and-guard-policy.md` (design #1635), §3.4/§6.3:
  the **shadow** evaluator both merge paths call alongside the existing
  `last_reviewed_sha` guard.

  Everything here is about the two properties P3 has to hold:

    * `observe/1` never changes and never crashes the merge decision — it
      returns `:ok` for *every* input, including ones whose `ctx` lookups
      raise; and
    * a disagreement is legible without grepping a journal — exactly one
      `:warning` line naming both answers, plus a durable counter row.
  """
  use Arbiter.DataCase, async: false

  import ExUnit.CaptureLog

  require Ash.Query

  alias Arbiter.Events
  alias Arbiter.Mergers.NetDiff
  alias Arbiter.Reviews.Coverage
  alias Arbiter.Reviews.CoverageShadow
  alias Arbiter.Reviews.CoverageShadow.Tally

  @diff_a """
  diff --git a/lib/a.ex b/lib/a.ex
  index 1111111..2222222 100644
  --- a/lib/a.ex
  +++ b/lib/a.ex
  @@ -1,3 +1,4 @@
   defmodule A do
  +  def hello, do: :world
   end
  """

  # The same net contribution after a base merge: new blob hashes, shifted
  # hunk header, identical content. §4.2's `M` — the rule-3 case.
  @diff_a_after_base_merge """
  diff --git a/lib/a.ex b/lib/a.ex
  index 3333333..4444444 100644
  --- a/lib/a.ex
  +++ b/lib/a.ex
  @@ -41,3 +41,4 @@ defmodule A do
   defmodule A do
  +  def hello, do: :world
   end
  """

  @diff_b """
  diff --git a/lib/a.ex b/lib/a.ex
  index 1111111..5555555 100644
  --- a/lib/a.ex
  +++ b/lib/a.ex
  @@ -1,3 +1,4 @@
   defmodule A do
  +  def hello, do: :universe
   end
  """

  @fp_a NetDiff.fingerprint(@diff_a)

  # The tally is a singleton owned by the application supervisor, so each test
  # zeroes it rather than starting its own. Safe because this file is `async:
  # false`: ExUnit runs every async test before any sync one, so nothing else
  # is touching the table while these run.
  setup do
    Tally.reset()
    on_exit(&Tally.reset/0)
    :ok
  end

  defp sha(seed), do: Base.encode16(:crypto.hash(:sha, seed), case: :lower)

  defp workspace_id, do: Ecto.UUID.generate()

  defp record_reviewed(mr_ref, head_sha) do
    {:ok, entry} =
      Coverage.record(%{
        task_id: "bd-b0fqcl",
        mr_ref: mr_ref,
        head_sha: head_sha,
        base_ref: "main",
        net_diff_id: @fp_a,
        kind: :reviewed,
        source: :review_gate
      })

    entry
  end

  defp observe(overrides) do
    CoverageShadow.observe(
      Map.merge(
        %{
          site: :watchdog,
          task_id: "bd-b0fqcl",
          mr_ref: "ryanrborn/arbiter#1649",
          workspace_id: workspace_id(),
          head: sha("a"),
          old: {:covered, sha("a")},
          ctx: %{base_ref: "main", fetch_diff: fn _base, _head -> {:ok, @diff_b} end}
        },
        Map.new(overrides)
      )
    )
  end

  defp shadow_events do
    Arbiter.Events.Record
    |> Ash.Query.filter(topic == "coverage_shadow")
    |> Ash.read!()
  end

  describe "agreement" do
    test "an exact-match head agrees, counts, and logs nothing" do
      mr_ref = "ryanrborn/arbiter#1649"
      record_reviewed(mr_ref, sha("a"))

      log =
        capture_log(fn ->
          assert :ok == observe(%{mr_ref: mr_ref, head: sha("a"), old: {:covered, sha("a")}})
        end)

      refute log =~ "DISAGREEMENT"

      assert %{evaluations: 1, agreements: 1, disagreements: 0, errors: 0} = Tally.snapshot()
    end
  end

  describe "disagreement" do
    test "logs exactly one warning naming both answers and the reason" do
      mr_ref = "ryanrborn/arbiter#1649"
      record_reviewed(mr_ref, sha("a"))

      log =
        capture_log(fn ->
          assert :ok ==
                   observe(%{
                     mr_ref: mr_ref,
                     head: sha("z"),
                     old: {:covered, sha("z")}
                   })
        end)

      lines = for line <- String.split(log, "\n"), line =~ "DISAGREEMENT", do: line
      assert length(lines) == 1

      [line] = lines
      assert line =~ "[warning]"
      assert line =~ "site=watchdog"
      assert line =~ "task=bd-b0fqcl"
      assert line =~ "mr=" <> mr_ref
      assert line =~ "head=" <> sha("z")
      assert line =~ "old=covered"
      assert line =~ "new=uncovered"
      assert line =~ "new_reason=authored_content"
    end

    test "increments the durable disagreement counter" do
      mr_ref = "ryanrborn/arbiter#1649"
      record_reviewed(mr_ref, sha("a"))

      assert CoverageShadow.disagreement_count() == 0

      capture_log(fn ->
        observe(%{mr_ref: mr_ref, head: sha("z"), old: {:covered, sha("z")}})
      end)

      assert CoverageShadow.disagreement_count() == 1
      assert %{disagreements: 1, agreements: 0} = Tally.snapshot()

      assert [event] = shadow_events()
      assert event.payload["result"] == "disagree"
      assert event.payload["old"] == "covered"
      assert event.payload["new"] == "uncovered"
      assert event.payload["new_reason"] == "authored_content"
      assert event.payload["site"] == "watchdog"
    end

    test "the documented SQL readout groups the durable rows by result" do
      # The query the design doc's §6.3 tells a coordinator to run after a
      # restart. Asserted here so a payload shape change cannot quietly break
      # the one readout the post-merge verification depends on.
      mr_ref = "ryanrborn/arbiter#1649"
      record_reviewed(mr_ref, sha("a"))

      capture_log(fn ->
        observe(%{mr_ref: mr_ref, head: sha("a"), old: {:covered, sha("a")}})
        observe(%{mr_ref: mr_ref, head: sha("z"), old: {:covered, sha("z")}})
      end)

      %{rows: rows} =
        Arbiter.Repo.query!("""
        select json_extract(payload, '$.result') as result, count(*)
          from events where topic = 'coverage_shadow' group by result
        """)

      assert Enum.sort(rows) == [["agree", 1], ["disagree", 1]]
    end

    test "a re-poll of the same head does not re-log or double-count the same disagreement" do
      mr_ref = "ryanrborn/arbiter#1649"
      record_reviewed(mr_ref, sha("a"))

      args = %{mr_ref: mr_ref, head: sha("z"), old: {:covered, sha("z")}}

      log = capture_log(fn -> Enum.each(1..3, fn _ -> observe(args) end) end)

      assert length(for line <- String.split(log, "\n"), line =~ "DISAGREEMENT", do: line) == 1
      assert CoverageShadow.disagreement_count() == 1
      assert %{evaluations: 3} = Tally.snapshot()
    end
  end

  describe "the shadow never changes or crashes the merge decision" do
    test "a ctx lookup that raises is rescued, logged and counted" do
      log =
        capture_log(fn ->
          assert :ok ==
                   observe(%{
                     ctx: fn -> raise "forge exploded" end,
                     old: {:covered, sha("a")}
                   })
        end)

      assert log =~ "Reviews.CoverageShadow"
      assert log =~ "[warning]"
      assert log =~ "forge exploded"
      refute log =~ "DISAGREEMENT"

      assert %{errors: 1, disagreements: 0, agreements: 0} = Tally.snapshot()
    end

    test "a decide/3 that raises is rescued and counted" do
      log =
        capture_log(fn ->
          assert :ok ==
                   observe(%{
                     # `decide_with_record/3` reads `.head_sha` off every entry.
                     coverage: [%{not: :an_entry}],
                     old: {:covered, sha("a")}
                   })
        end)

      assert log =~ "Reviews.CoverageShadow"
      assert %{errors: 1} = Tally.snapshot()
    end

    test "returns :ok for structurally invalid input rather than raising" do
      assert :ok == CoverageShadow.observe(%{})
      assert :ok == CoverageShadow.observe(%{site: :watchdog, old: :nonsense})
      assert :ok == CoverageShadow.observe(:not_even_a_map)
    end

    test "the tally itself never raises when its table is missing" do
      # `terminate_child/2` rather than `GenServer.stop/1`: stopping a
      # permanent supervised child makes the supervisor restart it right back,
      # so the table would never actually be gone.
      :ok = Supervisor.terminate_child(Arbiter.Supervisor, Tally)
      on_exit(fn -> Supervisor.restart_child(Arbiter.Supervisor, Tally) end)

      assert :ok == observe(%{old: {:covered, sha("a")}})
      assert Tally.snapshot() == Tally.empty_snapshot()

      {:ok, _pid} = Supervisor.restart_child(Arbiter.Supervisor, Tally)
    end
  end

  describe "rule-3 :mechanical rows in shadow mode" do
    setup do
      mr_ref = "ryanrborn/arbiter#1649"
      record_reviewed(mr_ref, sha("a"))

      args = %{
        mr_ref: mr_ref,
        head: sha("m"),
        old: {:uncovered, :stale_reviewed_sha},
        ctx: %{
          base_ref: "main",
          fetch_diff: fn _base, _head -> {:ok, @diff_a_after_base_merge} end
        }
      }

      {:ok, mr_ref: mr_ref, args: args}
    end

    test "are NOT written by default", %{mr_ref: mr_ref, args: args} do
      capture_log(fn -> assert :ok == observe(args) end)

      assert Coverage.for_mr(mr_ref) |> Enum.map(& &1.kind) == [:reviewed]
    end

    test "are written when the flag is on", %{mr_ref: mr_ref, args: args} do
      previous = Application.get_env(:arbiter, :coverage_shadow_record_mechanical)
      Application.put_env(:arbiter, :coverage_shadow_record_mechanical, true)

      on_exit(fn ->
        if is_nil(previous) do
          Application.delete_env(:arbiter, :coverage_shadow_record_mechanical)
        else
          Application.put_env(:arbiter, :coverage_shadow_record_mechanical, previous)
        end
      end)

      capture_log(fn -> assert :ok == observe(args) end)

      kinds = mr_ref |> Coverage.for_mr() |> Enum.map(& &1.kind) |> Enum.sort()
      assert kinds == [:mechanical, :reviewed]
    end
  end

  describe "the event topic" do
    test "is a subscribable topic, so the counter is API-readable" do
      assert "coverage_shadow" in Events.valid_topics()
    end
  end
end
