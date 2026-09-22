defmodule Arbiter.Repo.Migrations.AccountMaxConcurrentOptIn do
  @moduledoc """
  Phase P8 of `docs/provider-account-design.md` (§4.4, bd-1k6pgv): the account
  concurrency ceiling is **opt-in**.

  `provider_accounts.max_concurrent` was created nullable by P1
  (`20260913074116_create_provider_accounts`) and nothing has written it since,
  so this migration is mostly a statement of intent — it resets the column to
  `NULL` for every existing account and prints one advisory line per account.
  The reset is deliberate rather than redundant: §4.4 is explicit that this
  install upgrades with *today's behaviour, bit-for-bit*, and a row that
  arrived with a number (a hand-edited DB, a restored backup, a future
  extraction pass that guessed) would otherwise silently cut fleet throughput
  on the day of the upgrade.

  Deriving the number instead was rejected in both directions (§4.4):
  `max(4, 4, 4) = 4` cuts a three-workspace install's throughput by 3×, and
  `sum = 12` enshrines the broken status quo — `graphs × workspaces ×
  max_concurrent` — as an explicit setting. So the migration reports the sum
  and lets the operator pick.

  The quota *hold* is account-wide immediately, with no opt-in (P7). The
  asymmetry is deliberate: an account-wide ceiling can reduce throughput below
  what an operator intended, but an account-wide hold can only ever stop
  dispatch against a budget that is already exhausted.

  ## `down/0` is a no-op

  There is nothing to restore. Every value this migration overwrites was
  already `NULL` on any install that reached here through the migration chain,
  and a ceiling an operator sets *after* the upgrade is theirs to keep — a
  rollback that re-derived numbers would invent the exact setting §4.4 refuses
  to invent.
  """

  use Ecto.Migration

  # The Conductor's own fallback when a workspace sets no `max_concurrent`
  # (`Arbiter.Workflows.Conductor`'s `@default_system_max`). Duplicated rather
  # than referenced: a migration must keep reporting the number that was true
  # when it ran, not follow a constant that moves later.
  @default_system_max 16

  def up do
    advise()

    # Raw `repo().query!` rather than `execute/1` throughout: `execute/1` is
    # queued and flushed at the end of `up/0`, which would run the reset
    # *after* the advisory reads the column it is reporting on.
    repo().query!("UPDATE provider_accounts SET max_concurrent = NULL")
  end

  def down, do: :ok

  defp advise do
    system_max =
      Application.get_env(:arbiter, :conductor_system_max_concurrent, @default_system_max)

    rows = repo().query!("SELECT provider, slug, id FROM provider_accounts ORDER BY slug").rows

    # `provider:slug`, not the bare slug §4.4's example uses. Every install
    # that has been through `Arbiter.Accounts.Resolver.ensure_account_id/2`
    # holds one `default` account *per provider*, and `arb account set default`
    # is rejected as ambiguous against more than one — an advisory that prints
    # a command the operator cannot run is worse than no advisory.
    for [provider, slug, id] <- rows do
      caps = workspace_caps(id, system_max)
      ref = "#{provider}:#{slug}"

      IO.puts(
        "[account_max_concurrent_opt_in] account `#{ref}` is referenced by " <>
          "#{length(caps)} workspaces whose caps total #{Enum.sum(caps)} concurrent workers; " <>
          "consider `arb account set #{ref} --max-concurrent N`."
      )
    end
  end

  # Every workspace metered under this account, as the concurrency cap it runs
  # at today: its own `conductor.max_concurrent` when set, else the
  # install-wide ceiling it actually inherits.
  defp workspace_caps(account_id, system_max) do
    %{rows: rows} =
      repo().query!(
        """
        SELECT w.config
          FROM workspace_provider_accounts wpa
          JOIN workspaces w ON w.id = wpa.workspace_id
         WHERE wpa.provider_account_id = ?1
        """,
        [account_id]
      )

    Enum.map(rows, fn [config] -> workspace_cap(config) || system_max end)
  end

  # Mirrors `Arbiter.Tasks.Workspace.max_concurrent/1`, including its string
  # clause: `conductor.max_concurrent` is written through a JSON config blob
  # and arrives as `"4"` rather than `4` on a live install, so an
  # integer-only match silently reports `system_max` for a workspace that is
  # in fact capped.
  defp workspace_cap(config) when is_binary(config) do
    case Jason.decode(config) do
      {:ok, decoded} -> cap_value(get_in(decoded, ["conductor", "max_concurrent"]))
      _ -> nil
    end
  end

  defp workspace_cap(_config), do: nil

  defp cap_value(n) when is_integer(n) and n > 0, do: n

  defp cap_value(s) when is_binary(s) do
    case Integer.parse(s) do
      {n, ""} when n > 0 -> n
      _ -> nil
    end
  end

  defp cap_value(_), do: nil
end
