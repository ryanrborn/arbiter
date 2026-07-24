defmodule Arbiter.Repo.Migrations.AddSessionIdConfigDirToWorkerRuns do
  @moduledoc """
  Adds two columns to `worker_runs` (bd-au3xrq):

    - `session_id` — the Claude Code session id (== `CLAUDE_CODE_SESSION_ID` ==
      the on-disk session JSONL filename), captured once the run's session
      init event lands. Nullable.
    - `config_dir` — the effective `CLAUDE_CONFIG_DIR` the run spawned under
      (workers use an isolated dir, not `~/.claude`). Nullable.

  Together these root the on-disk session JSONL lookup
  (`<config_dir>/projects/<slug>/<session_id>.jsonl`) that
  `Arbiter.Usage.ClaudeSessionFile` uses to reconcile token usage the primary
  stdout path missed (agent killed/crashed before the terminal `result` event,
  or the node died mid-run).

  Idempotent: each column is added only if it is not already present, so the
  migration is safe to re-run and on fresh installs.
  """

  use Ecto.Migration

  def up do
    add_col("session_id", "TEXT")
    add_col("config_dir", "TEXT")
  end

  def down do
    drop_col("config_dir")
    drop_col("session_id")
  end

  defp add_col(name, type) do
    unless column_exists?(name) do
      execute("ALTER TABLE worker_runs ADD COLUMN #{name} #{type}")
    end
  end

  defp drop_col(name) do
    if column_exists?(name) do
      execute("ALTER TABLE worker_runs DROP COLUMN #{name}")
    end
  end

  defp column_exists?(name) do
    %{rows: rows} = repo().query!("PRAGMA table_info(worker_runs)")
    name in Enum.map(rows, fn row -> Enum.at(row, 1) end)
  end
end
