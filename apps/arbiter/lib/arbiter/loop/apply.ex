defmodule Arbiter.Loop.Apply do
  @moduledoc """
  Applying a queued loop proposal, as four named steps.

      validate/1     may this row be applied at all?
      side_effect/2  do the thing, through the same public domain API a
                     human would use
      persist/2      move the row to :applied
      notify/1       announce the state change

  `run/2` is those four in order, and is what `Arbiter.Loop.apply_pending/2`
  calls. They are public individually (bd-3b7svv) because this is the *only*
  code path that turns a proposal into a real change to a skill, a workspace's
  config, a task's difficulty, or a repo's `CLAUDE.md` — and the queue's
  no-auto-apply discipline is a property of `validate/1` specifically, which is
  worth asserting without also provisioning the write it guards.

  Two rules the ordering encodes, and that the split makes checkable:

    * **The side effect runs before the row is marked.** A failed apply leaves
      the proposal `:proposed`, so it can be retried once the gap is closed —
      it is never silently consumed.
    * **The change is attributed to the proposal, not to the operator.**
      `attribution/1` produces `loop:proposal:<id>`, so reading the target's
      version history shows exactly which queued proposal moved it. The
      operator rides along separately as the Ash actor on `persist/2`.
  """

  alias Arbiter.Loop
  alias Arbiter.Loop.Apply.{Payload, RepoDoc}
  alias Arbiter.Loop.{Notify, PendingWrite}
  alias Arbiter.Tasks.{Issue, Workspace}

  @type error :: {:error, {:not_applicable | :unmapped | :invalid, String.t()}}

  @doc """
  The whole apply pipeline: validate, apply the side effect, persist, notify.

  Stops at the first step that fails, and never marks the row unless the side
  effect actually landed.
  """
  @spec run(PendingWrite.t(), String.t()) :: {:ok, PendingWrite.t()} | error()
  def run(%PendingWrite{} = row, operator) do
    with :ok <- validate(row),
         :ok <- side_effect(row, attribution(row)),
         {:ok, applied} <- persist(row, operator) do
      notify(applied)
      {:ok, applied}
    end
  end

  # ---- step 1: validation --------------------------------------------------

  @doc """
  Whether `row` is in a state an operator may apply — `:proposed` only.

  This is the evidence bar's teeth: a `:hypothesis` is refused here, with its
  current evidence count and the shortfall named, and nothing downstream runs.
  """
  @spec validate(PendingWrite.t()) :: :ok | {:error, {:not_applicable, String.t()}}
  def validate(%PendingWrite{} = row) do
    case Loop.inapplicable_reason(row) do
      nil -> :ok
      reason -> {:error, {:not_applicable, reason}}
    end
  end

  @doc """
  The PaperTrail attribution for changes this proposal makes:
  `loop:proposal:<id>`.
  """
  @spec attribution(PendingWrite.t()) :: String.t()
  def attribution(%PendingWrite{id: id}), do: "loop:proposal:#{id}"

  # ---- step 2: side effect -------------------------------------------------

  @doc """
  Apply the change `row.kind` describes, through the existing public domain
  API — never a direct table write — so it lands as a normal PaperTrail
  version attributed to `attribution`.

  Returns `:ok`, `{:error, {:unmapped, msg}}` when the proposal cannot be
  applied as written, or `{:error, {:invalid, msg}}` when the domain refused
  the write. Does not touch `row` itself; that is `persist/2`.
  """
  @spec side_effect(PendingWrite.t(), String.t()) :: :ok | error()
  def side_effect(%PendingWrite{kind: :difficulty_override, payload: payload}, attribution) do
    with {:ok, task_id} <- Payload.string(payload, "task_id"),
         {:ok, difficulty} <- Payload.integer(payload, "difficulty"),
         {:ok, issue} <- fetch_issue(task_id) do
      # `change_origin` is the Issue-side attribution hook: it lands in the
      # version row's `version_action_inputs`, since Issue has no `actor`
      # column to snapshot the way Skill / Workspace do.
      issue
      |> Ash.update(%{difficulty: difficulty, change_origin: attribution},
        action: :update,
        actor: attribution
      )
      |> ok_or_invalid()
    end
  end

  # The skill is fetched *before* the attrs are built, because a clause-carrying
  # payload (bd-5w8h0r) is resolved against the skill's current body — the
  # splice happens here, at apply time, not when the proposal was authored.
  def side_effect(%PendingWrite{kind: :skill_patch, payload: payload}, attribution) do
    with {:ok, ref} <- Payload.string(payload, "skill", Payload.skill_gap_message()),
         {:ok, skill} <- fetch_skill(ref),
         {:ok, attrs} <- Payload.skill_attrs(payload, skill.body) do
      case Arbiter.Skills.update_skill(skill, attrs, actor: attribution) do
        {:ok, _} -> :ok
        {:error, err} -> {:error, {:invalid, ash_message(err)}}
      end
    end
  end

  def side_effect(%PendingWrite{kind: :skill_create, payload: payload}, attribution) do
    with {:ok, name} <- Payload.string(payload, "name"),
         {:ok, body} <- Payload.string(payload, "body") do
      # bd-blxwla: the loop authored this row, full stop — not something the
      # payload gets a say in, so `managed_by: :loop` is forced here rather
      # than read from `payload`.
      %{name: name, body: body, managed_by: :loop}
      |> Payload.maybe_put(:metadata, Map.get(payload, "metadata"))
      |> Payload.maybe_put(:workspace_id, Map.get(payload, "workspace_id"))
      |> Arbiter.Skills.create_skill(actor: attribution)
      |> ok_or_invalid()
    end
  end

  # Invariant 4: config changes go through the deep-merge `:patch_config`
  # action, never a raw overwrite of `config`.
  def side_effect(%PendingWrite{kind: :config_set} = row, attribution) do
    payload = row.payload

    with {:ok, ws_id} <- Payload.workspace_id(payload, row.workspace_id),
         {:ok, patch} <- Payload.map(payload, "patch"),
         {:ok, ws} <- fetch_workspace(ws_id) do
      unset = Map.get(payload, "unset_paths") || []

      ws
      |> Ash.update(%{patch: patch, unset_paths: unset},
        action: :patch_config,
        actor: attribution
      )
      |> ok_or_invalid()
    end
  end

  # Rung 2 of the destination ladder (Amendment D) — see `Loop.Apply.RepoDoc`
  # for the worktree/commit/PR mechanics this hands off to.
  def side_effect(%PendingWrite{kind: :repo_doc_patch} = row, attribution) do
    payload = row.payload

    with {:ok, repo} <- RepoDoc.repo(row),
         {:ok, lesson} <- Payload.string(payload, "lesson"),
         {:ok, ws_id} <- Payload.workspace_id(payload, row.workspace_id),
         {:ok, ws} <- fetch_workspace(ws_id) do
      RepoDoc.run(row, ws, repo, lesson, attribution)
    end
  end

  # ---- step 3: persistence -------------------------------------------------

  @doc """
  Move `row` to `:applied` and stamp `applied_at`, attributed to `operator`.

  Persistence only — it runs no side effect, so calling it without one would
  mark a proposal that never landed. `run/2` is what orders the two.
  """
  @spec persist(PendingWrite.t(), String.t()) :: {:ok, PendingWrite.t()} | {:error, term()}
  def persist(%PendingWrite{} = row, operator) do
    Ash.update(row, %{state: :applied, actor: operator},
      action: :mark_applied,
      actor: operator
    )
  end

  # ---- step 4: notification ------------------------------------------------

  @doc "Announce the applied row to the dashboard and the `/events` stream."
  @spec notify(PendingWrite.t()) :: :ok
  def notify(%PendingWrite{} = applied) do
    _ = Notify.announce(applied, :applied)
    :ok
  end

  # ---- shared --------------------------------------------------------------

  defp ok_or_invalid({:ok, _}), do: :ok
  defp ok_or_invalid({:error, err}), do: {:error, {:invalid, ash_message(err)}}

  defp fetch_issue(task_id) do
    case Ash.get(Issue, task_id) do
      {:ok, issue} -> {:ok, issue}
      _ -> {:error, {:unmapped, "no task #{task_id}"}}
    end
  end

  defp fetch_skill(ref) do
    case Arbiter.Skills.get_skill(ref) do
      {:ok, skill} -> {:ok, skill}
      {:error, :not_found} -> {:error, {:unmapped, "no skill named #{inspect(ref)}"}}
    end
  end

  defp fetch_workspace(ws_id) do
    case Ash.get(Workspace, ws_id) do
      {:ok, ws} -> {:ok, ws}
      _ -> {:error, {:unmapped, "no workspace #{ws_id}"}}
    end
  end

  defp ash_message(%Ash.Error.Invalid{errors: errors}),
    do: errors |> Enum.map_join("; ", &Exception.message/1)

  defp ash_message(err) when is_exception(err), do: Exception.message(err)
  defp ash_message(err), do: inspect(err)
end
