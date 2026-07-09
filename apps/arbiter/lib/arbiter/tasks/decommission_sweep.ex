defmodule Arbiter.Tasks.DecommissionSweep do
  @moduledoc """
  One-time sweep to bulk-close tasks orphaned by the GT → arbiter
  cutover. The Dolt importer carried forward the entire `hq` and `server`
  workspaces, including tasks that are now obsolete (daemon role
  definitions, coordinator session handoffs, GT-specific bug reports,
  compaction reports, etc.).

  ## Patterns swept

  Categories (each becomes the closure reason):

    * **HANDOFF**: title starts with `🤝 HANDOFF` — old GT coordinator/witness
      session-handoff protocol artifacts.
    * **Daemon role definition**: `MergeQueue for X`, `Witness for X`,
      `Crew worker N in X`, `coordinator`/`deacon` titles. The GT identity
      tasks for daemon roles per repo.
    * **Worker identity**: task IDs matching `<prefix>-...-worker-...`.
    * **Workflow definition**: task IDs starting with `hq-wf-` or
      `vs-wfs-` — workflow step tasks from GT's "molecule" system.
    * **GT-system bug or task**: title mentions the old `gt`/`GT` tooling.
    * **Compaction report**: title starts with `Compaction Report`.
    * **Escalation reply**: title starts with `Re: ESCALATION` or
      `Re: REFINERY BLOCKED`.
    * **Patrol cycle note**: title contains `Patrol` (Deacon Patrol,
      Witness Patrol, MergeQueue Patrol).

  ## Keepers

  Tasks on the keep list are skipped even if they match a pattern:

    * `gte-026`, `gte-027`, `gte-028` — arbiter cutover process tasks,
      intentionally open during the 7-day rollback window.
    * `hq-109` — UUIDv7 regression test, may still apply to Ash.
    * `hq-3be` — VR-17575, a real outstanding Verus Server task with a
      Jira ticket.
    * `vs-sy5` — real Verus product bug.
  """

  alias Arbiter.Tasks.Issue
  require Ash.Query

  @keepers MapSet.new([
             "gte-026",
             "gte-027",
             "gte-028",
             "hq-109",
             "hq-3be",
             "vs-sy5"
           ])

  @typedoc "A proposed closure with the category that matched."
  @type proposal :: %{
          task_id: String.t(),
          category: String.t(),
          title: String.t(),
          current_status: atom()
        }

  @doc """
  Return the list of proposals — every open or in_progress task whose
  id/title matches one of the decommissioning patterns and which isn't
  on the keep list.
  """
  @spec proposals() :: [proposal()]
  def proposals do
    Issue
    |> Ash.Query.filter(status in [:open, :in_progress])
    |> Ash.read!()
    |> Enum.flat_map(&categorize/1)
    |> Enum.reject(&keeper?/1)
    |> Enum.sort_by(&{&1.category, &1.task_id})
  end

  @doc """
  Apply each proposal by closing the task. Returns `{closed, errors}`
  where `closed` is a list of task_ids and `errors` is a list of
  `{task_id, reason}` pairs.
  """
  @spec apply!([proposal()]) :: {[String.t()], [{String.t(), term()}]}
  def apply!(proposals) when is_list(proposals) do
    Enum.reduce(proposals, {[], []}, fn p, {ok, errs} ->
      reason = "Auto-closed by DecommissionSweep (#{p.category}; GT decommissioned 2026-05-20)"

      case close_task(p.task_id, reason) do
        :ok -> {[p.task_id | ok], errs}
        {:error, reason} -> {ok, [{p.task_id, reason} | errs]}
      end
    end)
    |> then(fn {ok, errs} -> {Enum.reverse(ok), Enum.reverse(errs)} end)
  end

  # ---- categorization ----

  @category_rules [
    {"HANDOFF", &__MODULE__.handoff?/1},
    {"Patrol cycle note", &__MODULE__.patrol_note?/1},
    {"Daemon role definition", &__MODULE__.daemon_role?/1},
    {"Worker identity", &__MODULE__.worker_identity?/1},
    {"Workflow definition", &__MODULE__.workflow_def?/1},
    {"GT-system bug or task", &__MODULE__.gt_system?/1},
    {"Compaction report", &__MODULE__.compaction_report?/1},
    {"Escalation reply", &__MODULE__.escalation_reply?/1}
  ]

  defp categorize(%Issue{} = issue) do
    Enum.find_value(@category_rules, [], fn {label, predicate} ->
      if predicate.(issue) do
        [
          %{
            task_id: issue.id,
            category: label,
            title: issue.title,
            current_status: issue.status
          }
        ]
      end
    end)
  end

  defp keeper?(%{task_id: id}), do: MapSet.member?(@keepers, id)

  # ---- predicates (public for compile-time capture) ----

  @doc false
  def handoff?(%Issue{title: t}) when is_binary(t), do: String.starts_with?(t, "🤝 HANDOFF")
  def handoff?(_), do: false

  @doc false
  def patrol_note?(%Issue{title: t}) when is_binary(t) do
    # Match e.g. "Deacon Patrol", "Witness Patrol", "MergeQueue Patrol" as
    # standalone or short titles. Avoid matching legitimate sentences that
    # happen to include "patrol".
    Regex.match?(~r/\b(Deacon|Witness|MergeQueue|Idle|Mayor)\s+Patrol\b/, t)
  end

  def patrol_note?(_), do: false

  @doc false
  def daemon_role?(%Issue{title: t}) when is_binary(t) do
    cond do
      String.starts_with?(t, "MergeQueue for ") -> true
      String.starts_with?(t, "Witness for ") -> true
      Regex.match?(~r/^Crew worker .* in /, t) -> true
      String.starts_with?(t, "Deacon (daemon beacon)") -> true
      String.starts_with?(t, "Coordinator - global coordinator") -> true
      true -> false
    end
  end

  def daemon_role?(_), do: false

  @doc false
  def worker_identity?(%Issue{id: id, title: t}) when is_binary(id) and is_binary(t) do
    # Task ID like `vs-server-worker-chrome` whose title duplicates the
    # ID — these are old GT worker identity records, not work items.
    Regex.match?(~r/-worker-/, id) and (id == t or t == "" or String.contains?(id, t))
  end

  def worker_identity?(_), do: false

  @doc false
  def workflow_def?(%Issue{id: id}) when is_binary(id) do
    String.starts_with?(id, "hq-wf-") or String.starts_with?(id, "vs-wfs-")
  end

  def workflow_def?(_), do: false

  @doc false
  def gt_system?(%Issue{title: t}) when is_binary(t) do
    # The decommissioned Go GT system mentioned in the title. Case
    # insensitive on the bare token "gt", but skip if it's clearly the
    # arbiter port (e.g. "arbiter", "gte-").
    cond do
      String.starts_with?(t, "GT worker ") -> true
      String.starts_with?(t, "GT: ") -> true
      Regex.match?(~r/^gt /, t) -> true
      Regex.match?(~r/^\[HIGH\] Dolt:/, t) -> true
      true -> false
    end
  end

  def gt_system?(_), do: false

  @doc false
  def compaction_report?(%Issue{title: t}) when is_binary(t) do
    String.starts_with?(t, "Compaction Report") or
      String.starts_with?(t, "compact report")
  end

  def compaction_report?(_), do: false

  @doc false
  def escalation_reply?(%Issue{title: t}) when is_binary(t) do
    String.starts_with?(t, "Re: ESCALATION") or String.starts_with?(t, "Re: REFINERY BLOCKED")
  end

  def escalation_reply?(_), do: false

  # ---- close ----

  defp close_task(task_id, reason) do
    with {:ok, task} <- Ash.get(Issue, task_id),
         {:ok, _} <- Ash.update(task, %{reason: reason}, action: :close) do
      :ok
    else
      {:error, err} -> {:error, err}
    end
  end
end
