defmodule Arbiter.Skills.Materializer do
  @moduledoc """
  Dispatch-time materialization + prompt advertisement of the resolved skill
  set (epic child 3, bd-d5hy7y).

  ## Materialization

  At dispatch, arbiter writes **only** the resolved effective set into the
  worker's isolated worktree as `.claude/skills/<name>/SKILL.md` — the same
  injection point as the per-worker `.mcp.json` in `Arbiter.Worker.Dispatch`.
  Claude Code auto-discovers project skills under `.claude/skills/` from the
  working directory, so the worker sees exactly the selected set and nothing
  more. We deliberately do **not** install to `~/.claude/skills/` — that would
  leak every skill into every worker on the box. The registry (DB) stays the
  sole source of truth and gatekeeper.

  The `.claude/skills/` tree is added to the worktree's `.git/info/exclude` so a
  worker's `git add -A` can never sweep arbiter-injected skills into the task's
  commit (mirrors the `.mcp.json` handling).

  ## Advertisement (DECISION C)

  A materialized skill is only *listed* to a `--print` worker — it is a slash
  command, not an auto-injected system prompt (spike bd-5tc1s0). So the caller
  splices `prompt_section/1` into the worker prompt:

    * `:always_on`   skills → an explicit "you MUST use `/<name>`" directive.
    * `:situational` skills → advertised as available, invocation left to the
      agent's judgement.
  """

  alias Arbiter.MCP.AgentConfig
  alias Arbiter.Skills.Selection

  require Logger

  @skills_dir Path.join(".claude", "skills")

  @doc "The worktree-relative directory skills are materialized under (`.claude/skills`)."
  @spec skills_dir() :: String.t()
  def skills_dir, do: @skills_dir

  @doc """
  Write each resolved skill into `worktree` at `.claude/skills/<name>/SKILL.md`
  and exclude the tree from git. `resolved` is the list returned by
  `Arbiter.Skills.Selection.resolve/1`.

  Returns `{:ok, [written_name]}`. Best-effort per skill: a single write
  failure is logged and skipped rather than aborting the whole dispatch. An
  empty set is a no-op (`{:ok, []}`), and a `nil` worktree (a review / task-type
  dispatch with no isolated worktree) never touches the filesystem.
  """
  @spec materialize(Path.t() | nil, [Selection.resolved()]) :: {:ok, [String.t()]}
  def materialize(nil, _resolved), do: {:ok, []}
  def materialize(_worktree, []), do: {:ok, []}

  def materialize(worktree, resolved) when is_binary(worktree) and is_list(resolved) do
    written =
      resolved
      |> Enum.map(& &1.skill)
      |> Enum.flat_map(fn skill ->
        case write_skill(worktree, skill) do
          :ok ->
            [skill.name]

          {:error, reason} ->
            Logger.warning(
              "Arbiter.Skills.Materializer: failed to write skill #{inspect(skill.name)}: " <>
                inspect(reason)
            )

            []
        end
      end)

    # Keep arbiter-injected skills out of the worker's commits regardless of the
    # target repo's tracked .gitignore. Best-effort — never blocks a dispatch.
    if written != [] do
      _ = AgentConfig.add_to_git_exclude(worktree, [@skills_dir <> "/"])
    end

    {:ok, written}
  end

  defp write_skill(worktree, skill) do
    dir = Path.join([worktree, @skills_dir, skill.name])

    with :ok <- File.mkdir_p(dir) do
      File.write(Path.join(dir, "SKILL.md"), skill.body)
    end
  end

  @doc """
  The worker-prompt section advertising the resolved skills, or `""` when the
  set is empty. always-on skills get an imperative "use `/<name>`" directive;
  situational skills are listed as available for the agent to invoke by
  judgement.
  """
  @spec prompt_section([Selection.resolved()]) :: String.t()
  def prompt_section([]), do: ""

  def prompt_section(resolved) when is_list(resolved) do
    always_on = Selection.always_on(resolved)
    situational = Selection.situational(resolved)

    [always_on_block(always_on), situational_block(situational)]
    |> Enum.reject(&(&1 == ""))
    |> Enum.join("\n")
    |> case do
      "" -> ""
      body -> "\n" <> body <> "\n"
    end
  end

  defp always_on_block([]), do: ""

  defp always_on_block(resolved) do
    directives =
      resolved
      |> Enum.map(fn %{skill: s} -> "  * `/#{s.name}`#{skill_desc(s)}" end)
      |> Enum.join("\n")

    """
    Required skills — you MUST use each of these for this task. Invoke it as a
    slash command at the point it applies (they are available in this worktree):
    #{directives}
    """
  end

  defp situational_block([]), do: ""

  defp situational_block(resolved) do
    listing =
      resolved
      |> Enum.map(fn %{skill: s} -> "  * `/#{s.name}`#{skill_desc(s)}" end)
      |> Enum.join("\n")

    """
    Available skills — invoke the relevant one via its slash command when it
    applies; skip any that don't. They are materialized in this worktree:
    #{listing}
    """
  end

  # A short description from the skill's metadata, if present, else "".
  defp skill_desc(%{metadata: %{"description" => desc}}) when is_binary(desc) and desc != "",
    do: " — " <> desc

  defp skill_desc(_), do: ""
end
