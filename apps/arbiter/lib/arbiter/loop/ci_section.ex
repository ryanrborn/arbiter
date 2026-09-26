defmodule Arbiter.Loop.CiSection do
  @moduledoc """
  The CI section of the loop-analysis report (bd-cuu8n3): how often a task's
  PR went red on CI, and what each CI fix_pass actually fixed.

  Pure — `build/2` reasons over the `meta.ci` shape `Arbiter.Loop.Corpus`
  fetched and writes nothing.

  ## First-push CI red rate

  The share of PR-bearing tasks (a main run in the window, and a PR) that
  needed at least one fix_pass, overall and broken down by repo, by the
  provider/model of the task's latest main run in the window, and by the
  task's difficulty. Every rate carries its counts.

  ## Known undercount

  A fix_pass is only dispatched for an **approved** PR blocked on red CI
  (`Arbiter.Workflows.MergeQueue.FixPassDispatcher`). A push that went red
  and was fixed during review — by the implementer's own next round — leaves
  no fix_pass behind, so it is not counted here. The rate is a lower bound;
  `undercount/0` says so in every rendering.

  ## Fix_pass outcomes

  Every fix_pass run in the window is classified by
  `Arbiter.Loop.FixPassClassifier` into exactly one class, with the basis it
  was decided on. The `:unknown` share is reported, not hidden.

  ## Lint feedback

  A repo whose `:lint` share of fix_passes exceeds `:lint_share_threshold`
  (with at least `:min_fix_passes` fix_passes this window) is flagged with the
  command that would have caught those failures before the push. Each flag
  becomes a `:repo_doc_patch` proposal in `Arbiter.Loop.Proposals` — the
  first producer that rung of the destination ladder has had.

  The command is, in order: the workspace's configured
  `loop.ci.check_commands.<repo>`; else the repo's own red lint-job names this
  window, when each reads as a command (`mix precommit (compile, deps,
  format)` → `mix precommit`); else a phrase naming those jobs.
  """

  alias Arbiter.Loop.FixPassClassifier

  @default_lint_share_threshold 0.3
  @default_min_fix_passes 3

  @undercount "Known undercount: a fix_pass is only dispatched for an approved PR blocked on red CI, " <>
                "so a push that went red and was fixed before approval (during review) is not counted. " <>
                "The first-push red rate is a lower bound."

  # Leading tokens that make a CI job name read as a runnable command.
  @command_prefix_re ~r/^(mix|npm|npx|yarn|pnpm|make|cargo|go|bundle|bin\/|\.\/|poetry|uv|ruff|pytest|tox|gradle|mvn|dotnet|just)\b/

  @type rate_row :: %{
          key: term(),
          tasks: non_neg_integer(),
          red: non_neg_integer(),
          rate: float() | nil
        }

  @type t :: %{
          red_rate: %{tasks: non_neg_integer(), red: non_neg_integer(), rate: float() | nil},
          by_repo: [rate_row()],
          by_model: [rate_row()],
          by_difficulty: [rate_row()],
          outcomes: map(),
          outcomes_by_repo: [map()],
          runs: [map()],
          lint_flags: [map()],
          lint_share_threshold: float(),
          min_fix_passes: pos_integer(),
          undercount: String.t()
        }

  @doc "Default `:lint_share_threshold` (overridable under `loop.ci.lint_share_threshold`)."
  @spec default_lint_share_threshold() :: float()
  def default_lint_share_threshold, do: @default_lint_share_threshold

  @doc "Default `:min_fix_passes` (overridable under `loop.ci.min_fix_passes`)."
  @spec default_min_fix_passes() :: pos_integer()
  def default_min_fix_passes, do: @default_min_fix_passes

  @doc "The approved-PR-only undercount, stated verbatim in every rendering."
  @spec undercount() :: String.t()
  def undercount, do: @undercount

  @doc "The section for an empty window — the default before anything is fetched."
  @spec empty() :: t()
  def empty, do: build(%{tasks: [], fix_passes: []})

  @doc """
  Build the section from `ci` (`%{tasks: [...], fix_passes: [...]}`, see
  `Arbiter.Loop.Corpus`). Options: `:lint_share_threshold`,
  `:min_fix_passes`, `:check_commands` (`%{repo => command}`).
  """
  @spec build(map(), keyword()) :: t()
  def build(ci, opts \\ []) do
    threshold = Keyword.get(opts, :lint_share_threshold) || @default_lint_share_threshold
    min_n = Keyword.get(opts, :min_fix_passes) || @default_min_fix_passes
    commands = Keyword.get(opts, :check_commands) || %{}

    fix_passes = Map.get(ci, :fix_passes) || []
    runs = Enum.map(fix_passes, &classify/1)

    red_ids = fix_passes |> Enum.map(& &1.task_id) |> MapSet.new()

    cohort =
      (Map.get(ci, :tasks) || [])
      |> Enum.filter(&(&1.pr? or MapSet.member?(red_ids, &1.task_id)))
      |> Enum.map(&Map.put(&1, :red?, MapSet.member?(red_ids, &1.task_id)))

    %{
      red_rate: rate(cohort),
      by_repo: breakdown(cohort, & &1.repo),
      by_model: breakdown(cohort, &model_key/1),
      by_difficulty: breakdown(cohort, & &1.difficulty),
      outcomes: outcomes(runs),
      outcomes_by_repo: outcomes_by_repo(runs),
      runs: runs,
      lint_flags: lint_flags(runs, threshold, min_n, commands),
      lint_share_threshold: threshold,
      min_fix_passes: min_n,
      undercount: @undercount
    }
  end

  # ---- red rate ------------------------------------------------------------

  defp rate(tasks) do
    n = length(tasks)
    red = Enum.count(tasks, & &1.red?)
    %{tasks: n, red: red, rate: if(n == 0, do: nil, else: red / n)}
  end

  defp breakdown(cohort, key_fun) do
    cohort
    |> Enum.group_by(key_fun)
    |> Enum.map(fn {key, tasks} -> Map.put(rate(tasks), :key, key) end)
    |> Enum.sort_by(&{-&1.tasks, to_string(&1.key)})
  end

  # `worker_runs.provider` is NULL on runs recorded before it existed. The
  # model id's family names the provider unambiguously, so infer it from that
  # rather than splitting one model across a `?/` row and a `claude/` row.
  defp model_key(task) do
    model = Map.get(task, :model)
    provider = Map.get(task, :provider) || provider_for(model) || "?"
    "#{provider}/#{model || "?"}"
  end

  defp provider_for("claude-" <> _), do: "claude"
  defp provider_for("gemini-" <> _), do: "gemini"
  defp provider_for("gpt-" <> _), do: "codex"
  defp provider_for(_), do: nil

  # ---- outcomes ------------------------------------------------------------

  defp classify(fp) do
    evidence = Map.get(fp, :evidence) || %{}
    %{class: class, basis: basis, reason: reason} = FixPassClassifier.classify(evidence)

    %{
      run_id: fp.run_id,
      task_id: fp.task_id,
      repo: fp.repo,
      workspace_id: Map.get(fp, :workspace_id),
      class: class,
      basis: basis,
      reason: reason,
      checks: Map.get(evidence, :checks) || []
    }
  end

  defp outcomes(runs) do
    total = length(runs)
    counts = counts(runs)

    %{
      total: total,
      counts: counts,
      unknown_share: if(total == 0, do: nil, else: counts.unknown / total),
      by_basis:
        Map.merge(
          %{steps: 0, checks: 0, summary: 0, none: 0},
          Enum.frequencies_by(runs, & &1.basis)
        )
    }
  end

  defp counts(runs) do
    zero = Map.new(FixPassClassifier.classes(), &{&1, 0})
    Map.merge(zero, Enum.frequencies_by(runs, & &1.class))
  end

  defp outcomes_by_repo(runs) do
    runs
    |> Enum.group_by(& &1.repo)
    |> Enum.map(fn {repo, rs} ->
      counts = counts(rs)
      %{repo: repo, total: length(rs), counts: counts, lint_share: counts.lint / length(rs)}
    end)
    |> Enum.sort_by(&{-&1.total, to_string(&1.repo)})
  end

  # ---- lint feedback -----------------------------------------------------------

  defp lint_flags(runs, threshold, min_n, commands) do
    runs
    |> Enum.reject(&is_nil(&1.repo))
    |> Enum.group_by(& &1.repo)
    |> Enum.flat_map(fn {repo, rs} ->
      lint = Enum.filter(rs, &(&1.class == :lint))
      share = length(lint) / length(rs)

      if length(rs) >= min_n and share > threshold do
        {command, source} = check_command(repo, lint, commands)

        [
          %{
            repo: repo,
            workspace_id: majority_workspace(rs),
            lint: length(lint),
            total: length(rs),
            share: share,
            threshold: threshold,
            check_command: command,
            check_command_source: source,
            run_ids: Enum.map(lint, & &1.run_id),
            task_ids: lint |> Enum.map(& &1.task_id) |> Enum.uniq()
          }
        ]
      else
        []
      end
    end)
    |> Enum.sort_by(& &1.repo)
  end

  # The workspace the repo's runs mostly ran under — the one whose
  # `repo_paths` the proposal's apply path must resolve the repo against.
  defp majority_workspace(runs) do
    runs
    |> Enum.map(& &1.workspace_id)
    |> Enum.reject(&is_nil/1)
    |> Enum.frequencies()
    |> Enum.max_by(fn {_ws, n} -> n end, fn -> {nil, 0} end)
    |> elem(0)
  end

  defp check_command(repo, lint_runs, commands) do
    case Map.get(commands, repo) do
      cmd when is_binary(cmd) and cmd != "" ->
        {cmd, :config}

      _ ->
        names =
          lint_runs
          |> Enum.flat_map(& &1.checks)
          |> Enum.filter(&(FixPassClassifier.check_kind(&1) == :lint))
          |> Enum.map(&strip_parenthetical(&1.name))
          |> Enum.uniq()

        cond do
          names == [] ->
            {"the repo's full pre-push check suite (format, lint, type-check, compile with warnings as errors)",
             :fallback}

          Enum.all?(names, &(&1 =~ @command_prefix_re)) ->
            {Enum.join(names, " && "), :ci_job_names}

          true ->
            {"the same checks CI runs as " <> Enum.map_join(names, ", ", &"`#{&1}`"),
             :ci_job_names}
        end
    end
  end

  defp strip_parenthetical(name),
    do: name |> String.replace(~r/\s*\([^)]*\)\s*$/, "") |> String.trim()
end
