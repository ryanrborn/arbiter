defmodule Arbiter.Tasks.WorkspaceSecretsTest do
  use Arbiter.DataCase, async: false

  alias Arbiter.Tasks.Workspace

  describe "create with secrets" do
    test "stores secrets encrypted and decrypts them on read" do
      assert {:ok, ws} =
               Ash.create(Workspace, %{
                 name: "sec-create",
                 secrets: %{"tracker_token" => "sct_rw_plain"}
               })

      # The decrypt helper round-trips the plaintext...
      assert Workspace.secrets_map(ws) == %{"tracker_token" => "sct_rw_plain"}

      # ...but the stored column holds ciphertext, never the plaintext token.
      assert is_binary(ws.encrypted_secrets)
      refute ws.encrypted_secrets =~ "sct_rw_plain"

      # Re-reading from the DB decrypts the same value.
      assert {:ok, reloaded} = Ash.get(Workspace, ws.id)
      assert Workspace.secrets_map(reloaded) == %{"tracker_token" => "sct_rw_plain"}
    end

    test "omitting secrets leaves the column nil" do
      assert {:ok, ws} = Ash.create(Workspace, %{name: "sec-none"})
      assert ws.encrypted_secrets == nil
      assert Workspace.secrets_map(ws) == %{}
    end

    test "rejects non-string secret values" do
      assert {:error, %Ash.Error.Invalid{}} =
               Ash.create(Workspace, %{name: "sec-bad", secrets: %{"k" => 123}})
    end
  end

  describe "update merge-patch semantics" do
    setup do
      {:ok, ws} =
        Ash.create(Workspace, %{
          name: "sec-update",
          secrets: %{"a" => "1", "b" => "2"}
        })

      %{ws: ws}
    end

    test "setting a new key preserves existing keys", %{ws: ws} do
      assert {:ok, updated} = Ash.update(ws, %{secrets: %{"c" => "3"}})
      assert Workspace.secrets_map(updated) == %{"a" => "1", "b" => "2", "c" => "3"}
    end

    test "overwriting a key updates only that key", %{ws: ws} do
      assert {:ok, updated} = Ash.update(ws, %{secrets: %{"a" => "99"}})
      assert Workspace.secrets_map(updated) == %{"a" => "99", "b" => "2"}
    end

    test "a null value removes the key, leaving siblings", %{ws: ws} do
      assert {:ok, updated} = Ash.update(ws, %{secrets: %{"a" => nil}})
      assert Workspace.secrets_map(updated) == %{"b" => "2"}
    end

    test "omitting the secrets argument leaves all secrets untouched", %{ws: ws} do
      assert {:ok, updated} = Ash.update(ws, %{description: "touch something else"})
      assert Workspace.secrets_map(updated) == %{"a" => "1", "b" => "2"}
      assert updated.description == "touch something else"
    end

    test "an explicit null secrets argument is a no-op", %{ws: ws} do
      assert {:ok, updated} = Ash.update(ws, %{secrets: nil})
      assert Workspace.secrets_map(updated) == %{"a" => "1", "b" => "2"}
    end
  end

  describe "credentials_ref \"secret:\" resolution" do
    test "resolve_for_workspace decrypts a secret: ref from a loaded workspace" do
      alias Arbiter.Agents.CredentialsRef

      {:ok, ws} =
        Ash.create(Workspace, %{name: "sec-rfw", secrets: %{"tracker_token" => "sct_rfw"}})

      assert {:ok, "sct_rfw"} = CredentialsRef.resolve_for_workspace("secret:tracker_token", ws)
      assert {:secret_not_found, "nope"} = CredentialsRef.resolve_for_workspace("secret:nope", ws)
    end

    test "a tracker adapter resolves a secret: ref from the workspace" do
      alias Arbiter.Trackers.Shortcut.Config

      {:ok, ws} =
        Ash.create(Workspace, %{
          name: "sec-shortcut",
          secrets: %{"tracker_token" => "sct_from_db"},
          config: %{
            "tracker" => %{
              "type" => "shortcut",
              "config" => %{"credentials_ref" => "secret:tracker_token"}
            }
          }
        })

      Config.put_active(ws)
      assert {:ok, %{token: "sct_from_db"}} = Config.resolve()
    after
      Arbiter.Trackers.Shortcut.Config.clear()
    end

    test "a missing secret surfaces as config_missing" do
      alias Arbiter.Trackers.Shortcut.Config

      {:ok, ws} =
        Ash.create(Workspace, %{
          name: "sec-shortcut-missing",
          config: %{
            "tracker" => %{
              "type" => "shortcut",
              "config" => %{"credentials_ref" => "secret:nope"}
            }
          }
        })

      Config.put_active(ws)
      assert {:error, %{kind: :config_missing, message: msg}} = Config.resolve()
      assert msg =~ "secret"
    after
      Arbiter.Trackers.Shortcut.Config.clear()
    end

    test "env: refs continue to work unchanged" do
      alias Arbiter.Trackers.Shortcut.Config

      System.put_env("ARBITER_SECRETS_ENV_TEST", "from_env")

      {:ok, ws} =
        Ash.create(Workspace, %{
          name: "sec-env",
          config: %{
            "tracker" => %{
              "type" => "shortcut",
              "config" => %{"credentials_ref" => "env:ARBITER_SECRETS_ENV_TEST"}
            }
          }
        })

      Config.put_active(ws)
      assert {:ok, %{token: "from_env"}} = Config.resolve()
    after
      System.delete_env("ARBITER_SECRETS_ENV_TEST")
      Arbiter.Trackers.Shortcut.Config.clear()
    end
  end
end
