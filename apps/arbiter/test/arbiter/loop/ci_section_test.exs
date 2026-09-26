defmodule Arbiter.Loop.CiSectionTest do
  # Pure module — no DB, no I/O. Fully synchronous.
  use ExUnit.Case, async: true

  alias Arbiter.Loop.CiSection

  defp task(id, attrs \\ %{}) do
    Map.merge(
      %{
        task_id: id,
        repo: "arbiter",
        workspace_id: "ws-1",
        model: "claude-opus-5-5",
        provider: "claude",
        difficulty: 3,
        pr?: true
      },
      Map.new(attrs)
    )
  end

  defp fix_pass(run_id, task_id, evidence, attrs \\ %{}) do
    Map.merge(
      %{
        run_id: run_id,
        task_id: task_id,
        repo: "arbiter",
        workspace_id: "ws-1",
        evidence:
          Map.merge(
            %{
              checks: [],
              code_changed?: nil,
              rerun?: false,
              marked_external?: false,
              summary: nil
            },
            Map.new(evidence)
          )
      },
      Map.new(attrs)
    )
  end

  defp lint_evidence,
    do: %{
      checks: [
        %{name: "mix precommit (compile, deps, format)", summary: ""},
        %{name: "mix audit (credo, sobelow, dialyzer)", summary: ""}
      ],
      code_changed?: true
    }

  defp test_evidence, do: %{checks: [%{name: "mix test", summary: ""}], code_changed?: true}

  describe "first-push CI red rate" do
    test "is the share of PR-bearing tasks that needed ≥1 fix_pass, with counts" do
      ci = %{
        tasks: [task("t1"), task("t2"), task("t3"), task("t4", pr?: false)],
        fix_passes: [
          fix_pass("r1", "t1", test_evidence()),
          fix_pass("r2", "t1", test_evidence())
        ]
      }

      section = CiSection.build(ci)

      # t4 never opened a PR, so it is not in the denominator; t1's two
      # fix-passes count it once.
      assert section.red_rate == %{tasks: 3, red: 1, rate: 1 / 3}
    end

    test "is broken down by repo, by provider/model and by difficulty" do
      ci = %{
        tasks: [
          task("a1"),
          task("a2"),
          task("v1", repo: "vstim", model: "claude-sonnet-5", difficulty: 2),
          task("v2", repo: "vstim", model: "claude-sonnet-5", difficulty: nil)
        ],
        fix_passes: [
          fix_pass("r1", "a1", test_evidence()),
          fix_pass("r2", "v1", test_evidence(), repo: "vstim"),
          fix_pass("r3", "v2", test_evidence(), repo: "vstim")
        ]
      }

      section = CiSection.build(ci)

      assert %{key: "arbiter", tasks: 2, red: 1, rate: 0.5} in section.by_repo
      assert %{key: "vstim", tasks: 2, red: 2, rate: 1.0} in section.by_repo

      assert %{key: "claude/claude-opus-5-5", tasks: 2, red: 1, rate: 0.5} in section.by_model
      assert %{key: "claude/claude-sonnet-5", tasks: 2, red: 2, rate: 1.0} in section.by_model

      assert %{key: 3, tasks: 2, red: 1, rate: 0.5} in section.by_difficulty
      assert %{key: 2, tasks: 1, red: 1, rate: 1.0} in section.by_difficulty
      assert %{key: nil, tasks: 1, red: 1, rate: 1.0} in section.by_difficulty
    end

    # Older main runs carry no `provider`; the model id's family names it, so
    # the same model does not split into a `?/` row and a `claude/` row.
    test "a run with no recorded provider is keyed by its model family" do
      ci = %{
        tasks: [
          task("a", provider: nil, model: "claude-opus-5"),
          task("b", provider: "claude", model: "claude-opus-5"),
          task("c", provider: nil, model: "gemini-3.8-flash-low"),
          task("d", provider: nil, model: "mystery-1")
        ],
        fix_passes: []
      }

      keys = CiSection.build(ci).by_model |> Enum.map(& &1.key) |> Enum.sort()
      assert keys == ["?/mystery-1", "claude/claude-opus-5", "gemini/gemini-3.8-flash-low"]
    end

    test "an empty window reports a nil rate, not zero" do
      section = CiSection.build(%{tasks: [], fix_passes: []})
      assert section.red_rate == %{tasks: 0, red: 0, rate: nil}
      assert section.outcomes.total == 0
      assert section.outcomes.unknown_share == nil
    end
  end

  describe "fix_pass outcomes" do
    test "every fix_pass is classified exactly once, with the unknown share reported" do
      ci = %{
        tasks: [task("t1"), task("t2")],
        fix_passes: [
          fix_pass("r1", "t1", lint_evidence()),
          fix_pass("r2", "t1", test_evidence()),
          fix_pass("r3", "t2", %{code_changed?: false, rerun?: true}),
          fix_pass("r4", "t2", %{marked_external?: true}),
          fix_pass("r5", "t2", %{code_changed?: false, summary: "Done."})
        ]
      }

      section = CiSection.build(ci)

      assert section.outcomes.total == 5

      assert section.outcomes.counts == %{
               lint: 1,
               flake_rerun: 1,
               test_fix: 1,
               infra: 1,
               unknown: 1
             }

      assert section.outcomes.unknown_share == 0.2
      assert Enum.map(section.runs, & &1.run_id) |> Enum.sort() == ~w(r1 r2 r3 r4 r5)
      assert Enum.all?(section.runs, &(&1.class in Arbiter.Loop.FixPassClassifier.classes()))
      assert section.outcomes.by_basis |> Map.values() |> Enum.sum() == 5
    end

    test "states the approved-PR-only undercount" do
      section = CiSection.build(%{tasks: [], fix_passes: []})
      assert section.undercount =~ "approved"
      assert section.undercount =~ "undercount"
    end
  end

  describe "lint feedback (repo_doc_patch flags)" do
    defp lint_heavy_ci(extra_fix_passes \\ []) do
      %{
        tasks: [task("t1"), task("t2"), task("t3")],
        fix_passes:
          [
            fix_pass("r1", "t1", lint_evidence()),
            fix_pass("r2", "t2", lint_evidence()),
            fix_pass("r3", "t3", test_evidence())
          ] ++ extra_fix_passes
      }
    end

    test "a repo whose lint share exceeds the threshold is flagged with its check command" do
      section = CiSection.build(lint_heavy_ci(), lint_share_threshold: 0.5, min_fix_passes: 3)

      assert [flag] = section.lint_flags
      assert flag.repo == "arbiter"
      assert flag.workspace_id == "ws-1"
      assert flag.lint == 2
      assert flag.total == 3
      assert flag.share == 2 / 3
      # Derived from the repo's own lint-job names, parentheticals stripped.
      assert flag.check_command == "mix precommit && mix audit"
      assert flag.check_command_source == :ci_job_names
      assert Enum.sort(flag.run_ids) == ~w(r1 r2)
      assert Enum.sort(flag.task_ids) == ~w(t1 t2)
    end

    test "a repo at or under the threshold is not flagged" do
      assert CiSection.build(lint_heavy_ci(), lint_share_threshold: 0.7).lint_flags == []
    end

    test "a repo below the minimum sample is not flagged" do
      assert CiSection.build(lint_heavy_ci(), lint_share_threshold: 0.5, min_fix_passes: 4).lint_flags ==
               []
    end

    test "a configured check command wins over the derived one" do
      section =
        CiSection.build(lint_heavy_ci(),
          lint_share_threshold: 0.5,
          check_commands: %{"arbiter" => "mix precommit && mix audit && mix test"}
        )

      assert [
               %{
                 check_command: "mix precommit && mix audit && mix test",
                 check_command_source: :config
               }
             ] =
               section.lint_flags
    end

    test "job names that are not commands fall back to naming the jobs" do
      ci = %{
        tasks: [task("t1", repo: "tonic"), task("t2", repo: "tonic")],
        fix_passes: [
          fix_pass("r1", "t1", %{checks: [%{name: "lint", summary: ""}], code_changed?: true},
            repo: "tonic"
          ),
          fix_pass("r2", "t2", %{checks: [%{name: "lint", summary: ""}], code_changed?: true},
            repo: "tonic"
          )
        ]
      }

      assert [flag] = CiSection.build(ci, lint_share_threshold: 0.5, min_fix_passes: 2).lint_flags
      assert flag.check_command_source == :ci_job_names
      assert flag.check_command =~ "`lint`"
    end

    test "defaults are exposed" do
      assert CiSection.default_lint_share_threshold() > 0
      assert CiSection.default_min_fix_passes() > 0
    end
  end

  describe "recurring flakes (bd-6vullc)" do
    defp flake(task_id, attrs \\ %{}) do
      Map.merge(
        %{
          task_id: task_id,
          run_id: "run-#{task_id}",
          repo: "arbiter",
          ci_job: "mix test",
          test_file: "test/coverage_test.exs",
          test_line: 150,
          signature: "DataCase teardown timeout"
        },
        Map.new(attrs)
      )
    end

    test "the same test file:line recurring at least N times is surfaced with counts and task ids" do
      ci = %{
        tasks: [],
        fix_passes: [],
        flake_events: [
          flake("t1"),
          flake("t2"),
          flake("t3", %{signature: "a different signature entirely"})
        ]
      }

      section = CiSection.build(ci, flake_recurrence_threshold: 2)

      assert [group] = section.recurring_flakes
      assert group.repo == "arbiter"
      assert group.test_file == "test/coverage_test.exs"
      assert group.test_line == 150
      assert group.count == 3
      assert Enum.sort(group.task_ids) == ["t1", "t2", "t3"]
    end

    test "below the threshold is not surfaced" do
      ci = %{
        tasks: [],
        fix_passes: [],
        flake_events: [flake("t1"), flake("t2", %{task_id: "t2"})]
      }

      section = CiSection.build(ci, flake_recurrence_threshold: 3)

      assert section.recurring_flakes == []
    end

    test "events with no test location group by signature instead" do
      ci = %{
        tasks: [],
        fix_passes: [],
        flake_events: [
          flake("t1", %{test_file: nil, test_line: nil, signature: "runner OOM"}),
          flake("t2", %{test_file: nil, test_line: nil, signature: "runner OOM"})
        ]
      }

      section = CiSection.build(ci, flake_recurrence_threshold: 2)

      assert [group] = section.recurring_flakes
      assert group.test_file == nil
      assert group.signature == "runner OOM"
      assert group.count == 2
    end

    test "different repos with the same test location are not merged" do
      ci = %{
        tasks: [],
        fix_passes: [],
        flake_events: [flake("t1", %{repo: "arbiter"}), flake("t2", %{repo: "shipyard"})]
      }

      section = CiSection.build(ci, flake_recurrence_threshold: 2)

      assert section.recurring_flakes == []
    end

    test "an empty window has no recurring flakes and the default threshold is exposed" do
      assert CiSection.empty().recurring_flakes == []
      assert CiSection.default_flake_recurrence_threshold() > 0
    end
  end
end
