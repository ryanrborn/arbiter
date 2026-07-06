defmodule Arbiter.Skills.Selection do
  @moduledoc """
  Layered, dispatch-time resolution of the **effective skill set** for a worker
  (epic child 3, bd-d5hy7y).

  ## Layers

  Skills are selected by *layering*, resolved when a task is dispatched:

      workspace defaults → repo defaults → per-task override

  The effective set is the **union** of the applicable layers, with a per-task
  way to opt out (of one skill or all of them). An Elixir repo wants different
  skills than a Python one, hence the repo layer.

  Config for the workspace + repo layers lives in the workspace `config` map
  (set via the deep-merge `arb config` surface — never a raw PATCH):

      config["skills"]["workspace"]        # => ["tdd", "systematic-debugging"]
      config["skills"]["repos"]["server"]  # => %{"add" => ["elixir-tdd"], "remove" => ["tdd"]}

  A layer entry is either a bare skill name (string) or a map that overrides the
  skill's activation for that layer:

      "tdd"                                   # inherit the skill's own activation_mode
      %{"name" => "tdd", "activation" => "always_on"}

  The per-task layer is `Issue.skills` (see that attribute's docs): `opt_out` /
  `only` / `add` / `remove` / `activation`.

  ## Activation & DECISION C

  A materialized skill is only *listed* to a `--print` worker — it is a slash
  command, not an auto-injected system prompt (spike bd-5tc1s0). So each
  resolved skill carries an activation:

    * `:always_on`   → the dispatcher auto-invokes `/<name>` in the worker prompt.
    * `:situational` → the skill is advertised; invocation is left to the agent.

  Resolution precedence for a skill's activation: per-task override →
  per-layer override (repo beats workspace) → the skill's own `activation_mode`.

  ## Code-awareness (scoping refinement, Ryan 2026-07-06)

  Code-discipline skills (TDD, …) only make sense for **code-producing** work.
  A skill flagged `code_only` is dropped from the effective set entirely for a
  non-code-producing task (`decision`, `task`/spike, `epic`), so an always-on
  skill is never *forced* onto a task that emits no code. A doc-only `chore`
  that shouldn't carry TDD uses the per-task opt-out (`remove` / `opt_out`).
  """

  alias Arbiter.Skills
  alias Arbiter.Skills.Skill
  alias Arbiter.Tasks.Issue
  alias Arbiter.Tasks.Workspace

  @type resolved :: %{skill: Skill.t(), activation: :always_on | :situational}

  # Issue types whose dispatch produces a committed code change through the
  # review/merge path. `:decision`, `:task` (ops/research/spike), and `:epic`
  # emit no code, so `code_only` skills never attach to them.
  @code_producing_types ~w(feature bug chore)a

  @doc "The issue types treated as code-producing."
  @spec code_producing_types() :: [atom()]
  def code_producing_types, do: @code_producing_types

  @doc "Whether a task (or bare issue_type) is code-producing."
  @spec code_producing?(Issue.t() | atom()) :: boolean()
  def code_producing?(%Issue{issue_type: type}), do: type in @code_producing_types
  def code_producing?(type) when is_atom(type), do: type in @code_producing_types

  @doc """
  Resolve the effective skill set for a dispatch.

  Opts:

    * `:task`      — the `%Issue{}` being dispatched (required).
    * `:workspace` — the task's `%Workspace{}` or a raw config map. `nil` →
      no workspace/repo layers (task layer only).
    * `:repo`      — the resolved repo name, for the repo layer. `nil` → skip.
    * `:loader`    — test seam: `(name -> {:ok, %Skill{}} | {:error, _})`.
      Defaults to `Arbiter.Skills.get_skill_by_name/1`.

  Returns a list of `%{skill: %Skill{}, activation: :always_on | :situational}`
  in stable (resolution) order, de-duplicated by skill name. Unknown skill
  names (in config but not in the registry) are skipped.
  """
  @spec resolve(keyword()) :: [resolved()]
  def resolve(opts) do
    task = Keyword.fetch!(opts, :task)
    config = workspace_config(Keyword.get(opts, :workspace))
    repo = Keyword.get(opts, :repo)
    loader = Keyword.get(opts, :loader, &Skills.get_skill_by_name/1)

    {names, overrides} = effective_names(config, repo, task)

    names
    |> Enum.map(&load_resolved(&1, overrides, loader))
    |> Enum.reject(&is_nil/1)
    |> filter_code_awareness(task)
  end

  @doc "The `:always_on` subset of a resolved list, preserving order."
  @spec always_on([resolved()]) :: [resolved()]
  def always_on(resolved), do: Enum.filter(resolved, &(&1.activation == :always_on))

  @doc "The `:situational` subset of a resolved list, preserving order."
  @spec situational([resolved()]) :: [resolved()]
  def situational(resolved), do: Enum.filter(resolved, &(&1.activation == :situational))

  # ---- Name resolution across layers --------------------------------------

  # Returns `{ordered_unique_names, activation_overrides}` where overrides is a
  # name => activation-atom map (later layers win).
  defp effective_names(config, repo, task) do
    ws_entries = entry_list(get_in(config, ["skills", "workspace"]))
    {ws_names, ws_ov} = split_entries(ws_entries)

    {repo_names, repo_ov} = apply_repo_layer(ws_names, repo_layer(config, repo))

    overrides = Map.merge(ws_ov, repo_ov)

    apply_task_layer(repo_names, overrides, task_skills(task))
  end

  defp repo_layer(_config, nil), do: nil
  defp repo_layer(config, repo) when is_binary(repo), do: get_in(config, ["skills", "repos", repo])

  # The repo layer may be a bare list (all treated as additions) or a map with
  # "add"/"remove" (each an entry list). Removals are applied after additions.
  defp apply_repo_layer(names, nil), do: {names, %{}}

  defp apply_repo_layer(names, list) when is_list(list) do
    {add_names, ov} = split_entries(entry_list(list))
    {union(names, add_names), ov}
  end

  defp apply_repo_layer(names, %{} = layer) do
    {add_names, ov} = split_entries(entry_list(Map.get(layer, "add")))
    {remove_names, _} = split_entries(entry_list(Map.get(layer, "remove")))
    {difference(union(names, add_names), remove_names), ov}
  end

  defp apply_repo_layer(names, _), do: {names, %{}}

  # The per-task layer (Issue.skills map). Precedence within the task layer:
  #   opt_out → empties the set outright.
  #   only    → replaces the inherited set entirely.
  #   add/remove → adjust the inherited set.
  # A task "activation" map (name => "always_on"|"situational") wins over the
  # config-layer overrides.
  defp apply_task_layer(names, overrides, task_skills) when is_map(task_skills) do
    task_ov = Map.merge(overrides, activation_map(Map.get(task_skills, "activation")))

    cond do
      truthy?(Map.get(task_skills, "opt_out")) ->
        {[], task_ov}

      is_list(Map.get(task_skills, "only")) ->
        {only_names, only_ov} = split_entries(entry_list(Map.get(task_skills, "only")))
        {only_names, Map.merge(task_ov, only_ov)}

      true ->
        {add_names, add_ov} = split_entries(entry_list(Map.get(task_skills, "add")))
        {remove_names, _} = split_entries(entry_list(Map.get(task_skills, "remove")))
        {difference(union(names, add_names), remove_names), Map.merge(task_ov, add_ov)}
    end
  end

  defp apply_task_layer(names, overrides, _), do: {names, overrides}

  # ---- Entry normalization -------------------------------------------------

  # Normalize a raw config value into a list of entries (each a string or map).
  defp entry_list(nil), do: []
  defp entry_list(list) when is_list(list), do: list
  defp entry_list(one), do: [one]

  # Split a list of entries into `{ordered_unique_names, activation_overrides}`.
  defp split_entries(entries) do
    entries
    |> Enum.reduce({[], %{}}, fn entry, {names, ov} ->
      case entry_name(entry) do
        nil ->
          {names, ov}

        name ->
          ov =
            case entry_activation(entry) do
              nil -> ov
              act -> Map.put(ov, name, act)
            end

          {[name | names], ov}
      end
    end)
    |> then(fn {names, ov} -> {names |> Enum.reverse() |> Enum.uniq(), ov} end)
  end

  defp entry_name(name) when is_binary(name) do
    case String.trim(name) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp entry_name(%{"name" => name}), do: entry_name(name)
  defp entry_name(%{name: name}), do: entry_name(name)
  defp entry_name(_), do: nil

  defp entry_activation(%{"activation" => act}), do: parse_activation(act)
  defp entry_activation(%{activation: act}), do: parse_activation(act)
  defp entry_activation(_), do: nil

  defp parse_activation(act) when act in [:always_on, :situational], do: act
  defp parse_activation("always_on"), do: :always_on
  defp parse_activation("situational"), do: :situational
  defp parse_activation(_), do: nil

  # A task "activation" override map ("name" => "always_on"|"situational").
  defp activation_map(%{} = map) do
    Enum.reduce(map, %{}, fn {name, act}, acc ->
      case {entry_name(name), parse_activation(act)} do
        {n, a} when is_binary(n) and not is_nil(a) -> Map.put(acc, n, a)
        _ -> acc
      end
    end)
  end

  defp activation_map(_), do: %{}

  # ---- Loading + code-awareness -------------------------------------------

  defp load_resolved(name, overrides, loader) do
    case loader.(name) do
      {:ok, %Skill{} = skill} ->
        %{skill: skill, activation: Map.get(overrides, name, skill.activation_mode)}

      _ ->
        require Logger

        Logger.debug(
          "Arbiter.Skills.Selection: skill #{inspect(name)} selected but not in registry; skipping"
        )

        nil
    end
  end

  # On a non-code-producing task, drop `code_only` skills entirely so an
  # always-on code-discipline skill (TDD) is never forced onto a decision /
  # spike / epic. Code tasks keep the full set.
  defp filter_code_awareness(resolved, %Issue{} = task) do
    if code_producing?(task) do
      resolved
    else
      Enum.reject(resolved, & &1.skill.code_only)
    end
  end

  # ---- Small set helpers (order-preserving) --------------------------------

  defp union(a, b), do: (a ++ b) |> Enum.uniq()
  defp difference(a, b), do: Enum.reject(a, &(&1 in b))

  defp truthy?(true), do: true
  defp truthy?("true"), do: true
  defp truthy?(_), do: false

  defp workspace_config(%Workspace{config: %{} = config}), do: config
  defp workspace_config(%Workspace{}), do: %{}
  defp workspace_config(%{} = config), do: config
  defp workspace_config(_), do: %{}

  defp task_skills(%Issue{skills: %{} = skills}), do: skills
  defp task_skills(_), do: %{}
end
