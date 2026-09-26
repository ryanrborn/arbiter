defmodule Arbiter.Loop.FixPassClassifier do
  @moduledoc """
  Deterministic outcome classification for CI **fix_pass** runs (bd-cuu8n3).

  A fix_pass is dispatched when an approved PR is blocked on red CI
  (`Arbiter.Workflows.MergeQueue.FixPassDispatcher`). It normally ends
  `:completed`, so `Arbiter.Loop.FailureClassifier` (which only sees `:failed`
  runs) never looks at it. This module sorts each one into exactly one of:

    * `:lint` — format / credo / dialyzer / compile-warning fix. Preventable
      by running the repo's full check before pushing.
    * `:flake_rerun` — no code change; the job was re-run and went green.
    * `:test_fix` — a code change against a failing test job.
    * `:infra` — auth, rate limit, runner or DB trouble, or the worker's own
      `ci_mark_external` verdict.
    * `:unknown` — none of the above could be shown. Reported, never hidden.

  Like the rest of the Loop pass this is **model-free**: allowlist regexes
  over structured data first, prose only as a fallback. The inputs, in the
  order they are trusted:

    1. **Steps** (`worker_run_steps`) — did the worker edit a file or make a
       successful `git commit` (the diff is non-empty), re-run a job, or call
       `ci_mark_external`? See `step_signals/1`.
    2. **Checks** — the failing CI jobs the dispatcher briefed the worker
       with, recovered from the run's archived prompt (`parse_checks/1`):
       each job's name and, on GitLab, its log tail. See `check_kind/1`.
    3. **Summary** — the worker's closing prose (`final_summary/2`, or the
       CLI's own result text when it was captured).

  `classify/1` returns the class, the `basis` it was decided on (`:steps`,
  `:checks`, `:summary`, or `:none` for `:unknown`) and a short reason, so a
  report can say how much of the window was decided from structure versus
  text.
  """

  @classes [:lint, :flake_rerun, :test_fix, :infra, :unknown]

  @type class :: :lint | :flake_rerun | :test_fix | :infra | :unknown
  @type basis :: :steps | :checks | :summary | :none
  @type check :: %{name: String.t(), summary: String.t()}
  @type check_kind :: :lint | :test | :infra | :other
  @type step :: %{
          required(:name) => String.t() | nil,
          required(:input_summary) => String.t() | nil,
          optional(:output_summary) => String.t() | nil,
          required(:is_error) => boolean() | integer() | nil
        }
  @type signals :: %{
          code_changed?: boolean() | nil,
          rerun?: boolean(),
          marked_external?: boolean()
        }
  @type evidence :: %{
          optional(:checks) => [check()],
          optional(:code_changed?) => boolean() | nil,
          optional(:rerun?) => boolean(),
          optional(:marked_external?) => boolean(),
          optional(:summary) => String.t() | nil
        }
  @type result :: %{class: class(), basis: basis(), reason: String.t()}

  # ---- vocabularies ----------------------------------------------------------

  # Tools that write a file. Claude Code's names, agy's, and codex's.
  @edit_tools ~w(Edit Write MultiEdit NotebookEdit replace_file_content write_to_file
                 multi_replace_file_content apply_patch)

  # Tools whose `input_summary` is a shell command line.
  @shell_tools ~w(Bash bash run_command shell exec_command)

  @commit_re ~r/\bgit\b[^|;&]*\bcommit\b/
  # Git's own output proving a non-empty diff: a new commit (`[branch sha]
  # msg`) or a pushed ref update (`0fa68d4..4ccf102  branch -> branch`, or a
  # forced `+ a...b`). Read because `input_summary` is capped at 200
  # characters and a long `cd … && git add … && git commit` loses its verb.
  @commit_output_re ~r/^\[[^\]\s]+ [0-9a-f]{7,}\]|^\s*\+?\s*[0-9a-f]{7,}\.{2,3}[0-9a-f]{7,}\s+\S+ -> \S+/m
  @rerun_cmd_re ~r/gh run rerun|gh workflow run|glab (ci|pipeline|job) (retry|run)|\/(retry|rerun|rerun-failed-jobs)\b/

  # A CI job log whose tail says the *runner* failed, not the code.
  @check_infra_re ~r/prepare environment|image pull failed|ImagePullBackOff|ErrImagePull|runner system failure|no space left on device|rate limit exceeded|HTTP Basic: Access denied|401 Unauthorized|403 Forbidden|could not resolve host|runner has received a shutdown signal|stuck_or_timeout_failure/i

  @check_lint_log_re ~r/mix format failed|--check-formatted|\bcredo\b|\bdialyzer\b|Compilation failed due to warnings|warnings[- ]as[- ]errors|\beslint\b|prettier --check|\brubocop\b|\bclippy\b/i
  @check_test_log_re ~r/\d+ tests?, [1-9]\d* failures?|Assertion with|\btests? failed\b/i

  @check_lint_name_re ~r/format|credo|dialyzer|lint|pre-?commit|compile|prettier|rubocop|clippy|sobelow|typecheck|\btsc\b|mypy|\bstyle\b/i
  @check_test_name_re ~r/\btests?\b|coverage|visual|\be2e\b|\bspecs?\b|playwright|cypress|integration/i

  # Prose vocabularies for the summary fallback.
  # Strong: an infrastructure cause no re-run of the test suite explains.
  @summary_infra_re ~r/rate[- ]limited|rate[- ]limit (was |is )?(exceeded|hit|reached)|(hit|exceeded|reached|exhausted) (the |a |our )?(\S+ ){0,3}rate[- ]limit|\b40[13] (Unauthorized|Forbidden)\b|HTTP 40[13]\b|unauthori[sz]ed|credentials? (expired|invalid)|authentication fail|runner (fail|died|lost|was lost|shut ?down|system failure)|no space left|out of disk|image pull|ImagePullBackOff|could not resolve host|service unavailable|database (is |was )?(down|unavailable|unreachable)/i
  # Weak: "infra" words that, in practice, workers also use for a test-suite
  # DB-pool/sandbox flake. Only decisive when nothing was re-run.
  @summary_weak_infra_re ~r/\binfra(structure)?\b|DBConnection/i
  @summary_flake_re ~r/\bflak(e|es|y|iness)\b|\bre-?ran\b|\bre-?run\b|\brerun\b|\bretr(y|ied)\b|intermittent|transient|passed on (the )?(re|second|another)/i
  @summary_lint_re ~r/mix format|formatt(ing|er)|--check-formatted|\bcredo\b|\bdialyzer\b|compile(r)? warnings?|warnings[- ]as[- ]errors|unused (variable|alias|import|function)|\blint(er|ing)?\b|\bprettier\b|\beslint\b|\brubocop\b|\bclippy\b|\bsobelow\b/i
  @summary_test_re ~r/\btests?\b[^.]{0,40}\b(fail|fix|broke|assert)|failing tests?|test failures?|\bassertions?\b|\bExUnit\b/i

  @doc "The closed class set, in report order."
  @spec classes() :: [class()]
  def classes, do: @classes

  # ---- classify ----------------------------------------------------------------

  @doc """
  Classify one fix_pass run from its `evidence` (see the moduledoc for the
  inputs). Pure and total: every input maps to exactly one class.
  """
  @spec classify(evidence()) :: result()
  def classify(evidence) when is_map(evidence) do
    checks = Map.get(evidence, :checks) || []
    summary = Map.get(evidence, :summary) || ""
    kinds = checks |> Enum.map(&check_kind/1) |> Enum.uniq()

    cond do
      Map.get(evidence, :marked_external?) == true ->
        result(:infra, :steps, "worker recorded a ci_mark_external verdict")

      Map.get(evidence, :code_changed?) == false ->
        no_change(evidence, kinds, summary)

      Map.get(evidence, :code_changed?) == true ->
        changed(kinds, summary)

      true ->
        no_step_data(kinds, summary)
    end
  end

  # Nothing was edited or committed: the check went green (or was declared
  # not-our-problem) without a diff.
  defp no_change(evidence, kinds, summary) do
    cond do
      kinds != [] and Enum.all?(kinds, &(&1 == :infra)) ->
        result(:infra, :checks, "every failing job's log is a runner/auth failure")

      summary =~ @summary_infra_re ->
        result(:infra, :summary, "no code change; summary names an infrastructure cause")

      Map.get(evidence, :rerun?) == true ->
        result(:flake_rerun, :steps, "no code change; the job was re-run")

      summary =~ @summary_flake_re ->
        result(:flake_rerun, :summary, "no code change; summary describes a re-run/flake")

      summary =~ @summary_weak_infra_re ->
        result(:infra, :summary, "no code change or re-run; summary blames infrastructure")

      true ->
        result(:unknown, :none, "no code change, no re-run, no recognisable cause")
    end
  end

  # A diff was made, so something code-shaped was fixed: decide which gate it
  # was for. A job whose log is a runner failure says nothing about the diff,
  # so `:infra` checks drop out of that decision.
  defp changed(kinds, summary) do
    case {:lint in kinds, :test in kinds} do
      {true, true} ->
        if lint_only_summary?(summary),
          do: result(:lint, :summary, "lint and test jobs red; summary names only a lint fix"),
          else: result(:test_fix, :checks, "code change against a red test job")

      {false, true} ->
        result(:test_fix, :checks, "code change against a red test job")

      {true, false} ->
        result(:lint, :checks, "code change against red lint jobs only")

      {false, false} ->
        changed_without_gate(kinds, summary)
    end
  end

  # No red job names a lint or test gate (none captured, or only
  # unrecognised/runner-failure jobs): the summary decides.
  defp changed_without_gate(kinds, summary) do
    cond do
      summary =~ @summary_lint_re ->
        result(:lint, :summary, "code change; summary names a lint fix")

      summary =~ @summary_test_re ->
        result(:test_fix, :summary, "code change; summary names a test fix")

      kinds != [] and Enum.all?(kinds, &(&1 == :infra)) ->
        result(:infra, :checks, "every failing job's log is a runner/auth failure")

      true ->
        result(:unknown, :none, "code change against an unrecognised job")
    end
  end

  defp lint_only_summary?(summary),
    do: summary =~ @summary_lint_re and not (summary =~ @summary_test_re)

  # A run with no step rows (recorded before `worker_run_steps` existed): the
  # diff is unknown, so the text leads and the job names back it up.
  defp no_step_data(kinds, summary) do
    cond do
      summary =~ @summary_infra_re ->
        result(:infra, :summary, "summary names an infrastructure cause")

      summary =~ @summary_flake_re ->
        result(:flake_rerun, :summary, "summary describes a re-run/flake")

      summary =~ @summary_lint_re ->
        result(:lint, :summary, "summary names a lint fix")

      summary =~ @summary_test_re ->
        result(:test_fix, :summary, "summary names a test fix")

      summary =~ @summary_weak_infra_re ->
        result(:infra, :summary, "summary blames infrastructure")

      :test in kinds ->
        result(:test_fix, :checks, "red test job (no step data)")

      :lint in kinds ->
        result(:lint, :checks, "red lint jobs only (no step data)")

      true ->
        result(:unknown, :none, "no step data and no recognisable cause")
    end
  end

  defp result(class, basis, reason), do: %{class: class, basis: basis, reason: reason}

  # ---- checks --------------------------------------------------------------

  @doc """
  Recover the failing-check briefing from a fix-pass prompt rendered by
  `FixPassDispatcher.prompt_for/1` (archived per run by
  `Arbiter.Worker.PromptLog`). Returns `[%{name:, summary:}]` — `summary` is
  the job's log tail as briefed (often empty on GitHub, which hands over no
  log). `[]` when the prompt has no briefing or said none was captured.
  """
  @spec parse_checks(String.t() | nil) :: [check()]
  def parse_checks(prompt) when is_binary(prompt) do
    with [_, rest] <- String.split(prompt, "Failing checks:\n", parts: 2),
         [block | _] <- String.split(rest, "\nDO NOT:", parts: 2) do
      block
      |> String.split("\n")
      |> Enum.reduce([], &collect_check_line/2)
      |> Enum.reverse()
      |> Enum.map(fn %{summary: lines} = c ->
        %{c | summary: lines |> Enum.reverse() |> Enum.join("\n") |> String.trim()}
      end)
    else
      _ -> []
    end
  end

  def parse_checks(_), do: []

  # `  * <name>[ (<url>)]` opens a check; six-space-indented lines are its
  # summary (`FixPassDispatcher.render_check/1`).
  defp collect_check_line("  * " <> header, acc) do
    name =
      case Regex.run(~r/^(.*) \((https?:\/\/[^\s)]+)\)$/, header) do
        [_, name, _url] -> name
        nil -> header
      end

    [%{name: String.trim(name), summary: []} | acc]
  end

  defp collect_check_line("      " <> line, [%{summary: lines} = current | rest]),
    do: [%{current | summary: [line | lines]} | rest]

  defp collect_check_line(_line, acc), do: acc

  @doc """
  What kind of gate one failing check is. The job's log tail is read first
  (a runner failure, a formatter/linter message, a test-failure count) and
  outranks its name, because one job can run several gates — vstim's `test`
  job also runs the formatter.
  """
  @spec check_kind(check()) :: check_kind()
  def check_kind(%{} = check) do
    name = Map.get(check, :name) || ""
    log = Map.get(check, :summary) || ""

    cond do
      log =~ @check_infra_re -> :infra
      log =~ @check_lint_log_re -> :lint
      log =~ @check_test_log_re -> :test
      name =~ @check_lint_name_re -> :lint
      name =~ @check_test_name_re -> :test
      true -> :other
    end
  end

  # ---- steps -----------------------------------------------------------------

  @doc """
  Structured signals from a run's tool-call steps. `code_changed?` is `nil`
  — unknown, not "no" — when the run has no step rows at all.
  """
  @spec step_signals([step()]) :: signals()
  def step_signals([]), do: %{code_changed?: nil, rerun?: false, marked_external?: false}

  def step_signals(steps) when is_list(steps) do
    ok = Enum.reject(steps, &error?/1)

    %{
      code_changed?: Enum.any?(ok, &code_change?/1),
      rerun?: Enum.any?(ok, &rerun?/1),
      marked_external?: Enum.any?(ok, &tool?(&1, "ci_mark_external"))
    }
  end

  defp error?(%{is_error: e}) when e in [true, 1], do: true
  defp error?(_), do: false

  defp code_change?(%{name: name}) when name in @edit_tools, do: true

  defp code_change?(%{name: name} = step) when name in @shell_tools,
    do: input(step) =~ @commit_re or output(step) =~ @commit_output_re

  defp code_change?(_), do: false

  defp rerun?(%{name: name} = step) when name in @shell_tools, do: input(step) =~ @rerun_cmd_re
  defp rerun?(step), do: tool?(step, "ci_rerun")

  # An MCP tool call, directly (`mcp__arbiter__ci_rerun`) or through agy's
  # generic `call_mcp_tool` wrapper, which names the tool in its input.
  defp tool?(%{name: "call_mcp_tool"} = step, tool), do: String.contains?(input(step), tool)
  defp tool?(%{name: name}, tool) when is_binary(name), do: String.ends_with?(name, tool)
  defp tool?(_, _), do: false

  defp input(%{input_summary: s}) when is_binary(s), do: s
  defp input(_), do: ""

  defp output(%{output_summary: s}) when is_binary(s), do: s
  defp output(_), do: ""

  # ---- final summary -----------------------------------------------------------

  @doc """
  The worker's closing prose, recovered from the tail of its rendered
  transcript (`Arbiter.Worker.OutputLog`): every line that is not a tool
  call, a tool result, or session chrome, joined with spaces.

  Tool-result bodies are recognised three ways: the `⏴ ` glyph newer
  transcripts tag them with, the `… (N more lines)` marker a truncated result
  ends on, and — for older, untagged transcripts — membership in
  `step_outputs`, the `output_summary` of the run's last few steps (the same
  text, redacted by the same choke-point).
  """
  @spec final_summary([String.t()], [String.t() | nil]) :: String.t()
  def final_summary(lines, step_outputs \\ []) when is_list(lines) do
    known =
      step_outputs
      |> Enum.flat_map(&String.split(&1 || "", "\n"))
      |> Enum.map(&String.trim/1)
      |> Enum.reject(&(&1 == ""))
      |> MapSet.new()

    lines
    |> Enum.reduce({[], :prose, []}, fn line, state -> prose_line(line, state, known) end)
    |> elem(0)
    |> Enum.reverse()
    |> Enum.join(" ")
  end

  @more_lines_re ~r/^(⏴ )?… \(\d+ more lines?\)$/

  # State: `{prose_acc, mode, acc_at_last_result_header}`. A result body is
  # skipped while its lines are known step output; a `… (N more lines)` marker
  # proves everything since the header was result body, so the accumulator is
  # rewound to where the header left it.
  defp prose_line(line, {acc, mode, mark}, known) do
    trimmed = String.trim(line)

    cond do
      String.starts_with?(trimmed, "⏵ ") -> {acc, :prose, mark}
      trimmed in ["⏴ tool result", "⏴ tool error"] -> {acc, :result, acc}
      trimmed =~ @more_lines_re -> {mark, :prose, mark}
      chrome?(trimmed) -> {acc, mode, mark}
      mode == :result and MapSet.member?(known, trimmed) -> {acc, :result, mark}
      true -> {[trimmed | acc], :prose, mark}
    end
  end

  defp chrome?(""), do: true
  defp chrome?("arb done"), do: true
  defp chrome?("⏴" <> _), do: true
  defp chrome?("⚙" <> _), do: true
  defp chrome?(_), do: false
end
