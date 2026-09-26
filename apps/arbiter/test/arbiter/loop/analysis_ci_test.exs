defmodule Arbiter.Loop.AnalysisCiTest do
  # bd-cuu8n3: the CI section threads from `meta.ci` through
  # `Analysis.build_report/2` onto the report and into its markdown. Pure.
  use ExUnit.Case, async: true

  alias Arbiter.Loop
  alias Arbiter.Loop.{Analysis, CiSection, Report}
  alias Arbiter.Tasks.Workspace

  defp ci_meta do
    %{
      tasks: [
        %{
          task_id: "t1",
          repo: "arbiter",
          model: "m1",
          provider: "claude",
          workspace_id: "ws",
          difficulty: 3,
          pr?: true
        },
        %{
          task_id: "t2",
          repo: "arbiter",
          model: "m1",
          provider: "claude",
          workspace_id: "ws",
          difficulty: 3,
          pr?: true
        }
      ],
      fix_passes: [
        %{
          run_id: "r1",
          task_id: "t1",
          repo: "arbiter",
          workspace_id: "ws",
          evidence: %{
            checks: [%{name: "mix precommit (compile, deps, format)", summary: ""}],
            code_changed?: true,
            rerun?: false,
            marked_external?: false,
            summary: nil
          }
        },
        %{
          run_id: "r2",
          task_id: "t1",
          repo: "arbiter",
          workspace_id: "ws",
          evidence: %{
            checks: [],
            code_changed?: false,
            rerun?: false,
            marked_external?: false,
            summary: "Done."
          }
        }
      ],
      flake_events: [
        %{
          task_id: "t1",
          run_id: "r2",
          repo: "arbiter",
          ci_job: "mix test",
          test_file: "test/coverage_test.exs",
          test_line: 150,
          signature: "DataCase teardown timeout"
        },
        %{
          task_id: "t2",
          run_id: nil,
          repo: "arbiter",
          ci_job: "mix test",
          test_file: "test/coverage_test.exs",
          test_line: 150,
          signature: "DataCase teardown timeout"
        }
      ]
    }
  end

  test "build_report/2 carries the CI section built from meta.ci" do
    report = Analysis.build_report([], meta: %{ci: ci_meta()}, label: "t")

    assert report.ci.red_rate == %{tasks: 2, red: 1, rate: 0.5}
    assert report.ci.outcomes.counts.lint == 1
    assert report.ci.outcomes.counts.unknown == 1
  end

  test "build_report/2 surfaces recurring flakes from meta.ci (bd-6vullc)" do
    report =
      Analysis.build_report([],
        meta: %{ci: ci_meta()},
        ci_config: %{flake_recurrence_threshold: 2}
      )

    assert [flake] = report.ci.recurring_flakes
    assert flake.repo == "arbiter"
    assert flake.test_file == "test/coverage_test.exs"
    assert flake.test_line == 150
    assert flake.count == 2
    assert Enum.sort(flake.task_ids) == ["t1", "t2"]
  end

  test "build_report/2 threads the :ci_config thresholds through" do
    report =
      Analysis.build_report([],
        meta: %{ci: ci_meta()},
        ci_config: %{lint_share_threshold: 0.4, min_fix_passes: 2, check_commands: %{}}
      )

    assert [%{repo: "arbiter", check_command: "mix precommit"}] = report.ci.lint_flags
  end

  test "a report built with no meta.ci carries the empty section" do
    report = Analysis.build_report([], label: "t")
    assert report.ci == CiSection.empty()
  end

  describe "markdown" do
    setup do
      %{
        md:
          [] |> Analysis.build_report(meta: %{ci: ci_meta()}, label: "t") |> Report.to_markdown()
      }
    end

    test "renders the CI section with rates, counts and breakdowns", %{md: md} do
      assert md =~ "## CI: first-push red rate and fix_pass outcomes"
      assert md =~ "1 of 2"
      assert md =~ "50.0%"
      assert md =~ "| arbiter | 2 | 1 | 50.0% |"
      assert md =~ "| claude/m1 | 2 | 1 | 50.0% |"
      assert md =~ "| D3 | 2 | 1 | 50.0% |"
    end

    test "reports every outcome class and the unknown share", %{md: md} do
      for class <- ~w(lint flake_rerun test_fix infra unknown), do: assert(md =~ "`#{class}`")
      assert md =~ "unknown share"
      assert md =~ "50.0%"
    end

    test "states the approved-PR-only undercount", %{md: md} do
      assert md =~ CiSection.undercount()
    end

    test "renders recurring flakes with counts and task ids (bd-6vullc)" do
      md =
        []
        |> Analysis.build_report(
          meta: %{ci: ci_meta()},
          ci_config: %{flake_recurrence_threshold: 2}
        )
        |> Report.to_markdown()

      assert md =~ "### Recurring flakes"
      assert md =~ "test/coverage_test.exs:150"
      assert md =~ "recurred **2** time(s)"
      assert md =~ "t1"
      assert md =~ "t2"
    end
  end

  describe "Loop.ci_config/1" do
    test "defaults when the workspace sets nothing" do
      assert Loop.ci_config(nil) == %{
               lint_share_threshold: CiSection.default_lint_share_threshold(),
               min_fix_passes: CiSection.default_min_fix_passes(),
               check_commands: %{},
               flake_recurrence_threshold: CiSection.default_flake_recurrence_threshold()
             }
    end

    test "reads loop.ci from workspace config" do
      ws = %Workspace{
        config: %{
          "loop" => %{
            "ci" => %{
              "lint_share_threshold" => 0.5,
              "min_fix_passes" => "4",
              "check_commands" => %{"arbiter" => "mix precommit && mix audit"},
              "flake_recurrence_threshold" => "3"
            }
          }
        }
      }

      assert Loop.ci_config(ws) == %{
               lint_share_threshold: 0.5,
               min_fix_passes: 4,
               check_commands: %{"arbiter" => "mix precommit && mix audit"},
               flake_recurrence_threshold: 3
             }
    end

    test "an out-of-range threshold falls back to the default" do
      ws = %Workspace{config: %{"loop" => %{"ci" => %{"lint_share_threshold" => 7}}}}
      assert Loop.ci_config(ws).lint_share_threshold == CiSection.default_lint_share_threshold()
    end
  end
end
