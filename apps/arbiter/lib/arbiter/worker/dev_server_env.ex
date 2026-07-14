defmodule Arbiter.Worker.DevServerEnv do
  @moduledoc """
  Overrides `DATABASE_PATH` in worker child environments so a worker's own
  manual `mix phx.server` — started to visually/via-curl verify a rendering
  change per the verification-before-completion skill — never writes into
  the same sqlite file the live coordinator-facing `arbiter.service`
  instance uses (bd-bzsqbu).

  Every worker `Port.open` inherits the coordinator's own OS environment
  verbatim, including whatever `DATABASE_PATH` it was started with — there
  is no isolation today, so a worker-started dev server silently points at
  the live, shared database. `pairs/1` returns a task-scoped throwaway
  sqlite path override (mirrors config/test.exs's tmp-scoped test DB) so any
  dev server a worker starts inside its own worktree lands there instead.

  Called from `Arbiter.Worker.ClaudeSession.env_pairs/2`, the same
  choke-point `Arbiter.Worker.ReleaseEnv` uses.
  """

  @doc """
  Returns a single `{"DATABASE_PATH", scoped_path}` pair scoped to `task_id`.
  Returns `[]` when `task_id` isn't a non-empty string (no task context to
  scope the path to).
  """
  @spec pairs(String.t() | nil) :: [{String.t(), String.t()}]
  def pairs(task_id) when is_binary(task_id) and task_id != "" do
    path = Path.join(System.tmp_dir!(), "arbiter_worker_verify_#{task_id}.sqlite3")
    [{"DATABASE_PATH", path}]
  end

  def pairs(_), do: []
end
