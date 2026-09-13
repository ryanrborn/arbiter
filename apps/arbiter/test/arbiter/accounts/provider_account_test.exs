defmodule Arbiter.Accounts.ProviderAccountTest do
  use Arbiter.DataCase, async: true

  alias Arbiter.Accounts.ProviderAccount

  describe "create" do
    test "creates an account with defaults" do
      assert {:ok, account} =
               Ash.create(ProviderAccount, %{provider: :claude, slug: "personal-max"})

      assert account.provider == :claude
      assert account.slug == "personal-max"
      assert account.identity_source == :operator
      assert account.enabled == true
      assert account.max_concurrent == nil
      assert account.quota_config == %{}
      assert account.merged_into_id == nil
    end

    test "rejects a second account with the same provider + slug" do
      assert {:ok, _} = Ash.create(ProviderAccount, %{provider: :claude, slug: "dupe"})

      assert {:error, %Ash.Error.Invalid{}} =
               Ash.create(ProviderAccount, %{provider: :claude, slug: "dupe"})
    end

    test "allows the same slug across different providers" do
      assert {:ok, _} = Ash.create(ProviderAccount, %{provider: :claude, slug: "shared-name"})
      assert {:ok, _} = Ash.create(ProviderAccount, %{provider: :codex, slug: "shared-name"})
    end

    test "rejects an unknown provider" do
      assert {:error, %Ash.Error.Invalid{}} =
               Ash.create(ProviderAccount, %{provider: :bogus, slug: "x"})
    end
  end

  describe "update" do
    test "does not accept provider or slug changes" do
      assert {:ok, account} = Ash.create(ProviderAccount, %{provider: :claude, slug: "fixed"})

      assert {:ok, updated} =
               account
               |> Ash.Changeset.for_update(:update, %{label: "Personal Max"})
               |> Ash.update()

      assert updated.label == "Personal Max"
      assert updated.provider == :claude
      assert updated.slug == "fixed"
    end
  end
end
