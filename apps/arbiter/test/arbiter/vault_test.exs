defmodule Arbiter.VaultTest do
  # async: false — mutates the ARBITER_CLOAK_KEY env var / app config.
  use ExUnit.Case, async: false

  alias Arbiter.Vault

  setup do
    # Snapshot and restore the env vars + config fallback so cases that clear
    # them don't leak into the running vault (or other tests).
    prev_env = System.get_env("ARBITER_CLOAK_KEY")
    prev_old_env = System.get_env("ARBITER_CLOAK_KEY_OLD")
    prev_cfg = Application.get_env(:arbiter, Vault)

    on_exit(fn ->
      if prev_env,
        do: System.put_env("ARBITER_CLOAK_KEY", prev_env),
        else: System.delete_env("ARBITER_CLOAK_KEY")

      if prev_old_env,
        do: System.put_env("ARBITER_CLOAK_KEY_OLD", prev_old_env),
        else: System.delete_env("ARBITER_CLOAK_KEY_OLD")

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

  describe "old_key/0" do
    test "returns nil when ARBITER_CLOAK_KEY_OLD is unset (no rotation in progress)" do
      System.delete_env("ARBITER_CLOAK_KEY_OLD")
      Application.delete_env(:arbiter, Vault)

      assert Vault.old_key() == nil
    end

    test "decodes ARBITER_CLOAK_KEY_OLD when set" do
      key = :crypto.strong_rand_bytes(32)
      System.put_env("ARBITER_CLOAK_KEY_OLD", Base.encode64(key))

      assert Vault.old_key() == key
    end

    test "raises when set but malformed, same as key!/0" do
      System.put_env("ARBITER_CLOAK_KEY_OLD", "not valid base64 !!!")

      assert_raise RuntimeError, ~r/ARBITER_CLOAK_KEY_OLD must be valid Base64/, fn ->
        Vault.old_key()
      end
    end
  end

  describe "rotation: init/1 cipher set" do
    test "registers only the current cipher when no old key is configured" do
      System.put_env("ARBITER_CLOAK_KEY", Base.encode64(:crypto.strong_rand_bytes(32)))
      System.delete_env("ARBITER_CLOAK_KEY_OLD")

      {:ok, config} = Vault.init([])

      assert Keyword.keys(config[:ciphers]) == [:default]
    end

    test "registers both ciphers, default first, when an old key is configured" do
      System.put_env("ARBITER_CLOAK_KEY", Base.encode64(:crypto.strong_rand_bytes(32)))
      System.put_env("ARBITER_CLOAK_KEY_OLD", Base.encode64(:crypto.strong_rand_bytes(32)))

      {:ok, config} = Vault.init([])

      assert Keyword.keys(config[:ciphers]) == [:default, :retired]
      {_mod, default_opts} = config[:ciphers][:default]
      {_mod, retired_opts} = config[:ciphers][:retired]
      assert default_opts[:tag] == Vault.current_tag()
      assert retired_opts[:tag] == Vault.retired_tag()
      assert default_opts[:tag] != retired_opts[:tag]
    end

    test "mid-rotation: old-cipher ciphertext still decrypts, new writes use the new cipher" do
      new_key = :crypto.strong_rand_bytes(32)
      old_key = :crypto.strong_rand_bytes(32)
      plaintext = "sct_rw_mid_rotation"

      # Simulate a row written before rotation, under the old cipher/tag.
      old_only_config = [
        ciphers: [
          default: {Cloak.Ciphers.AES.GCM, tag: Vault.retired_tag(), key: old_key, iv_length: 12}
        ]
      ]

      old_ciphertext = Cloak.Vault.encrypt!(old_only_config, plaintext)

      System.put_env("ARBITER_CLOAK_KEY", Base.encode64(new_key))
      System.put_env("ARBITER_CLOAK_KEY_OLD", Base.encode64(old_key))
      {:ok, rotating_config} = Vault.init([])

      # Old ciphertext still decrypts while the retired cipher is registered.
      assert {:ok, ^plaintext} = Cloak.Vault.decrypt(rotating_config, old_ciphertext)

      # New encryptions use the default (new) cipher/tag.
      new_ciphertext = Cloak.Vault.encrypt!(rotating_config, plaintext)
      assert %{tag: tag} = Cloak.Tags.Decoder.decode(new_ciphertext)
      assert tag == Vault.current_tag()
      assert {:ok, ^plaintext} = Cloak.Vault.decrypt(rotating_config, new_ciphertext)

      # Once the retired cipher is dropped (old key removed post-rotation),
      # the pre-rotation ciphertext can no longer be decrypted.
      System.delete_env("ARBITER_CLOAK_KEY_OLD")
      {:ok, post_rotation_config} = Vault.init([])
      assert {:error, _} = Cloak.Vault.decrypt(post_rotation_config, old_ciphertext)
    end
  end
end
