defmodule Arbiter.Usage.ProviderAccountBackfillTest do
  @moduledoc """
  P9 (bd-al9qqe, `docs/provider-account-design.md` §8).
  """
  use Arbiter.DataCase, async: false

  alias Arbiter.Accounts.{ProviderAccount, WorkspaceProviderAccount}
  alias Arbiter.Tasks.Workspace
  alias Arbiter.Usage.{Event, ProviderAccountBackfill}

  defp workspace!(name), do: Ash.create!(Workspace, %{name: name})

  defp account!(provider, slug),
    do: Ash.create!(ProviderAccount, %{provider: provider, slug: slug})

  defp link!(ws, provider, account) do
    Ash.create!(WorkspaceProviderAccount, %{
      workspace_id: ws.id,
      provider: provider,
      provider_account_id: account.id
    })
  end

  defp insert_event!(extra) do
    attrs =
      Map.merge(
        %{repo: "arbiter", step: :work, occurred_at: DateTime.utc_now()},
        extra
      )

    {:ok, ev} = Ash.create(Event, attrs)
    ev
  end

  test "backfills a row from its workspace's linked account for that provider" do
    ws = workspace!("pab-a")
    account = account!(:claude, "pab-claude")
    link!(ws, :claude, account)

    ev = insert_event!(%{workspace_id: ws.id, provider: "claude"})
    assert ev.provider_account_id == nil

    report = ProviderAccountBackfill.run()
    assert report.backfilled >= 1

    assert Ash.get!(Event, ev.id).provider_account_id == account.id
  end

  test "does not cross providers — a workspace's codex account never backfills a claude row" do
    ws = workspace!("pab-b")
    codex = account!(:codex, "pab-codex")
    link!(ws, :codex, codex)

    ev = insert_event!(%{workspace_id: ws.id, provider: "claude"})

    ProviderAccountBackfill.run()

    assert Ash.get!(Event, ev.id).provider_account_id == nil
  end

  test "leaves a workspace-less row NULL and counts it unresolved" do
    ev = insert_event!(%{provider: "claude"})

    report = ProviderAccountBackfill.run()

    assert report.unresolved >= 1
    assert Ash.get!(Event, ev.id).provider_account_id == nil
  end

  test "does not touch a row that already carries a provider_account_id" do
    ws = workspace!("pab-c")
    account = account!(:claude, "pab-claude-2")
    other_account = account!(:claude, "pab-claude-other")
    link!(ws, :claude, account)

    ev =
      insert_event!(%{
        workspace_id: ws.id,
        provider: "claude",
        provider_account_id: other_account.id
      })

    ProviderAccountBackfill.run()

    assert Ash.get!(Event, ev.id).provider_account_id == other_account.id
  end

  # Documents the known limitation named in §8 and this module's moduledoc:
  # `workspace_provider_accounts` only stores the *current* link, so a
  # workspace whose account assignment changed mid-history backfills every
  # historical row — including ones from before the change — to whichever
  # account the link points at now. This is not a bug to fix here; it is the
  # explicit, accepted imprecision of an exact-only-pre-migration backfill.
  test "a workspace's account change mid-history is NOT reflected — every row lands on the current link" do
    ws = workspace!("pab-mid-history")
    old_account = account!(:claude, "pab-old")
    new_account = account!(:claude, "pab-new")

    link = link!(ws, :claude, old_account)

    old_row =
      insert_event!(%{
        workspace_id: ws.id,
        provider: "claude",
        occurred_at: DateTime.add(DateTime.utc_now(), -7, :day)
      })

    # The operator re-points the workspace at a new account (an `arb account
    # attach`-shaped edit) — the join row updates in place, with no trace of
    # what it used to point at.
    {:ok, _} = Ash.update(link, %{provider_account_id: new_account.id})

    new_row = insert_event!(%{workspace_id: ws.id, provider: "claude"})

    ProviderAccountBackfill.run()

    # Both rows land on `new_account` — the limitation, made concrete: the
    # pre-change row is silently mis-attributed rather than left NULL.
    assert Ash.get!(Event, old_row.id).provider_account_id == new_account.id
    assert Ash.get!(Event, new_row.id).provider_account_id == new_account.id
  end
end
