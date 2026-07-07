defmodule Arbiter.Repo.Migrations.AddOauthUsageToAnthropicQuotas do
  @moduledoc """
  Secondary Anthropic quota source columns (bd-8tpha6): per-model weekly
  utilization + extra_usage overage from `/api/oauth/usage`, fetched
  on-demand alongside the existing header-capture aggregate columns.
  """

  use Ecto.Migration

  def up do
    alter table(:anthropic_quotas) do
      add :per_model_utilization, :map, default: %{}
      add :extra_usage, :map, default: %{}
      add :oauth_utilization_5h, :float
      add :oauth_utilization_7d, :float
      add :oauth_captured_at, :utc_datetime
    end
  end

  def down do
    alter table(:anthropic_quotas) do
      remove :oauth_captured_at
      remove :oauth_utilization_7d
      remove :oauth_utilization_5h
      remove :extra_usage
      remove :per_model_utilization
    end
  end
end
