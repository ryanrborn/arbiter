defmodule Arbiter.Repo.Migrations.AddCaptureSourceToAnthropicQuotas do
  @moduledoc """
  Provenance marker for the Anthropic quota row (bd-b0zody).

  Two sources now write the *same* primary columns — the proxy's
  `anthropic-ratelimit-unified-*` header capture ("headers") and the polled
  `/api/oauth/usage` snapshot ("oauth_poll"). During the overlap window (kept
  deliberately, so the two can be watched for agreement before the proxy is
  removed) the row is unreadable without knowing which one last wrote it, and
  `Arbiter.Quota.Gate` keys its staleness threshold off it.

  Legacy rows keep `NULL`, which reads as the header source.
  """

  use Ecto.Migration

  def up do
    alter table(:anthropic_quotas) do
      add :capture_source, :text
    end
  end

  def down do
    alter table(:anthropic_quotas) do
      remove :capture_source
    end
  end
end
