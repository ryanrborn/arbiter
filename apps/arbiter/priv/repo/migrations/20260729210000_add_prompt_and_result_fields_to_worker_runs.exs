defmodule Arbiter.Repo.Migrations.AddPromptAndResultFieldsToWorkerRuns do
  @moduledoc """
  Adds prompt/result persistence columns to `worker_runs` (bd-9rdwe4, #1017
  gap G5): nothing recorded what an agent was told or how its run actually
  terminated beyond a bare exit code.

    - `prompt_sha256`   — SHA-256 hex of the redacted composed prompt
                          persisted to `<output_log_root>/<run_id>.prompt`
                          (`Arbiter.Worker.PromptLog`), so identical prompts
                          are comparable without fetching the file.
    - `result_subtype`  — the terminal stream-json `result` event's
                          `subtype` (e.g. "success" / "error_max_turns" /
                          "error_during_execution") — the CLI's own
                          outcome/verdict, distinct from the subprocess
                          `exit_code`.
    - `result_is_error` — the terminal event's `is_error` flag.
    - `result_message`  — the terminal event's final assistant-facing text
                          (redacted the same as transcript lines), truncated
                          to 20,000 chars.

  All nullable; a run whose session never reached a terminal `result` event
  (crashed, non-Claude provider, workflow-mode worker) simply has these nil —
  graceful degradation, matching every other best-effort Run write.
  """

  use Ecto.Migration

  def up do
    alter table(:worker_runs) do
      add(:prompt_sha256, :text)
      add(:result_subtype, :text)
      add(:result_is_error, :boolean)
      add(:result_message, :text)
    end
  end

  def down do
    alter table(:worker_runs) do
      remove(:result_message)
      remove(:result_is_error)
      remove(:result_subtype)
      remove(:prompt_sha256)
    end
  end
end
