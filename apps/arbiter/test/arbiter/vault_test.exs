defmodule Arbiter.VaultTest do
  # async: false — mutates the ARBITER_CLOAK_KEY env var / app config.
  use ExUnit.Case, async: false

  alias Arbiter.Vault

  setup do
    # Snapshot and restore the env var + config fallback so cases that clear
    # them don't leak into the running vault (or other tests).
    prev_env = System.get_env("ARBITER_CLOAK_KEY")
    prev_cfg = Application.get_env(:arbiter, Vault)

    on_exit(fn ->
      if prev_env,
        do: System.put_env("ARBITER_CLOAK_KEY", prev_env),
        else: System.delete_env("ARBITER_CLOAK_KEY")

      Application.put_env(:arbiter, Vault, prev_cfg)
    end)

    :ok
  end

  describe "key!/0" do
    test "decodes a valid Base64 32-byte key from ARBITER_CLOAK_KEY" do
      key = :crypto.strong_rand_bytes(32)
      System.put_env("ARBITER_CLOAK_KEY", Base.encode64(key))

      assert Vault.key!() == key
      assert byte_size(Vault.key!()) == 32
    end

    test "the env var takes precedence over the config fallback" do
      env_key = :crypto.strong_rand_bytes(32)
      System.put_env("ARBITER_CLOAK_KEY", Base.encode64(env_key))
      Application.put_env(:arbiter, Vault, key: Base.encode64(:crypto.strong_rand_bytes(32)))

      assert Vault.key!() == env_key
    end

    test "falls back to the config key when the env var is absent" do
      System.delete_env("ARBITER_CLOAK_KEY")
      cfg_key = :crypto.strong_rand_bytes(32)
      Application.put_env(:arbiter, Vault, key: Base.encode64(cfg_key))

      assert Vault.key!() == cfg_key
    end

    test "raises a clear error when no key is configured" do
      System.delete_env("ARBITER_CLOAK_KEY")
      Application.put_env(:arbiter, Vault, [])

      assert_raise RuntimeError, ~r/ARBITER_CLOAK_KEY is not set/, fn -> Vault.key!() end
    end

    test "raises when the key does not decode to 32 bytes" do
      System.put_env("ARBITER_CLOAK_KEY", Base.encode64(:crypto.strong_rand_bytes(16)))

      assert_raise RuntimeError, ~r/must decode to 32 bytes/, fn -> Vault.key!() end
    end

    test "raises when the key is not valid Base64" do
      System.put_env("ARBITER_CLOAK_KEY", "not valid base64 !!!")

      assert_raise RuntimeError, ~r/must be valid Base64/, fn -> Vault.key!() end
    end
  end

  describe "encrypt/decrypt round-trip" do
    test "the running vault encrypts and decrypts a binary" do
      plaintext = "sct_rw_super_secret"

      assert {:ok, ciphertext} = Vault.encrypt(plaintext)
      assert ciphertext != plaintext
      assert {:ok, ^plaintext} = Vault.decrypt(ciphertext)
    end
  end
end
