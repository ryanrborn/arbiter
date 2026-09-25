defmodule Arbiter.Accounts.ProviderSettingsTest do
  @moduledoc """
  bd-64apru: the per-role allowed-account sets on a workspace, their
  preference order and per-account concurrency share — and the effective
  resolution routing reads, including the `agent.type` / `review_agent.type`
  fallback when nothing is attached.
  """
  use Arbiter.DataCase, async: false

  require Ash.Query

  alias Arbiter.Accounts.{ProviderAccount, ProviderSettings, WorkspaceProviderAccount}
  alias Arbiter.Tasks.Workspace

  defp workspace!(config \\ %{}) do
    Ash.create!(Workspace, %{name: "ps-#{System.unique_integer([:positive])}", config: config})
  end

  defp account!(provider, slug, attrs \\ %{}) do
    Ash.create!(ProviderAccount, Map.merge(%{provider: provider, slug: slug}, attrs))
  end

  defp link!(ws, account, attrs \\ %{}) do
    Ash.create!(
      WorkspaceProviderAccount,
      Map.merge(
        %{workspace_id: ws.id, provider: account.provider, provider_account_id: account.id},
        attrs
      )
    )
  end

  defp slugs(%{candidates: candidates}), do: Enum.map(candidates, & &1.account.slug)
  defp types(%{candidates: candidates}), do: Enum.map(candidates, & &1.agent_type)

  defp reload(ws), do: Ash.get!(Workspace, ws.id)

  describe "effective/2 with nothing attached" do
    test "implementer falls back to the default claude when agent.type is unset" do
      ws = workspace!()

      resolved = ProviderSettings.effective(ws, :implementer)

      assert resolved.source == :default
      assert types(resolved) == ["claude"]
      assert [%{account: nil}] = resolved.candidates
    end

    test "implementer honours a hand-written agent.type list, in order" do
      ws = workspace!(%{"agent" => %{"type" => ["codex", "claude"]}})

      resolved = ProviderSettings.effective(ws, :implementer)

      assert resolved.source == :agent_type
      assert types(resolved) == ["codex", "claude"]
    end

    test "a fallback candidate names the account its provider is metered under" do
      ws = workspace!(%{"agent" => %{"type" => "claude"}})
      acct = account!(:claude, "ps-metered", %{max_concurrent: 4})
      link!(ws, acct, %{share: 2})

      assert %{source: :agent_type, candidates: [candidate]} =
               ProviderSettings.effective(ws, :implementer)

      assert candidate.account.id == acct.id
      assert candidate.share == 2
      assert candidate.ceiling == 4
      assert candidate.cap == 2
    end

    test "reviewer honours review_agent.type" do
      ws = workspace!(%{"agent" => %{"type" => "claude"}, "review_agent" => %{"type" => "codex"}})

      resolved = ProviderSettings.effective(ws, :reviewer)

      assert resolved.source == :review_agent_type
      assert types(resolved) == ["codex"]
    end

    test "reviewer falls back to the implementer's effective set" do
      ws = workspace!(%{"agent" => %{"type" => ["codex", "claude"]}})

      resolved = ProviderSettings.effective(ws, :reviewer)

      assert resolved.source == :implementer
      assert types(resolved) == ["codex", "claude"]
    end

    test "a linked account with no role does not become an allowed account" do
      ws = workspace!(%{"agent" => %{"type" => "claude"}})
      link!(ws, account!(:codex, "ps-metering-only"))

      assert %{source: :agent_type} = resolved = ProviderSettings.effective(ws, :implementer)
      assert types(resolved) == ["claude"]
    end
  end

  describe "add/3" do
    test "attaches an account to a role and resolves it as the effective set" do
      ws = workspace!()
      acct = account!(:codex, "ps-add")

      assert {:ok, ws} = ProviderSettings.add(ws, :implementer, acct.id)

      resolved = ProviderSettings.effective(ws, :implementer)
      assert resolved.source == :attached
      assert slugs(resolved) == ["ps-add"]

      # The reviewer role is independent — it still falls back.
      assert ProviderSettings.effective(ws, :reviewer).source == :implementer
    end

    test "appends in preference order and projects agent.type from it" do
      ws = workspace!(%{"agent" => %{"type" => "claude"}})
      codex = account!(:codex, "ps-order-codex")
      claude = account!(:claude, "ps-order-claude")

      {:ok, ws} = ProviderSettings.add(ws, :implementer, codex.id)
      assert reload(ws).config["agent"]["type"] == "codex"

      {:ok, ws} = ProviderSettings.add(ws, :implementer, claude.id)

      assert slugs(ProviderSettings.effective(ws, :implementer)) == [
               "ps-order-codex",
               "ps-order-claude"
             ]

      assert reload(ws).config["agent"]["type"] == ["codex", "claude"]
    end

    test "the reviewer role projects review_agent.type" do
      ws = workspace!()
      codex = account!(:codex, "ps-rev")

      {:ok, ws} = ProviderSettings.add(ws, :reviewer, codex.id)

      assert reload(ws).config["review_agent"]["type"] == "codex"
      assert slugs(ProviderSettings.effective(ws, :reviewer)) == ["ps-rev"]
    end

    test "reuses the existing link row for the same account (one row per provider)" do
      ws = workspace!()
      acct = account!(:claude, "ps-reuse")
      link!(ws, acct, %{share: 3})

      {:ok, ws} = ProviderSettings.add(ws, :implementer, acct.id)
      {:ok, ws} = ProviderSettings.add(ws, :reviewer, acct.id)

      assert [row] =
               WorkspaceProviderAccount
               |> Ash.Query.filter(workspace_id == ^ws.id)
               |> Ash.read!()

      assert row.share == 3
      assert row.implementer_position == 0
      assert row.reviewer_position == 0
    end

    test "re-points a role-less link to the chosen account" do
      ws = workspace!()
      old = account!(:claude, "ps-old")
      new = account!(:claude, "ps-new")
      link!(ws, old, %{share: 5})

      {:ok, ws} = ProviderSettings.add(ws, :implementer, new.id)

      assert slugs(ProviderSettings.effective(ws, :implementer)) == ["ps-new"]
      # The share was the old account's; it does not carry over.
      assert [%{share: nil}] = ProviderSettings.effective(ws, :implementer).candidates
    end

    test "refuses a second account for a provider another role already uses" do
      ws = workspace!()
      a = account!(:claude, "ps-taken-a")
      b = account!(:claude, "ps-taken-b")

      {:ok, ws} = ProviderSettings.add(ws, :reviewer, a.id)

      assert {:error, {:provider_taken, %ProviderAccount{id: id}}} =
               ProviderSettings.add(ws, :implementer, b.id)

      assert id == a.id
    end

    test "refuses a disabled or merged-away account" do
      ws = workspace!()
      survivor = account!(:claude, "ps-survivor")
      disabled = account!(:codex, "ps-disabled", %{enabled: false})
      merged = account!(:claude, "ps-merged", %{merged_into_id: survivor.id})

      assert {:error, :disabled} = ProviderSettings.add(ws, :implementer, disabled.id)
      assert {:error, {:merged_away, _}} = ProviderSettings.add(ws, :implementer, merged.id)
    end

    test "adding an account already in the role is a no-op" do
      ws = workspace!()
      acct = account!(:codex, "ps-dupe")

      {:ok, ws} = ProviderSettings.add(ws, :implementer, acct.id)
      {:ok, ws} = ProviderSettings.add(ws, :implementer, acct.id)

      assert slugs(ProviderSettings.effective(ws, :implementer)) == ["ps-dupe"]
    end
  end

  describe "move/4 and remove/3" do
    setup do
      ws = workspace!()
      codex = account!(:codex, "ps-mv-codex")
      claude = account!(:claude, "ps-mv-claude")
      {:ok, ws} = ProviderSettings.add(ws, :implementer, codex.id)
      {:ok, ws} = ProviderSettings.add(ws, :implementer, claude.id)
      %{ws: ws, codex: codex, claude: claude}
    end

    test "moves an account up the preference order", %{ws: ws, claude: claude} do
      {:ok, ws} = ProviderSettings.move(ws, :implementer, claude.id, :up)

      assert slugs(ProviderSettings.effective(ws, :implementer)) == [
               "ps-mv-claude",
               "ps-mv-codex"
             ]

      assert reload(ws).config["agent"]["type"] == ["claude", "codex"]
    end

    test "moving past either end is a no-op", %{ws: ws, codex: codex, claude: claude} do
      {:ok, ws} = ProviderSettings.move(ws, :implementer, codex.id, :up)
      {:ok, ws} = ProviderSettings.move(ws, :implementer, claude.id, :down)

      assert slugs(ProviderSettings.effective(ws, :implementer)) == [
               "ps-mv-codex",
               "ps-mv-claude"
             ]
    end

    test "removes an account from the role without detaching it", %{ws: ws, codex: codex} do
      {:ok, ws} = ProviderSettings.remove(ws, :implementer, codex.id)

      assert slugs(ProviderSettings.effective(ws, :implementer)) == ["ps-mv-claude"]
      assert reload(ws).config["agent"]["type"] == "claude"

      # The metering/credential link survives; only the role membership went.
      assert Arbiter.Accounts.Resolver.account_id(ws.id, :codex) == codex.id
    end

    test "removing the last account falls back to the (last projected) agent.type",
         %{ws: ws, codex: codex, claude: claude} do
      {:ok, ws} = ProviderSettings.remove(ws, :implementer, codex.id)
      {:ok, ws} = ProviderSettings.remove(ws, :implementer, claude.id)

      resolved = ProviderSettings.effective(ws, :implementer)
      assert resolved.source == :agent_type
      assert types(resolved) == ["claude"]
    end
  end

  describe "set_share/3" do
    test "writes and clears the workspace's share of an attached account" do
      ws = workspace!()
      acct = account!(:claude, "ps-share", %{max_concurrent: 4})
      {:ok, ws} = ProviderSettings.add(ws, :implementer, acct.id)

      assert {:ok, _} = ProviderSettings.set_share(ws, acct.id, 2)

      assert [%{share: 2, cap: 2, ceiling: 4}] =
               ProviderSettings.effective(ws, :implementer).candidates

      assert Arbiter.Accounts.Resolver.share(ws.id, :claude) == 2

      assert {:ok, _} = ProviderSettings.set_share(ws, acct.id, nil)
      assert [%{share: nil, cap: 4}] = ProviderSettings.effective(ws, :implementer).candidates
    end

    test "rejects a negative share and an unattached account" do
      ws = workspace!()
      acct = account!(:claude, "ps-share-bad")

      assert {:error, :not_attached} = ProviderSettings.set_share(ws, acct.id, 2)

      {:ok, ws} = ProviderSettings.add(ws, :implementer, acct.id)
      assert {:error, _} = ProviderSettings.set_share(ws, acct.id, -1)
    end
  end

  describe "adopt/2" do
    test "attaches the accounts the fallback config already resolves to, in order" do
      ws = workspace!(%{"agent" => %{"type" => ["codex", "claude"]}})
      codex = account!(:codex, "ps-adopt-codex")
      claude = account!(:claude, "ps-adopt-claude")
      link!(ws, claude)
      link!(ws, codex)

      {:ok, ws} = ProviderSettings.adopt(ws, :implementer)

      resolved = ProviderSettings.effective(ws, :implementer)
      assert resolved.source == :attached
      assert slugs(resolved) == ["ps-adopt-codex", "ps-adopt-claude"]
      assert reload(ws).config["agent"]["type"] == ["codex", "claude"]
    end

    test "is an error when no fallback candidate has an account" do
      ws = workspace!(%{"agent" => %{"type" => "claude"}})

      assert {:error, :nothing_to_adopt} = ProviderSettings.adopt(ws, :implementer)
    end
  end

  describe "agent_type/1" do
    test "maps each account provider onto the adapter that runs it" do
      assert ProviderSettings.agent_type(:claude) == "claude"
      assert ProviderSettings.agent_type(:codex) == "codex"
      assert ProviderSettings.agent_type(:gemini_cli) == "gemini"
      assert ProviderSettings.agent_type(:antigravity) == "gemini"
    end
  end
end
