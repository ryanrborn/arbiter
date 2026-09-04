defmodule Arbiter.Loop.ProposalsTest do
  # The report → candidate mapping (pure) and the `propose?:` opt-in on the pass
  # (which must leave the default path byte-identical to Stage 1).
  use Arbiter.DataCase, async: false

  alias Arbiter.Loop
  alias Arbiter.Loop.{Analysis, PendingWrite, Proposals, Report}
  alias Arbiter.ReviewGate.Round
  alias Arbiter.Tasks.{Issue, Workspace}
  alias Arbiter.Usage.Event
  alias Arbiter.Workers.Run

  defp report(attrs), do: struct(Report, attrs)

  defp finding_category(attrs \\ %{}) do
    Map.merge(
      %{
        category: "plausible code, green tests, inert at runtime",
        count: 3,
        run_ids: ["run-1", "run-2", "run-3"],
        tasks: ["bd-aaa", "bd-bbb"],
        example: "the new code path is never executed"
      },
      attrs
    )
  end

  describe "candidates/2 (pure)" do
    test "every finding category becomes a fleet-scoped skill_patch, below-bar ones included" do
      r =
        report(%{
          finding_categories: [
            finding_category(),
            finding_category(%{category: "thin test", count: 1, run_ids: ["r9"], tasks: ["bd-z"]})
          ],
          suggestions: [
            %{
              title: "plausible code, green tests, inert at runtime",
              target_metric: "rework rate",
              baseline: "42.0%",
              destination: :skill,
              verdict: :fleet_wide
            }
          ]
        })

      candidates = Proposals.candidates(r)

      assert length(candidates) == 2
      assert Enum.all?(candidates, &(&1.kind == :skill_patch and &1.scope == :fleet))

      inert = Enum.find(candidates, &(&1.category =~ "inert at runtime"))
      assert inert.incident_refs == ["run-1", "run-2", "run-3"]
      assert inert.task_refs == ["bd-aaa", "bd-bbb"]
      # The metric and its baseline are pre-registered at propose time, for the
      # later re-grading pass to measure against.
      assert inert.target_metric == "rework rate"
      assert inert.baseline == "42.0%"

      # Stage 3 gap: no target skill is named, so nothing here claims to know
      # which skill the patch belongs in.
      refute Map.has_key?(inert.payload, "skill")

      thin = Enum.find(candidates, &(&1.category == "thin test"))
      assert thin, "a below-bar category is still a candidate — that is the point of Stage 2"
      assert thin.incident_refs == ["r9"]
    end

    test "a rework misestimate becomes a task-scoped difficulty_override with a diff" do
      r =
        report(%{
          difficulty_misestimates: [
            %{
              task_id: "bd-7rspia",
              dispatched_difficulty: 1,
              rounds: 2,
              cost_usd: 10.62,
              reason: :rework,
              cell: {1, "arbiter"},
              recommendation: %{target_metric: "rework rate", baseline: "50.0%"}
            }
          ]
        })

      candidates = Proposals.candidates(r)

      candidate = Enum.find(candidates, &(&1.kind == :difficulty_override))

      assert candidate.scope == :task
      assert candidate.target == "bd-7rspia"
      assert candidate.difficulty == 1
      assert candidate.repo == "arbiter"
      assert candidate.payload["task_id"] == "bd-7rspia"
      assert candidate.payload["difficulty"] == 2
      assert candidate.gist =~ "D1 → D2"
      assert candidate.diff =~ "-difficulty: 1"
      assert candidate.diff =~ "+difficulty: 2"

      # A lone occurrence in its cell still gets a fleet-scoped cluster
      # candidate (bd-70nblx) — it just won't clear the evidence bar on its
      # own, same as a below-bar reviewer-finding category.
      cluster = Enum.find(candidates, &(&1.kind == :config_set))
      assert cluster.scope == :fleet
      assert cluster.difficulty == 1
      assert cluster.repo == "arbiter"
      assert cluster.task_refs == ["bd-7rspia"]
    end

    test "misestimates sharing a (from, to, repo) cell aggregate into one fleet-wide cluster candidate" do
      r =
        report(%{
          difficulty_misestimates: [
            %{
              task_id: "bd-2fzwlc",
              dispatched_difficulty: 2,
              rounds: 3,
              cost_usd: 22.86,
              reason: :rework,
              cell: {2, "arbiter"},
              recommendation: %{}
            },
            %{
              task_id: "bd-4ku4ze",
              dispatched_difficulty: 2,
              rounds: 2,
              cost_usd: 7.24,
              reason: :rework,
              cell: {2, "arbiter"},
              recommendation: %{}
            },
            %{
              task_id: "bd-61hnbb",
              dispatched_difficulty: 2,
              rounds: 2,
              cost_usd: 13.84,
              reason: :rework,
              cell: {2, "arbiter"},
              recommendation: %{}
            }
          ]
        })

      candidates = Proposals.candidates(r)

      overrides = Enum.filter(candidates, &(&1.kind == :difficulty_override))
      assert length(overrides) == 3

      clusters = Enum.filter(candidates, &(&1.kind == :config_set))
      assert [cluster] = clusters
      assert cluster.scope == :fleet
      assert cluster.difficulty == 2
      assert cluster.repo == "arbiter"

      assert Enum.sort(cluster.task_refs) == ["bd-2fzwlc", "bd-4ku4ze", "bd-61hnbb"]
      assert Enum.sort(cluster.incident_refs) == ["bd-2fzwlc", "bd-4ku4ze", "bd-61hnbb"]
      assert cluster.gist =~ "D2"
      assert cluster.gist =~ "workspace-wide"

      # No workspace_config passed, so the patch renders D2 the way the
      # stock default_mapping routes D3 (the tier above).
      assert cluster.payload["patch"] == %{
               "routing" => %{
                 "rules" => %{"D2" => %{"model_tier" => "premium", "thinking" => "high"}}
               }
             }
    end

    test "the patch routes the under-provisioned tier the way the workspace already routes the tier above it" do
      r =
        report(%{
          difficulty_misestimates: [
            %{
              task_id: "bd-override",
              dispatched_difficulty: 2,
              rounds: 3,
              cost_usd: 10.0,
              reason: :rework,
              cell: {2, "arbiter"},
              recommendation: %{}
            }
          ]
        })

      workspace_config = %{
        "routing" => %{"rules" => %{"D3" => %{"model_tier" => "flagship", "thinking" => "xhigh"}}}
      }

      [cluster] =
        Proposals.candidates(r, workspace_config: workspace_config)
        |> Enum.filter(&(&1.kind == :config_set))

      assert cluster.payload["patch"] == %{
               "routing" => %{
                 "rules" => %{"D2" => %{"model_tier" => "flagship", "thinking" => "xhigh"}}
               }
             }
    end

    test "an identity-rendering cell (from and to already route the same way) produces no cluster candidate" do
      # Stock default_mapping routes D3 and D4 both premium/high, so a D3 -> D4
      # cluster with no D4 override would render a no-op patch — a row that
      # fails Ash validation on every `arb loop apply all`, forever.
      r =
        report(%{
          difficulty_misestimates: [
            %{
              task_id: "bd-identity",
              dispatched_difficulty: 3,
              rounds: 2,
              cost_usd: 10.0,
              reason: :rework,
              cell: {3, "arbiter"},
              recommendation: %{}
            }
          ]
        })

      candidates = Proposals.candidates(r)

      assert Enum.any?(candidates, &(&1.kind == :difficulty_override))
      refute Enum.any?(candidates, &(&1.kind == :config_set))
    end

    test "misestimates in different cells produce separate cluster candidates" do
      r =
        report(%{
          difficulty_misestimates: [
            %{
              task_id: "bd-a",
              dispatched_difficulty: 1,
              rounds: 2,
              cost_usd: 5.0,
              reason: :rework,
              cell: {1, "arbiter"},
              recommendation: %{}
            },
            %{
              task_id: "bd-b",
              dispatched_difficulty: 2,
              rounds: 2,
              cost_usd: 5.0,
              reason: :rework,
              cell: {2, "arbiter"},
              recommendation: %{}
            },
            %{
              task_id: "bd-c",
              dispatched_difficulty: 1,
              rounds: 2,
              cost_usd: 5.0,
              reason: :rework,
              cell: {1, "other-repo"},
              recommendation: %{}
            }
          ]
        })

      clusters = Proposals.candidates(r) |> Enum.filter(&(&1.kind == :config_set))

      assert length(clusters) == 3
      cells = Enum.map(clusters, &{&1.difficulty, &1.repo})
      assert Enum.sort(cells) == [{1, "arbiter"}, {1, "other-repo"}, {2, "arbiter"}]
    end

    test "a misestimate on a task already at the difficulty ceiling is not a candidate" do
      # `Issue.difficulty` is constrained to 0..4, so a D4 → D5 override could
      # never apply — and being :task-scoped it would bypass the bar and land
      # directly as :proposed, sticking in the queue forever.
      r =
        report(%{
          difficulty_misestimates: [
            %{
              task_id: "bd-ceiling",
              dispatched_difficulty: 4,
              rounds: 3,
              cost_usd: 31.0,
              reason: :rework,
              cell: {4, "arbiter"},
              recommendation: %{}
            }
          ]
        })

      assert Proposals.candidates(r) == []
    end

    test "a quality_failure misestimate is deliberately not a candidate" do
      r =
        report(%{
          difficulty_misestimates: [
            %{
              task_id: "bd-cost",
              dispatched_difficulty: 3,
              rounds: 1,
              cost_usd: 22.0,
              reason: :quality_failure,
              cell: {3, "arbiter"}
            }
          ]
        })

      assert Proposals.candidates(r) == []
    end

    test "candidates carry the workspace and origin they were built with" do
      r = report(%{finding_categories: [finding_category()]})

      assert [c] = Proposals.candidates(r, workspace_id: "ws-1", origin: "loop.manual")
      assert c.workspace_id == "ws-1"
      assert c.origin == "loop.manual"
    end

    test "auto-generated candidates never produce :repo_doc_patch (the :claude_md destination path does not exist)" do
      # :repo_doc_patch is authored only by operators via `arb loop propose repo-doc-patch`,
      # not auto-generated by Analysis.suggestion_targets/2 which only produces :skill or :per_task_override.
      r =
        report(%{
          finding_categories: [finding_category()],
          difficulty_misestimates: [
            %{
              task_id: "bd-test",
              dispatched_difficulty: 1,
              rounds: 2,
              cost_usd: 5.0,
              reason: :rework,
              cell: {1, "arbiter"},
              recommendation: %{}
            }
          ]
        })

      candidates = Proposals.candidates(r)

      refute Enum.any?(candidates, &(&1.kind == :repo_doc_patch)),
             "auto-generated candidates must not include :repo_doc_patch"
    end

    test "candidates/2 writes nothing" do
      r = report(%{finding_categories: [finding_category()]})

      _ = Proposals.candidates(r)

      assert Ash.read!(PendingWrite) == []
    end
  end

  describe "the propose? opt-in on the pass" do
    setup do
      {:ok, ws} = Ash.create(Workspace, %{name: "propose-ws", prefix: "prop"})

      {:ok, issue} =
        Ash.create(Issue, %{title: "inert task", difficulty: 1, workspace_id: ws.id})

      {:ok, run} =
        Ash.create(Run, %{
          task_id: issue.id,
          repo: "arbiter",
          worker_type: :main,
          status: :failed,
          model: "claude-haiku-4-5",
          failure_reason: ":review_gate_rejected",
          started_at: DateTime.utc_now()
        })

      {:ok, _} =
        Ash.create(Event, %{
          task_id: issue.id,
          step: :work,
          worker_run_id: run.id,
          cost_usd: 4.44,
          occurred_at: DateTime.utc_now()
        })

      {:ok, _} =
        Ash.create(Round, %{
          task_id: issue.id,
          run_id: run.id,
          round: 2,
          role: :review,
          verdict: :request_changes,
          converged: false,
          findings: "Tests are green but the new code path is never executed at runtime — inert."
        })

      %{ws: ws, issue: issue}
    end

    defp analyze!(opts) do
      base = [
        label: "propose window",
        since: DateTime.add(DateTime.utc_now(), -24 * 3600, :second),
        until: DateTime.add(DateTime.utc_now(), 120, :second)
      ]

      {:ok, envelope} = Analysis.analyze(Keyword.merge(base, opts))
      envelope
    end

    test "without propose? the envelope has no :proposals key and the queue stays empty" do
      envelope = analyze!([])

      refute Map.has_key?(envelope, :proposals)
      assert Ash.read!(PendingWrite) == []
    end

    test "with propose? rows are inserted and nothing else is written", %{issue: issue} do
      issues_before = Issue |> Ash.read!() |> length()
      runs_before = Run |> Ash.read!() |> length()
      rounds_before = Round |> Ash.read!() |> length()
      events_before = Event |> Ash.read!() |> length()

      envelope = analyze!(propose?: true)

      assert is_list(envelope.proposals)
      assert envelope.proposals != []

      rows = Ash.read!(PendingWrite)
      assert length(rows) == length(envelope.proposals)

      # The queue is the only thing that grew, bar the pass's own cost row.
      assert Issue |> Ash.read!() |> length() == issues_before
      assert Run |> Ash.read!() |> length() == runs_before
      assert Round |> Ash.read!() |> length() == rounds_before
      assert Event |> Ash.read!() |> length() == events_before + 1

      # The task-scoped difficulty bump bypasses the bar; the fleet-wide finding
      # (1 incident) does not.
      override = Enum.find(rows, &(&1.kind == :difficulty_override))
      assert override.scope == :task
      assert override.state == :proposed
      assert override.target == issue.id

      patch = Enum.find(rows, &(&1.kind == :skill_patch))
      assert patch.scope == :fleet
      assert patch.state == :hypothesis
      refute Loop.applicable?(patch)
    end

    test "two consecutive propose runs over the same window produce no duplicate rows" do
      first = analyze!(propose?: true)
      after_first = Ash.read!(PendingWrite)

      second = analyze!(propose?: true)
      after_second = Ash.read!(PendingWrite)

      assert length(after_second) == length(after_first)

      assert Enum.map(first.proposals, & &1.id) |> Enum.sort() ==
               Enum.map(second.proposals, & &1.id) |> Enum.sort()

      # Reinforcement unions the refs, so re-running the same window does not
      # inflate the evidence either.
      by_id = Map.new(after_first, &{&1.id, &1})

      for row <- after_second do
        before = Map.fetch!(by_id, row.id)
        assert row.evidence_count == before.evidence_count
        assert row.distinct_tasks == before.distinct_tasks
      end
    end
  end

  describe "record_all/2 — cross-task difficulty-misestimate cluster escalation (bd-70nblx)" do
    # Regression fixture: the 2026-08-10 `arb loop analyze --since 7d --propose`
    # window that surfaced this gap. Three distinct tasks, all D2 → D3 in the
    # (2, arbiter) cell — clears the same evidence bar the pass already
    # applies to reviewer-finding categories, so it must produce a fleet-wide
    # proposal alongside (not instead of) the three per-task overrides.

    # The `:config_set` cluster candidate is `:fleet`-scoped and carries no
    # `workspace_id` of its own (bd-3dasqm), so it resolves to the
    # installation's default workspace on insert — an install needs at least
    # one workspace to exist for that resolution to succeed.
    setup do
      {:ok, ws} = Ash.create(Workspace, %{name: "cluster-ws", prefix: "clus"})
      %{ws: ws}
    end

    defp misestimate_2026_08_10_fixture do
      [
        %{
          task_id: "bd-2fzwlc",
          dispatched_difficulty: 2,
          rounds: 3,
          cost_usd: 22.86,
          reason: :rework,
          cell: {2, "arbiter"},
          recommendation: %{}
        },
        %{
          task_id: "bd-4ku4ze",
          dispatched_difficulty: 2,
          rounds: 2,
          cost_usd: 7.24,
          reason: :rework,
          cell: {2, "arbiter"},
          recommendation: %{}
        },
        %{
          task_id: "bd-61hnbb",
          dispatched_difficulty: 2,
          rounds: 2,
          cost_usd: 13.84,
          reason: :rework,
          cell: {2, "arbiter"},
          recommendation: %{}
        }
      ]
    end

    test "a re-run over the fixture window produces one fleet-wide proposal, not three isolated rows only" do
      r = report(%{difficulty_misestimates: misestimate_2026_08_10_fixture()})

      %{rows: rows, dropped: []} = Proposals.record_all(r)

      overrides = Enum.filter(rows, &(&1.kind == :difficulty_override))
      assert length(overrides) == 3
      assert Enum.all?(overrides, &(&1.state == :proposed and &1.scope == :task))

      clusters = Enum.filter(rows, &(&1.kind == :config_set))
      assert [cluster] = clusters
      assert cluster.scope == :fleet
      assert cluster.state == :proposed
      assert cluster.evidence_count == 3
      assert cluster.distinct_tasks == 3
      assert Loop.applicable?(cluster)
    end

    test "the cluster accumulates across windows and only escalates once the bar clears" do
      [first, second, third] = misestimate_2026_08_10_fixture()

      {:ok, after_first} =
        Loop.record(
          hd(
            Proposals.candidates(report(%{difficulty_misestimates: [first]}))
            |> Enum.filter(&(&1.kind == :config_set))
          )
        )

      assert after_first.state == :hypothesis
      refute Loop.applicable?(after_first)

      {:ok, after_second} =
        Loop.record(
          hd(
            Proposals.candidates(report(%{difficulty_misestimates: [second]}))
            |> Enum.filter(&(&1.kind == :config_set))
          )
        )

      assert after_second.id == after_first.id
      assert after_second.state == :hypothesis
      assert after_second.distinct_tasks == 2

      {:ok, after_third} =
        Loop.record(
          hd(
            Proposals.candidates(report(%{difficulty_misestimates: [third]}))
            |> Enum.filter(&(&1.kind == :config_set))
          )
        )

      assert after_third.id == after_first.id
      assert after_third.state == :proposed
      assert after_third.distinct_tasks == 3
      assert Loop.applicable?(after_third)
    end

    test "isolated (n=1) misestimates in distinct cells never escalate a cluster" do
      r =
        report(%{
          difficulty_misestimates: [
            %{
              task_id: "bd-solo-1",
              dispatched_difficulty: 1,
              rounds: 2,
              cost_usd: 4.0,
              reason: :rework,
              cell: {1, "arbiter"},
              recommendation: %{}
            },
            %{
              task_id: "bd-solo-2",
              dispatched_difficulty: 2,
              rounds: 2,
              cost_usd: 4.0,
              reason: :rework,
              cell: {2, "other-repo"},
              recommendation: %{}
            }
          ]
        })

      %{rows: rows, dropped: []} = Proposals.record_all(r)

      overrides = Enum.filter(rows, &(&1.kind == :difficulty_override))
      assert length(overrides) == 2
      assert Enum.all?(overrides, &(&1.state == :proposed))

      clusters = Enum.filter(rows, &(&1.kind == :config_set))
      assert length(clusters) == 2
      assert Enum.all?(clusters, &(&1.state == :hypothesis))
      refute Enum.any?(clusters, &Loop.applicable?/1)
    end
  end

  describe "the emitted patch feeds Canary directly (bd-53cuj6)" do
    test "Canary.eligible/1 (which calls parse_routing_patch/1) accepts a cleared-bar cluster's payload as-is" do
      {:ok, ws} =
        Ash.create(Workspace, %{
          name: "canary-feed-ws",
          prefix: "cf",
          config: %{
            "agent" => %{"type" => "claude", "config" => %{}},
            "routing" => %{"policy" => "by_difficulty"}
          }
        })

      r = report(%{difficulty_misestimates: misestimate_2026_08_10_fixture()})

      %{rows: rows, dropped: []} = Proposals.record_all(r, workspace_id: ws.id)

      assert [cluster] = Enum.filter(rows, &(&1.kind == :config_set))
      assert cluster.state == :proposed
      assert Loop.applicable?(cluster)

      assert {:ok, spec} = Arbiter.Loop.Canary.eligible(cluster)
      assert spec.difficulty == 2
      assert spec.rule == %{"model_tier" => "premium", "thinking" => "high"}
      assert spec.workspace_id == ws.id
    end

    test "applies successfully against a workspace shaped like the real live cells" do
      # The three live installations all carry only a D4 override
      # (flagship/xhigh) — this workspace mirrors that shape so `Apply.run/2`
      # exercises the exact patch the real D2 -> D3 / arbiter cell renders.
      {:ok, ws} =
        Ash.create(Workspace, %{
          name: "apply-feed-ws",
          prefix: "af",
          config: %{
            "agent" => %{"type" => "claude", "config" => %{}},
            "routing" => %{
              "policy" => "by_difficulty",
              "rules" => %{"D4" => %{"model_tier" => "flagship", "thinking" => "xhigh"}}
            }
          }
        })

      r = report(%{difficulty_misestimates: misestimate_2026_08_10_fixture()})

      %{rows: rows, dropped: []} = Proposals.record_all(r, workspace_id: ws.id)
      assert [cluster] = Enum.filter(rows, &(&1.kind == :config_set))
      assert cluster.state == :proposed

      assert {:ok, applied} = Arbiter.Loop.Apply.run(cluster, "test-operator")
      assert applied.state == :applied

      {:ok, updated_ws} = Ash.get(Workspace, ws.id)

      assert get_in(updated_ws.config, ["routing", "rules", "D2"]) == %{
               "model_tier" => "premium",
               "thinking" => "high"
             }

      # The pre-existing D4 override is untouched by the deep-merge patch.
      assert get_in(updated_ws.config, ["routing", "rules", "D4"]) == %{
               "model_tier" => "flagship",
               "thinking" => "xhigh"
             }
    end

    test "record_all/2 with no :workspace_id resolves the default workspace's config, not stock defaults" do
      # Production path: `arb loop analyze --propose` with no `--workspace`
      # leaves `workspace_id: nil` all the way down to `candidates/2`, but the
      # `:fleet`-scoped row still lands on `Quota.default_workspace_id()` on
      # insert (bd-3dasqm). `fetch_workspace_config/1` must mirror that same
      # resolution, or the patch renders against `ByDifficulty.default_mapping/0`
      # instead of the workspace the row actually applies to — exactly the gap
      # that dropped the live D3 -> D4 clusters (both D3 and D4 are
      # `premium/high` in the stock table, so the identity guard fired and
      # ate the candidate).
      {:ok, ws} =
        Ash.create(Workspace, %{
          name: "default",
          prefix: "def",
          config: %{
            "agent" => %{"type" => "claude", "config" => %{}},
            "routing" => %{
              "policy" => "by_difficulty",
              "rules" => %{"D4" => %{"model_tier" => "flagship", "thinking" => "xhigh"}}
            }
          }
        })

      r =
        report(%{
          difficulty_misestimates: [
            %{
              task_id: "bd-vstim-1",
              dispatched_difficulty: 3,
              rounds: 3,
              cost_usd: 9.0,
              reason: :rework,
              cell: {3, "vstim"},
              recommendation: %{}
            }
          ]
        })

      %{rows: rows, dropped: []} = Proposals.record_all(r)

      assert [cluster] = Enum.filter(rows, &(&1.kind == :config_set))
      assert cluster.workspace_id == ws.id

      assert cluster.payload["patch"] == %{
               "routing" => %{
                 "rules" => %{"D3" => %{"model_tier" => "flagship", "thinking" => "xhigh"}}
               }
             }
    end
  end
end
