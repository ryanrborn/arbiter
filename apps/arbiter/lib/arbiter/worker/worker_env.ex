defmodule Arbiter.Worker.WorkerEnv do
  @moduledoc """
  Injects a workspace's user-defined env vars into worker subprocess
  environments, and surfaces the secret-flagged values that must be redacted
  from worker output.

  A workspace can define named env vars (an API token a test suite needs, a
  config value, …) via `Arbiter.Tasks.Workspace`'s `worker_env` argument. Every
  worker dispatched under that workspace gets them in its child environment.
  Per-key a value may be flagged `secret`, in which case it is masked in the UI
  and redacted (`Arbiter.Redaction`) anywhere worker output reaches a human.

  This module is the read side of that store, keyed by **task id** — the only
  workspace handle `Arbiter.Worker.ClaudeSession.env_pairs/3` has at spawn time.
  It mirrors the shape of the sibling env sources it sits beside in that
  pipeline (`Arbiter.Worker.ReleaseEnv.clean_pairs/0`,
  `Arbiter.Worker.DevServerEnv.pairs/1`).

  ## Override order

  Wired into `env_pairs/3` as:

      release_clean ++ dev_server_clean ++ worker_env ++ caller_env ++ [ARB_WORKER_BEAD_ID]

  User vars sit **after** the release/dev-server cleanups (so a user could
  intentionally override `DATABASE_PATH`, at their own risk) but **before** the
  caller-explicit `:env` — the agent's own auth (`ANTHROPIC_API_KEY`,
  `CLAUDE_CONFIG_DIR`, …) and the always-last `ARB_WORKER_BEAD_ID` guard always
  win, so a user env var can never break the agent's ability to authenticate or
  the task-id self-recursion guard.
  """

  require Logger

  alias Arbiter.Tasks.Issue
  alias Arbiter.Tasks.Workspace
  alias Arbiter.Worker.ReviewGate

  @doc """
  Resolves both halves of the store for `task_id` from a **single** workspace
  load: `{pairs, secret_values}`.

  A spawn needs both — the pairs for the child's Port env, the secret values for
  the session's redaction list — and both derive from the same workspace, so
  `Arbiter.Worker.ClaudeSession.start/1` calls this once rather than paying two
  `Ash.get` round-trips per half.

  Returns `{[], []}` when `task_id` is not a non-empty string, the
  task/workspace can't be loaded, or no vars are configured — so the caller can
  splice the result in unconditionally.

  If the workspace resolves but its decrypted store is missing any key that
  `worker_env_meta` says should be configured — whether the store comes up
  entirely empty or just short some keys — that's a degradation rather than
  "nothing configured", and this logs a `Logger.warning` naming the task, the
  workspace, and the missing key(s), so the next occurrence is diagnosable
  from the log instead of a `/proc` inspection. A genuinely unconfigured
  workspace (empty `worker_env_meta`) never warns. If decryption itself raises
  (corrupt/undecryptable ciphertext), that is caught and logged too — this
  function never raises into a spawn.
  """
  @spec resolve(String.t() | nil) :: {[{String.t(), String.t()}], [String.t()]}
  def resolve(task_id) do
    case workspace_for(task_id) do
      %Workspace{} = ws ->
        pairs =
          try do
            ws |> Workspace.worker_env_map() |> Map.to_list()
          rescue
            error ->
              Logger.warning(
                "WorkerEnv: workspace #{ws.id} (#{ws.name}) has a worker env store that " <>
                  "raised while decrypting for task #{task_id}: #{Exception.format(:error, error)}"
              )

              []
          end

        secret_values =
          if pairs == [] do
            []
          else
            Workspace.worker_env_secret_values(ws)
          end

        warn_if_degraded(task_id, ws, pairs)
        {pairs, secret_values}

      nil ->
        {[], []}
    end
  end

  # Only a workspace with configured keys (non-empty `worker_env_meta`) but a
  # decrypted store that's missing some of them is a degradation worth a
  # warning — a workspace with nothing configured at all producing `[]` is the
  # expected, silent case. Compares by name set so a *partial* degradation
  # (some keys resolved, others didn't) is caught too, not just a total miss.
  defp warn_if_degraded(task_id, %Workspace{} = ws, pairs) do
    configured = ws |> Workspace.worker_env_keys() |> MapSet.new(& &1.name)
    resolved = MapSet.new(pairs, fn {name, _value} -> name end)

    case MapSet.difference(configured, resolved) |> MapSet.to_list() do
      [] ->
        :ok

      missing ->
        Logger.warning(
          "WorkerEnv: workspace #{ws.id} (#{ws.name}) has configured worker env key(s) " <>
            "#{Enum.join(missing, ", ")} that worker_env_map/1 did not decrypt for task " <>
            "#{task_id} — encrypted_worker_env may be NULL, unloaded, or empty"
        )
    end
  end

  @doc """
  Returns the workspace's user-defined env vars for `task_id` as decrypted
  `{name, value}` pairs, ready to append to a worker's Port env.

  Prefer `resolve/1` when you also need the secret values — this is the
  single-half convenience wrapper.
  """
  @spec pairs(String.t() | nil) :: [{String.t(), String.t()}]
  def pairs(task_id), do: task_id |> resolve() |> elem(0)

  @doc """
  Returns the values of the workspace's **secret-flagged** worker env vars for
  `task_id` — the strings `Arbiter.Redaction` must scrub from worker output.

  Prefer `resolve/1` when you also need the pairs.
  """
  @spec secret_values(String.t() | nil) :: [String.t()]
  def secret_values(task_id), do: task_id |> resolve() |> elem(1)

  @doc """
  Resolve the workspace backing a task id, or `nil` on any miss. Best-effort:
  a spawn must never crash because the env store couldn't be read.

  ReviewGate mints synthetic task ids for spawned reviewer/implementer/
  verifier workers (`<base>#review`, `#r<N>`, `#impl<N>`, `#v<N>`, `#t<N>`,
  or a chain of these) that are never real `Issue` ids on their own — so
  this normalizes back to the authoring task id via `ReviewGate.base_task_id/1`
  before looking it up. Without that, every synthetic-id worker would miss
  here and silently get no env vars and no redaction list.

  Public because `Arbiter.Worker.ClaudeSession` needs the same workspace to
  hand `Arbiter.Agents.Claude.ConfigDir` on the spawn path that builds its own
  env (bd-bw3466).
  """
  @spec workspace_for(String.t() | nil) :: Workspace.t() | nil
  def workspace_for(task_id) when is_binary(task_id) and task_id != "" do
    base = ReviewGate.base_task_id(task_id)

    case Ash.get(Issue, base) do
      {:ok, %Issue{workspace_id: ws_id}} when is_binary(ws_id) ->
        case Ash.get(Workspace, ws_id) do
          {:ok, %Workspace{} = ws} ->
            ws

          {:error, error} ->
            Logger.warning(
              "WorkerEnv: Issue #{base} (from task #{task_id}) has workspace_id #{ws_id} " <>
                "but its workspace failed to load: #{inspect(error)}"
            )

            nil
        end

      {:ok, %Issue{}} ->
        Logger.debug("WorkerEnv: Issue #{base} (from task #{task_id}) has no workspace_id")

        nil

      {:error, error} ->
        Logger.debug(
          "WorkerEnv: could not load Issue #{base} (from task #{task_id}): #{inspect(error)}"
        )

        nil
    end
  end

  def workspace_for(_), do: nil
end
