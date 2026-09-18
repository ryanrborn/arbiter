defmodule Arbiter.Repo.Migrations.AddThinkingTokensToUsageEvents do
  @moduledoc """
  Adds `thinking_tokens` to `usage_events` (bd-481sz7).

  agy/Antigravity's terminal `result.usage` carries a `thinking_tokens`
  bucket the stream parser used to drop entirely. Confirmed live:
  `input_tokens + output_tokens == total_tokens`, so thinking tokens are a
  subset already counted inside `output_tokens`, not additional spend — this
  column exists for visibility only, never added on top of `tokens_out`.
  """

  use Ecto.Migration

  def up do
    alter table(:usage_events) do
      add :thinking_tokens, :bigint
    end
  end

  def down do
    alter table(:usage_events) do
      remove :thinking_tokens
    end
  end
end
