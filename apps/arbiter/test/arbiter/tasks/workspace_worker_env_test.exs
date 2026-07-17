defmodule Arbiter.Tasks.WorkspaceWorkerEnvTest do
  use Arbiter.DataCase, async: false

  alias Arbiter.Tasks.Workspace

  describe "create with worker_env" do
    test "stores values encrypted and decrypts them on read" do
      assert {:ok, ws} =
               Ash.create(Workspace, %{
                 name: "we-create",
                 worker_env: %{
                   "API_TOKEN" => %{"value" => "tok_plainsecret", "secret" => true},
                   "LOG_LEVEL" => %{"value" => "debug", "secret" => false}
                 }
               })

      # Values round-trip through the decrypt helper...
      assert Workspace.worker_env_map(ws) == %{
               "API_TOKEN" => "tok_plainsecret",
               "LOG_LEVEL" => "debug"
             }

      # ...but the stored column holds ciphertext, never the plaintext value.
      assert is_binary(ws.encrypted_worker_env)
      refute ws.encrypted_worker_env =~ "tok_plainsecret"

      # Key names + secret flags are exposed without decrypting anything.
      assert Workspace.worker_env_keys(ws) == [
               %{name: "API_TOKEN", secret?: true},
               %{name: "LOG_LEVEL", secret?: false}
             ]

      # Re-reading from the DB decrypts the same values.
      assert {:ok, reloaded} = Ash.get(Workspace, ws.id)
      assert Workspace.worker_env_map(reloaded) == %{
               "API_TOKEN" => "tok_plainsecret",
               "LOG_LEVEL" => "debug"
             }
    end

    test "secret? defaults to false when the flag is omitted" do
      assert {:ok, ws} =
               Ash.create(Workspace, %{
                 name: "we-default-flag",
                 worker_env: %{"PLAIN" => %{"value" => "v"}}
               })

      assert Workspace.worker_env_keys(ws) == [%{name: "PLAIN", secret?: false}]
    end

    test "omitting worker_env leaves the column nil and helpers empty" do
      assert {:ok, ws} = Ash.create(Workspace, %{name: "we-none"})
      assert ws.encrypted_worker_env == nil
      assert Workspace.worker_env_map(ws) == %{}
      assert Workspace.worker_env_keys(ws) == []
    end

    test "rejects a non-string value" do
      assert {:error, %Ash.Error.Invalid{}} =
               Ash.create(Workspace, %{
                 name: "we-badval",
                 worker_env: %{"K" => %{"value" => 123}}
               })
    end

    test "rejects an invalid env var name" do
      assert {:error, %Ash.Error.Invalid{}} =
               Ash.create(Workspace, %{
                 name: "we-badname",
                 worker_env: %{"9BAD-NAME" => %{"value" => "v"}}
               })
    end

    test "rejects a non-boolean secret flag" do
      assert {:error, %Ash.Error.Invalid{}} =
               Ash.create(Workspace, %{
                 name: "we-badflag",
                 worker_env: %{"K" => %{"value" => "v", "secret" => "yes"}}
               })
    end
  end

  describe "update merge-patch semantics" do
    setup do
      {:ok, ws} =
        Ash.create(Workspace, %{
          name: "we-update",
          worker_env: %{
            "A" => %{"value" => "1", "secret" => true},
            "B" => %{"value" => "2", "secret" => false}
          }
        })

      %{ws: ws}
    end

    test "setting a new key preserves existing keys", %{ws: ws} do
      assert {:ok, updated} = Ash.update(ws, %{worker_env: %{"C" => %{"value" => "3"}}})

      assert Workspace.worker_env_map(updated) == %{"A" => "1", "B" => "2", "C" => "3"}
      assert Workspace.worker_env_keys(updated) == [
               %{name: "A", secret?: true},
               %{name: "B", secret?: false},
               %{name: "C", secret?: false}
             ]
    end

    test "overwriting a key updates only that value", %{ws: ws} do
      assert {:ok, updated} = Ash.update(ws, %{worker_env: %{"A" => %{"value" => "99"}}})
      assert Workspace.worker_env_map(updated) == %{"A" => "99", "B" => "2"}
    end

    test "toggling only the secret flag leaves the value untouched", %{ws: ws} do
      assert {:ok, updated} = Ash.update(ws, %{worker_env: %{"A" => %{"secret" => false}}})

      assert Workspace.worker_env_map(updated) == %{"A" => "1", "B" => "2"}
      assert Workspace.worker_env_keys(updated) == [
               %{name: "A", secret?: false},
               %{name: "B", secret?: false}
             ]
    end

    test "marking a key secret without providing its value fails when the key is new", %{ws: ws} do
      assert {:error, %Ash.Error.Invalid{}} =
               Ash.update(ws, %{worker_env: %{"NEW" => %{"secret" => true}}})
    end

    test "a null value removes the key from both value store and metadata", %{ws: ws} do
      assert {:ok, updated} = Ash.update(ws, %{worker_env: %{"A" => nil}})
      assert Workspace.worker_env_map(updated) == %{"B" => "2"}
      assert Workspace.worker_env_keys(updated) == [%{name: "B", secret?: false}]
    end

    test "omitting the worker_env argument leaves everything untouched", %{ws: ws} do
      assert {:ok, updated} = Ash.update(ws, %{description: "unrelated"})
      assert Workspace.worker_env_map(updated) == %{"A" => "1", "B" => "2"}
      assert updated.description == "unrelated"
    end

    test "an explicit null worker_env argument is a no-op", %{ws: ws} do
      assert {:ok, updated} = Ash.update(ws, %{worker_env: nil})
      assert Workspace.worker_env_map(updated) == %{"A" => "1", "B" => "2"}
    end
  end
end
