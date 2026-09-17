defmodule Arbiter.Vault.RotationTest do
  # async: false — mutates the ARBITER_CLOAK_KEY* env vars and temporarily
  # pushes the resulting rotating cipher config onto the live, VM-global
  # Arbiter.Vault singleton to simulate a mid-rotation deploy, restoring
  # both on exit.
  use Arbiter.DataCase, async: false

  alias Arbiter.Accounts.{ProviderAccount, ProviderCredential}
  alias Arbiter.Tasks.Workspace
  alias Arbiter.Vault
  alias Arbiter.Vault.Rotation

  @config_table Module.concat(Vault, Config)

  setup do
    {:ok, live_config} = Cloak.Vault.read_config(@config_table)
    {_mod, live_default_opts} = live_config[:ciphers][:default]
    old_key = live_default_opts[:key]

    prev_key_env = System.get_env("ARBITER_CLOAK_KEY")
    prev_old_env = System.get_env("ARBITER_CLOAK_KEY_OLD")
    prev_gen_env = System.get_env("ARBITER_CLOAK_KEY_GENERATION")

    # Drive the same env vars a real rotation deploy sets, so the tags this
    # test exercises are exactly what Vault.current_tag/0 and
    # Vault.retired_tag/0 (which Arbiter.Vault.Rotation itself compares
    # against) independently compute — not hand-picked strings that happen
    # to agree with them.
    System.put_env("ARBITER_CLOAK_KEY", Base.encode64(:crypto.strong_rand_bytes(32)))
    System.put_env("ARBITER_CLOAK_KEY_OLD", Base.encode64(old_key))
    System.put_env("ARBITER_CLOAK_KEY_GENERATION", "2")

    {:ok, rotating_config} = Vault.init([])
    old_tag = Vault.retired_tag()
    new_tag = Vault.current_tag()

    # The config ETS table is owned by the Arbiter.Vault GenServer
    # (protected access), so it can only be written to from inside that
    # process — route the write through :sys.replace_state/2, which runs the
    # given function in the target process without touching its actual
    # GenServer state.
    save_vault_config(rotating_config)

    on_exit(fn ->
      save_vault_config(live_config)

      if prev_key_env,
        do: System.put_env("ARBITER_CLOAK_KEY", prev_key_env),
        else: System.delete_env("ARBITER_CLOAK_KEY")

      if prev_old_env,
        do: System.put_env("ARBITER_CLOAK_KEY_OLD", prev_old_env),
        else: System.delete_env("ARBITER_CLOAK_KEY_OLD")

      if prev_gen_env,
        do: System.put_env("ARBITER_CLOAK_KEY_GENERATION", prev_gen_env),
        else: System.delete_env("ARBITER_CLOAK_KEY_GENERATION")
    end)

    %{old_key: old_key, old_tag: old_tag, new_tag: new_tag}
  end

  defp save_vault_config(config) do
    :sys.replace_state(Vault, fn state ->
      Cloak.Vault.save_config(@config_table, config)
      state
    end)
  end

  defp encrypt_under_old_cipher(old_key, old_tag, term) do
    {:ok, ciphertext} =
      Cloak.Ciphers.AES.GCM.encrypt(:erlang.term_to_binary(term),
        tag: old_tag,
        key: old_key,
        iv_length: 12
      )

    Base.encode64(ciphertext)
  end

  defp write_raw_column!(table, column, id, value) do
    Ecto.Adapters.SQL.query!(
      Arbiter.Repo,
      "UPDATE #{table} SET #{column} = ?1 WHERE id = ?2",
      [value, id]
    )
  end

  defp read_raw_column!(table, column, id) do
    %{rows: [[raw]]} =
      Ecto.Adapters.SQL.query!(
        Arbiter.Repo,
        "SELECT #{column} FROM #{table} WHERE id = ?1",
        [id]
      )

    raw
  end

  defp tag_of(raw) do
    %{tag: tag} = raw |> Base.decode64!() |> Cloak.Tags.Decoder.decode()
    tag
  end

  defp find_report(reports, table, column) do
    Enum.find(reports, &(&1.table == table and &1.column == column))
  end

  describe "sweep!/0" do
    test "re-encrypts a workspace row written under the retired cipher", %{
      old_key: old_key,
      old_tag: old_tag,
      new_tag: new_tag
    } do
      {:ok, ws} = Ash.create(Workspace, %{name: "rot-ws-#{System.unique_integer([:positive])}"})

      old_ciphertext =
        encrypt_under_old_cipher(old_key, old_tag, %{"tracker_token" => "sct_rw_old"})

      write_raw_column!("workspaces", "encrypted_secrets", ws.id, old_ciphertext)
      assert tag_of(read_raw_column!("workspaces", "encrypted_secrets", ws.id)) == old_tag

      reports = Rotation.sweep!()
      report = find_report(reports, "workspaces", "encrypted_secrets")
      assert report.rotated >= 1

      raw = read_raw_column!("workspaces", "encrypted_secrets", ws.id)
      assert tag_of(raw) == new_tag

      {:ok, reloaded} = Ash.get(Workspace, ws.id)
      assert Workspace.secrets_map(reloaded) == %{"tracker_token" => "sct_rw_old"}
    end

    test "leaves an already-current row's ciphertext untouched (safe to re-run)", %{
      new_tag: new_tag
    } do
      {:ok, ws} =
        Ash.create(Workspace, %{
          name: "rot-ws-current-#{System.unique_integer([:positive])}",
          secrets: %{"a" => "b"}
        })

      assert tag_of(read_raw_column!("workspaces", "encrypted_secrets", ws.id)) == new_tag

      report =
        Rotation.sweep!()
        |> find_report("workspaces", "encrypted_secrets")

      assert report.already_current >= 1

      before = read_raw_column!("workspaces", "encrypted_secrets", ws.id)
      Rotation.sweep!()
      assert read_raw_column!("workspaces", "encrypted_secrets", ws.id) == before

      {:ok, reloaded} = Ash.get(Workspace, ws.id)
      assert Workspace.secrets_map(reloaded) == %{"a" => "b"}
    end

    test "sweeps ProviderCredential's encrypted_secret column too" do
      {:ok, account} =
        Ash.create(ProviderAccount, %{
          provider: :claude,
          slug: "rot-cred-#{System.unique_integer([:positive])}"
        })

      {:ok, credential} =
        Ash.create(ProviderCredential, %{
          provider_account_id: account.id,
          kind: :oauth_token,
          env_var: "CLAUDE_CODE_OAUTH_TOKEN",
          fingerprint: "fp-rot",
          secret: "sk-ant-oat01-rot"
        })

      report =
        Rotation.sweep!()
        |> find_report("provider_credentials", "encrypted_secret")

      assert report.already_current >= 1

      {:ok, reloaded} = Ash.get(ProviderCredential, credential.id)
      assert ProviderCredential.secret(reloaded) == "sk-ant-oat01-rot"
    end
  end

  describe "update_row!/5 compare-and-swap" do
    test "succeeds and writes when old_value still matches, no-ops otherwise" do
      {:ok, ws} =
        Ash.create(Workspace, %{
          name: "rot-cas-#{System.unique_integer([:positive])}",
          secrets: %{"a" => "b"}
        })

      original = read_raw_column!("workspaces", "encrypted_secrets", ws.id)

      assert Rotation.update_row!(
               "workspaces",
               "encrypted_secrets",
               ws.id,
               original,
               "new-value-a"
             ) == :rotated

      assert read_raw_column!("workspaces", "encrypted_secrets", ws.id) == "new-value-a"
    end

    test "reports :changed_under_us and leaves the row alone when a concurrent write landed first" do
      {:ok, ws} =
        Ash.create(Workspace, %{
          name: "rot-cas-race-#{System.unique_integer([:positive])}",
          secrets: %{"a" => "b"}
        })

      stale_snapshot = read_raw_column!("workspaces", "encrypted_secrets", ws.id)

      # Simulate a concurrent write (e.g. a live secrets update) landing
      # between the sweep's SELECT and its UPDATE.
      write_raw_column!("workspaces", "encrypted_secrets", ws.id, "concurrent-write")

      assert Rotation.update_row!(
               "workspaces",
               "encrypted_secrets",
               ws.id,
               stale_snapshot,
               "would-clobber-the-concurrent-write"
             ) == :changed_under_us

      assert read_raw_column!("workspaces", "encrypted_secrets", ws.id) == "concurrent-write"
    end
  end

  describe "@columns drift guard" do
    test "matches every ash_cloak attribute in the app" do
      actual =
        :arbiter
        |> Application.fetch_env!(:ash_domains)
        |> Enum.flat_map(&Ash.Domain.Info.resources/1)
        |> Enum.flat_map(fn resource ->
          resource
          |> AshCloak.Info.cloak_attributes!()
          |> Enum.map(&{resource, AshSqlite.DataLayer.Info.table(resource), &1})
        end)
        |> MapSet.new()

      expected = MapSet.new(Rotation.columns())

      assert actual == expected,
             "Arbiter.Vault.Rotation's @columns is out of sync with the app's ash_cloak " <>
               "attributes.\n  missing from @columns: #{inspect(MapSet.difference(actual, expected))}\n" <>
               "  stale in @columns: #{inspect(MapSet.difference(expected, actual))}"
    end
  end

  describe "verify/0" do
    test "reports a nonzero retired count until the row is swept", %{
      old_key: old_key,
      old_tag: old_tag
    } do
      {:ok, ws} =
        Ash.create(Workspace, %{name: "rot-verify-#{System.unique_integer([:positive])}"})

      old_ciphertext = encrypt_under_old_cipher(old_key, old_tag, %{"k" => "v"})
      write_raw_column!("workspaces", "encrypted_secrets", ws.id, old_ciphertext)

      before = Rotation.verify() |> find_report("workspaces", "encrypted_secrets")
      assert before.retired >= 1

      Rotation.sweep!()

      after_sweep = Rotation.verify() |> find_report("workspaces", "encrypted_secrets")
      assert after_sweep.retired == 0
    end
  end
end
