defmodule Arbiter.Usage.ProviderAccountBackfill do
  @moduledoc """
  P9 (`docs/provider-account-design.md` §8, bd-al9qqe): one-time backfill of
  `usage_events.provider_account_id` from `workspace_provider_accounts`, run
  from the migration that adds the column
  (`priv/repo/migrations/20260921130000_*.exs`).

  A row is backfilled when it has a `workspace_id` and that workspace has a
  `workspace_provider_accounts` link for the row's `provider`. Everything
  else (no workspace, or a workspace linked to a different/no account for
  that provider) is left `NULL` and counted unresolved — the same shape as
  `Arbiter.Usage.WorkspaceBackfill`.

  ## Known limitation: mid-history account changes

  `workspace_provider_accounts` stores the workspace's **current** account per
  provider, not a history of it. If an operator re-points a workspace at a
  different account (`arb account attach`, or a merge re-pointing the link),
  this backfill has no way to tell which account was current for an *older*
  row — every historical row for that workspace/provider gets stamped with
  whatever account the link points to **now**, including rows that predate
  the change. §8 calls this out explicitly ("exact for any period in which a
  workspace's account for that provider did not change — trivially true
  pre-migration, since accounts did not exist") and does not ask this ticket
  to solve it; `provider_account_backfill_test.exs` documents the limitation
  rather than fixing it.

  Plain SQL rather than Ash/Ecto.Query, for the same reason as
  `Arbiter.Usage.WorkspaceBackfill`: this runs from inside an
  `Ecto.Migration`, where only the repo is guaranteed started.

  `usage_events.provider` stores the agent-type alias a spawn ran under
  (`"anthropic"`, `"openai"`, `"gemini"` — `Arbiter.Quota.provider_code/1`),
  not always the canonical `provider_accounts.provider` code
  (`"claude"`, `"codex"`, `"gemini_cli"` / `"antigravity"`). The join below
  matches both the literal code and the known aliases so historical alias
  rows are not left unresolved; a `"gemini"` row matches either concrete
  Gemini surface, since the alias does not distinguish which CLI ran it.
  """

  alias Arbiter.Repo

  @type report :: %{
          before: non_neg_integer(),
          backfilled: non_neg_integer(),
          unresolved: non_neg_integer()
        }

  @doc "Backfill `usage_events.provider_account_id`. Returns a before/after report."
  @spec run() :: report()
  def run do
    before_count = null_count()

    %{num_rows: updated} =
      Repo.query!(
        """
        UPDATE usage_events
        SET provider_account_id = (
          SELECT wpa.provider_account_id
          FROM workspace_provider_accounts wpa
          WHERE wpa.workspace_id = usage_events.workspace_id
            AND (
              wpa.provider = usage_events.provider
              OR (usage_events.provider = 'anthropic' AND wpa.provider = 'claude')
              OR (usage_events.provider = 'openai' AND wpa.provider = 'codex')
              OR (usage_events.provider = 'gemini' AND wpa.provider IN ('gemini_cli', 'antigravity'))
            )
        )
        WHERE provider_account_id IS NULL
          AND workspace_id IS NOT NULL
          AND provider IS NOT NULL
          AND EXISTS (
            SELECT 1 FROM workspace_provider_accounts wpa
            WHERE wpa.workspace_id = usage_events.workspace_id
              AND (
                wpa.provider = usage_events.provider
                OR (usage_events.provider = 'anthropic' AND wpa.provider = 'claude')
                OR (usage_events.provider = 'openai' AND wpa.provider = 'codex')
                OR (usage_events.provider = 'gemini' AND wpa.provider IN ('gemini_cli', 'antigravity'))
              )
          )
        """,
        []
      )

    after_count = null_count()

    %{before: before_count, backfilled: updated, unresolved: after_count}
  end

  defp null_count do
    %{rows: [[count]]} =
      Repo.query!("SELECT COUNT(*) FROM usage_events WHERE provider_account_id IS NULL", [])

    count
  end
end
