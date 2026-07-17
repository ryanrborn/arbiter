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

      release_clean ++ dev_server_clean ++ worker_env ++ caller_env ++ [ARB_ACOLYTE_BEAD_ID]

  User vars sit **after** the release/dev-server cleanups (so a user could
  intentionally override `DATABASE_PATH`, at their own risk) but **before** the
  caller-explicit `:env` — the agent's own auth (`ANTHROPIC_API_KEY`,
  `CLAUDE_CONFIG_DIR`, …) and the always-last `ARB_ACOLYTE_BEAD_ID` guard always
  win, so a user env var can never break the agent's ability to authenticate or
  the bead-id self-recursion guard.
  """

  alias Arbiter.Tasks.Issue
  alias Arbiter.Tasks.Workspace

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
  """
  @spec resolve(String.t() | nil) :: {[{String.t(), String.t()}], [String.t()]}
  def resolve(task_id) do
    case workspace_for(task_id) do
      %Workspace{} = ws ->
        {ws |> Workspace.worker_env_map() |> Map.to_list(),
         Workspace.worker_env_secret_values(ws)}

      nil ->
        {[], []}
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

  # Resolve the workspace backing a task id, or nil on any miss. Best-effort:
  # a spawn must never crash because the env store couldn't be read.
  defp workspace_for(task_id) when is_binary(task_id) and task_id != "" do
    with {:ok, %Issue{workspace_id: ws_id}} when is_binary(ws_id) <- Ash.get(Issue, task_id),
         {:ok, %Workspace{} = ws} <- Ash.get(Workspace, ws_id) do
      ws
    else
      _ -> nil
    end
  end

  defp workspace_for(_), do: nil
end
