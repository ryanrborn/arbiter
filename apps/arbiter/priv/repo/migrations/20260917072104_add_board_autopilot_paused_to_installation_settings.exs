defmodule Arbiter.Repo.Migrations.AddBoardAutopilotPausedToInstallationSettings do
  @moduledoc """
  Adds the `Arbiter.Board.Autopilot` pause flag to `installation_settings`
  (bd-pgi97m), so it survives a server restart instead of always coming back
  paused.

  `board_autopilot_paused` is nullable and defaults to NULL, meaning "no
  persisted value — fall back to the `:arbiter, :board_autopilot, enabled:`
  application env, else paused" — an install that never pauses/resumes keeps
  today's behavior exactly. `board_autopilot_paused_at` /
  `board_autopilot_paused_by` record when and (where known) by what caller
  the flag was last changed, for `scheduler_status` and the dashboard.
  """

  use Ecto.Migration

  def up do
    alter table(:installation_settings) do
      add :board_autopilot_paused, :boolean
      add :board_autopilot_paused_at, :utc_datetime_usec
      add :board_autopilot_paused_by, :text
    end
  end

  def down do
    alter table(:installation_settings) do
      remove :board_autopilot_paused
      remove :board_autopilot_paused_at
      remove :board_autopilot_paused_by
    end
  end
end
