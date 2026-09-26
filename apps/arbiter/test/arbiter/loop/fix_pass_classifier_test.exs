defmodule Arbiter.Loop.FixPassClassifierTest do
  # Pure module — no DB, no I/O. Fully synchronous.
  use ExUnit.Case, async: true

  alias Arbiter.Loop.FixPassClassifier, as: FPC
  alias Arbiter.Tasks.Issue
  alias Arbiter.Workflows.MergeQueue.FixPassDispatcher

  # ---- fixtures ------------------------------------------------------------

  # The fix-pass prompt exactly as the dispatcher renders it, so a change to
  # the briefing format breaks `parse_checks/1` here rather than silently in
  # the live corpus.
  defp prompt(checks) do
    FixPassDispatcher.prompt_for(%{
      task: %Issue{id: "bd-fixture"},
      branch: "feature/fixture",
      target_branch: "main",
      checks: checks
    })
  end

  defp step(name, input, opts \\ []) do
    %{
      name: name,
      input_summary: input,
      output_summary: Keyword.get(opts, :output),
      is_error: Keyword.get(opts, :error, false)
    }
  end

  defp evidence(attrs) do
    Map.merge(
      %{checks: [], code_changed?: nil, rerun?: false, marked_external?: false, summary: nil},
      Map.new(attrs)
    )
  end

  defp edit_steps do
    [
      step("Read", "apps/arbiter/lib/foo.ex"),
      step("Edit", "apps/arbiter/lib/foo.ex"),
      step("Bash", "git add -A && git commit -m \"fix\" && git push origin feature/x")
    ]
  end

  # ---- the class set -------------------------------------------------------

  test "classes/0 is the closed five-class set" do
    assert FPC.classes() == [:lint, :flake_rerun, :test_fix, :infra, :unknown]
  end

  # ---- parse_checks/1 --------------------------------------------------------

  describe "parse_checks/1" do
    test "recovers every check name and its log summary from the dispatcher's briefing" do
      text =
        prompt([
          %{name: "mix test", summary: "", url: "https://ci.example/jobs/1"},
          %{
            name: "lint",
            summary: "** (Mix) mix format failed due to --check-formatted.\nexit 1",
            url: nil
          }
        ])

      assert [
               %{name: "mix test", summary: ""},
               %{name: "lint", summary: summary}
             ] = FPC.parse_checks(text)

      assert summary =~ "mix format failed"
      assert summary =~ "exit 1"
    end

    test "a check name containing parentheses keeps them" do
      text =
        prompt([
          %{
            name: "mix audit (credo, sobelow, dialyzer)",
            summary: "",
            url: "https://github.com/o/r/actions/runs/1/job/2"
          }
        ])

      assert [%{name: "mix audit (credo, sobelow, dialyzer)"}] = FPC.parse_checks(text)
    end

    test "the no-details placeholder yields no checks" do
      assert FPC.parse_checks(prompt([])) == []
    end

    test "nil or a prompt without a briefing yields no checks" do
      assert FPC.parse_checks(nil) == []
      assert FPC.parse_checks("You are a worker. Do the thing.") == []
    end
  end

  # ---- check_kind/1 ----------------------------------------------------------

  describe "check_kind/1" do
    test "lint by job name" do
      for name <- [
            "mix precommit (compile, deps, format)",
            "mix audit (credo, sobelow, dialyzer)",
            "lint",
            "eslint",
            "typecheck"
          ] do
        assert FPC.check_kind(%{name: name, summary: ""}) == :lint, name
      end
    end

    test "test by job name" do
      for name <- ["mix test", "test 1/4", "test", "coverage", "visual", "e2e"] do
        assert FPC.check_kind(%{name: name, summary: ""}) == :test, name
      end
    end

    test "the log summary outranks the job name" do
      # vstim runs format + credo + tests in one job called `test`.
      assert FPC.check_kind(%{
               name: "test",
               summary: "** (Mix) mix format failed due to --check-formatted."
             }) == :lint

      assert FPC.check_kind(%{
               name: "test 2/4",
               summary:
                 "ERROR: Job failed: prepare environment: waiting for pod running: " <>
                   "pulling image \"minio/minio\": image pull failed"
             }) == :infra
    end

    test "an unrecognised job is :other" do
      assert FPC.check_kind(%{name: "audit:hex", summary: "vulnerability EEF-CVE-1"}) == :other
    end
  end

  # ---- step_signals/1 --------------------------------------------------------

  describe "step_signals/1" do
    test "an edit tool or a successful git commit is a code change" do
      assert FPC.step_signals([step("Edit", "lib/a.ex")]).code_changed?
      assert FPC.step_signals([step("replace_file_content", "lib/a.ex")]).code_changed?
      assert FPC.step_signals([step("Bash", "git commit -am wip")]).code_changed?
      assert FPC.step_signals([step("run_command", "git -C /w commit -m x")]).code_changed?
    end

    test "a failed commit and read-only steps are not a code change" do
      signals =
        FPC.step_signals([
          step("Bash", "git commit -m x", error: true),
          step("Read", "lib/a.ex"),
          step("Bash", "gh pr checks 12")
        ])

      refute signals.code_changed?
      refute signals.rerun?
      refute signals.marked_external?
    end

    # `input_summary` is capped at 200 characters, so a long `cd … && git add …
    # && git commit` loses its commit verb; the git output still proves it.
    test "a commit or a pushed ref update in a shell step's output is a code change" do
      assert FPC.step_signals([
               step("Bash", "cd /very/long/path && git add mix.lock test/visual/…",
                 output: "[bugfix/x 4ccf102] fix(ci): refresh baselines\n 2 files changed"
               )
             ]).code_changed?

      assert FPC.step_signals([
               step("Bash", "git push origin bugfix/x 2>&1 | tail -3",
                 output: "To gitlab.com:o/r.git\n   0fa68d4..4ccf102  bugfix/x -> bugfix/x"
               )
             ]).code_changed?
    end

    test "a push that had nothing to send is not a code change" do
      refute FPC.step_signals([
               step("Bash", "git push origin bugfix/x", output: "Everything up-to-date")
             ]).code_changed?
    end

    test "no steps at all is 'unknown', not 'no change'" do
      assert FPC.step_signals([]).code_changed? == nil
    end

    test "a ci_rerun tool call or a CLI job re-run is a rerun" do
      assert FPC.step_signals([step("mcp__arbiter__ci_rerun", "{\"mode\":\"auto\"}")]).rerun?
      assert FPC.step_signals([step("Bash", "gh run rerun 123 --failed")]).rerun?
      assert FPC.step_signals([step("Bash", "glab ci retry 456")]).rerun?
    end

    test "ci_mark_external is recorded" do
      assert FPC.step_signals([step("mcp__arbiter__ci_mark_external", "{\"note\":\"x\"}")]).marked_external?
    end
  end

  # ---- final_summary/2 -------------------------------------------------------

  describe "final_summary/2" do
    test "keeps the agent's prose and drops tool calls, results and session chrome" do
      lines = [
        "⏵ Bash(gh pr checks 2043)",
        "⏴ tool result",
        "mix audit (credo, sobelow, dialyzer)\tpass\t8m26s",
        "mix test\tpass\t7m1s",
        "All checks pass. No code changes were needed — the failure was a flake.",
        "",
        "arb done",
        "⚙ claude session success · 410.7s · $0.8471"
      ]

      last_outputs = ["mix audit (credo, sobelow, dialyzer)\tpass\t8m26s\nmix test\tpass\t7m1s"]

      assert FPC.final_summary(lines, last_outputs) ==
               "All checks pass. No code changes were needed — the failure was a flake."
    end

    test "a truncated tool result is skipped through its '… (N more lines)' marker" do
      lines = [
        "⏵ Bash(gh run view 1 --log-failed)",
        "⏴ tool result",
        "credo found 3 issues",
        "… (120 more lines)",
        "Fixed the flaky assertion in the test."
      ]

      assert FPC.final_summary(lines, []) == "Fixed the flaky assertion in the test."
    end

    test "glyph-tagged result bodies are dropped even without step outputs" do
      lines = ["⏵ Bash(mix test)", "⏴ tool result", "⏴ 3 tests, 1 failure", "Fixed the test."]
      assert FPC.final_summary(lines, []) == "Fixed the test."
    end

    test "prose before the final tool call is kept" do
      lines = [
        "The fix was a missing blank line that broke mix format.",
        "⏵ Bash(echo \"arb done\")",
        "⏴ tool result",
        "arb done"
      ]

      assert FPC.final_summary(lines, ["arb done"]) ==
               "The fix was a missing blank line that broke mix format."
    end
  end

  # ---- classify/1: one fixture per class -------------------------------------

  describe "classify/1 — lint" do
    test "a code change against only lint checks" do
      checks =
        FPC.parse_checks(
          prompt([
            %{name: "mix precommit (compile, deps, format)", summary: "", url: nil},
            %{name: "mix audit (credo, sobelow, dialyzer)", summary: "", url: nil}
          ])
        )

      r =
        FPC.classify(
          evidence(
            checks: checks,
            code_changed?: true,
            summary: "Added a blank line; mix format --check-formatted passes."
          )
        )

      assert r.class == :lint
      assert r.basis == :checks
    end

    test "a code change with no captured checks falls back to the summary" do
      r =
        FPC.classify(
          evidence(
            code_changed?: true,
            summary: "Removed the unused alias that tripped --warnings-as-errors."
          )
        )

      assert r.class == :lint
      assert r.basis == :summary
    end

    test "lint + test both red, summary says only formatting was wrong → lint" do
      r =
        FPC.classify(
          evidence(
            checks: [%{name: "mix test", summary: ""}, %{name: "mix audit (credo)", summary: ""}],
            code_changed?: true,
            summary: "The only problem was mix format on one file; ran the formatter."
          )
        )

      assert r.class == :lint
    end
  end

  describe "classify/1 — test_fix" do
    test "a code change against a failing test job" do
      r =
        FPC.classify(
          evidence(
            checks: [%{name: "mix test", summary: ""}],
            code_changed?: true,
            summary: "Updated the assertion to match the new copy."
          )
        )

      assert r.class == :test_fix
      assert r.basis == :checks
    end

    test "a code change with only a test-shaped summary" do
      r =
        FPC.classify(
          evidence(code_changed?: true, summary: "Fixed the failing test in worker_test.exs.")
        )

      assert r.class == :test_fix
      assert r.basis == :summary
    end
  end

  describe "classify/1 — flake_rerun" do
    test "no code change and a job re-run" do
      r =
        FPC.classify(
          evidence(
            checks: [%{name: "mix test", summary: ""}],
            code_changed?: false,
            rerun?: true,
            summary: "CI is green."
          )
        )

      assert r.class == :flake_rerun
      assert r.basis == :steps
    end

    test "no code change and a summary that names the re-run" do
      r =
        FPC.classify(
          evidence(
            checks: [%{name: "mix test", summary: ""}],
            code_changed?: false,
            summary: "mix test passed on re-run, confirming the baseline flake."
          )
        )

      assert r.class == :flake_rerun
      assert r.basis == :summary
    end
  end

  describe "classify/1 — a re-run test-suite flake is not infra" do
    # A DB-pool / sandbox flake in the test suite that a re-run cleared is a
    # flake, even when the worker's summary calls it "infra flakiness".
    test "no code change, a re-run, and a DBConnection flake in the summary" do
      r =
        FPC.classify(
          evidence(
            checks: [%{name: "mix test", summary: ""}],
            code_changed?: false,
            rerun?: true,
            summary:
              "The failure was the known DBConnection.OwnershipError sandbox flake, " <>
                "repo-wide infra flakiness; a rerun of the failed job passed."
          )
        )

      assert r.class == :flake_rerun
    end

    test "no code change, no re-run, and only a weak infra word still reads infra" do
      r =
        FPC.classify(
          evidence(
            code_changed?: false,
            summary: "This is broken CI infrastructure, not this branch."
          )
        )

      assert r.class == :infra
    end
  end

  describe "classify/1 — infra" do
    test "a ci_mark_external verdict wins over everything" do
      r =
        FPC.classify(
          evidence(
            checks: [%{name: "mix test", summary: ""}],
            code_changed?: true,
            marked_external?: true
          )
        )

      assert r.class == :infra
      assert r.basis == :steps
    end

    test "no code change and every check log is a runner failure" do
      r =
        FPC.classify(
          evidence(
            checks: [
              %{
                name: "test 1/4",
                summary: "ERROR: Job failed: prepare environment: ImagePullBackOff"
              }
            ],
            code_changed?: false
          )
        )

      assert r.class == :infra
      assert r.basis == :checks
    end

    # From the live corpus (bd-8h5iyc): a worker checking its own API budget
    # is not a rate-limit failure.
    test "a rate limit mentioned as fine is not infra" do
      r =
        FPC.classify(
          evidence(
            code_changed?: false,
            rerun?: true,
            summary: "Rate limit is fine now (4418 remaining). Re-ran the flaky job; green."
          )
        )

      assert r.class == :flake_rerun
    end

    test "a bare 403 in unrelated prose is not infra" do
      r = FPC.classify(evidence(code_changed?: false, summary: "See PR #403 for context."))
      assert r.class == :unknown
    end

    test "an HTTP 403 Forbidden is infra" do
      r = FPC.classify(evidence(code_changed?: false, summary: "gh api returned 403 Forbidden."))
      assert r.class == :infra
    end

    test "no code change and a summary naming a rate limit" do
      r =
        FPC.classify(
          evidence(code_changed?: false, summary: "The job hit the GitHub API rate limit.")
        )

      assert r.class == :infra
      assert r.basis == :summary
    end
  end

  describe "classify/1 — unknown" do
    test "no code change, no re-run and nothing in the text" do
      r = FPC.classify(evidence(code_changed?: false, summary: "Done."))
      assert r.class == :unknown
      assert r.basis == :none
    end

    test "no evidence at all" do
      assert FPC.classify(evidence([])).class == :unknown
    end

    test "a code change against an unrecognised check with no text signal" do
      r =
        FPC.classify(
          evidence(
            checks: [%{name: "audit:hex", summary: "vulnerability found"}],
            code_changed?: true,
            summary: "Bumped the dependency."
          )
        )

      assert r.class == :unknown
    end
  end

  test "classification is deterministic: same evidence, same answer" do
    ev = evidence(checks: [%{name: "mix test", summary: ""}], code_changed?: true)
    assert FPC.classify(ev) == FPC.classify(ev)
  end

  test "step_signals feeds classify end to end" do
    signals = FPC.step_signals(edit_steps())

    r =
      FPC.classify(evidence(Map.to_list(signals) ++ [checks: [%{name: "mix test", summary: ""}]]))

    assert r.class == :test_fix
  end
end
