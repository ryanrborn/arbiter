defmodule Arbiter.Worker.DevServerEnv do
  @moduledoc """
  Overrides `DATABASE_PATH` and `PORT` in worker child environments so a
  worker's own manual `mix phx.server` — started to visually/via-curl verify
  a rendering change per the verification-before-completion skill — never
  collides with the live coordinator-facing `arbiter.service` instance
  (bd-bzsqbu, bd-b49kqb).

  Every worker `Port.open` inherits the coordinator's own OS environment
  verbatim, including whatever `DATABASE_PATH`/`PORT` it was started with —
  there is no isolation today without this override. Without it, a
  worker-started dev server silently points at the live, shared database
  AND binds the coordinator's own HTTP port (`config/dev.exs` reads `PORT`,
  defaulting to 4848 — the same port `arbiter.service` uses). A worker
  hitting `EADDRINUSE` on 4848 and "freeing" the port has repeatedly killed
  the live coordinator (bd-b49kqb). `pairs/1` returns a task-scoped
  throwaway sqlite path and a task-scoped port so any dev server a worker
  starts inside its own worktree lands on both instead of colliding.

  Called from `Arbiter.Worker.ClaudeSession.env_pairs/2`, the same
  choke-point `Arbiter.Worker.ReleaseEnv` uses.
  """

  # Deliberately well above common ephemeral/dev-tool ranges. Deterministic
  # per task_id (via phash2) rather than random, so a resumed worker session
  # lands on the same port as its prior attempt. Collision between two
  # concurrently-dispatched tasks is possible but unlikely (10k-wide range)
  # and low-stakes — this guards a manual verification aid, not a hard
  # multi-tenancy boundary.
  @port_range_base 20_000
  @port_range_size 10_000

  @doc """
  Returns `{"DATABASE_PATH", scoped_path}` and `{"PORT", scoped_port}` pairs
  scoped to `task_id`. Returns `[]` when `task_id` isn't a non-empty string
  (no task context to scope to).
  """
  @spec pairs(String.t() | nil) :: [{String.t(), String.t()}]
  def pairs(task_id) when is_binary(task_id) and task_id != "" do
    db_path = Path.join(System.tmp_dir!(), "arbiter_worker_verify_#{task_id}.sqlite3")
    port = @port_range_base + :erlang.phash2(task_id, @port_range_size)

    [{"DATABASE_PATH", db_path}, {"PORT", Integer.to_string(port)}]
  end

  def pairs(_), do: []
end
