defmodule Arbiter.Vault.RotationTest do
  # async: false — temporarily registers a decrypt-only :retired cipher on
  # the live, VM-global Arbiter.Vault singleton to simulate a mid-rotation
  # window, and restores the original config on exit.
  use Arbiter.DataCase, async: false

  alias Arbiter.Accounts.{ProviderAccount, ProviderCredential}
  alias Arbiter.Tasks.Workspace
  alias Arbiter.Vault
  alias Arbiter.Vault.Rotation

  @old_tag "AES.GCM.V1"
  @config_table Module.concat(Vault, Config)

  setup do
    old_key = :crypto.strong_rand_bytes(32)
    {:ok, live_config} = Cloak.Vault.read_config(@config_table)

    rotating_config =
      Keyword.update!(live_config, :ciphers, fn ciphers ->
        ciphers ++
          [{:retired, {Cloak.Ciphers.AES.GCM, tag: @old_tag, key: old_key, iv_length: 12}}]
      end)

    # The config ETS table is owned by the Arbiter.Vault GenServer
    # (protected access), so it can only be written to from inside that
    # process — route the write through :sys.replace_state/2, which runs the
    # given function in the target process without touching its actual
    # GenServer state.
    save_vault_config(rotating_config)
    on_exit(fn -> save_vault_config(live_config) end)

    %{old_key: old_key}
  end

  defp save_vault_config(config) do
    :sys.replace_state(Vault, fn state ->
      Cloak.Vault.save_config(@config_table, config)
      state
    end)
  end

  defp encrypt_under_old_cipher(old_key, term) do
    {:ok, ciphertext} =
      Cloak.Ciphers.AES.GCM.encrypt(:erlang.term_to_binary(term),
        tag: @old_tag,
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
    test "re-encrypts a workspace row written under the retired cipher", %{old_key: old_key} do
      {:ok, ws} = Ash.create(Workspace, %{name: "rot-ws-#{System.unique_integer([:positive])}"})

      old_ciphertext = encrypt_under_old_cipher(old_key, %{"tracker_token" => "sct_rw_old"})
      write_raw_column!("workspaces", "encrypted_secrets", ws.id, old_ciphertext)
      assert tag_of(read_raw_column!("workspaces", "encrypted_secrets", ws.id)) == @old_tag

      reports = Rotation.sweep!()
      report = find_report(reports, "workspaces", "encrypted_secrets")
      assert report.rotated >= 1

      raw = read_raw_column!("workspaces", "encrypted_secrets", ws.id)
      assert tag_of(raw) == Vault.current_tag()

      {:ok, reloaded} = Ash.get(Workspace, ws.id)
      assert Workspace.secrets_map(reloaded) == %{"tracker_token" => "sct_rw_old"}
    end

    test "leaves an already-current row's ciphertext untouched (safe to re-run)" do
      {:ok, ws} =
        Ash.create(Workspace, %{
          name: "rot-ws-current-#{System.unique_integer([:positive])}",
          secrets: %{"a" => "b"}
        })

      assert tag_of(read_raw_column!("workspaces", "encrypted_secrets", ws.id)) ==
               Vault.current_tag()

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

  describe "verify/0" do
    test "reports a nonzero retired count until the row is swept", %{old_key: old_key} do
      {:ok, ws} =
        Ash.create(Workspace, %{name: "rot-verify-#{System.unique_integer([:positive])}"})

      old_ciphertext = encrypt_under_old_cipher(old_key, %{"k" => "v"})
      write_raw_column!("workspaces", "encrypted_secrets", ws.id, old_ciphertext)

      before = Rotation.verify() |> find_report("workspaces", "encrypted_secrets")
      assert before.retired >= 1

      Rotation.sweep!()

      after_sweep = Rotation.verify() |> find_report("workspaces", "encrypted_secrets")
      assert after_sweep.retired == 0
    end
  end
end
