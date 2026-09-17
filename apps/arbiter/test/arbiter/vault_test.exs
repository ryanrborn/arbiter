defmodule Arbiter.VaultTest do
  # async: false — mutates the ARBITER_CLOAK_KEY env var / app config.
  use ExUnit.Case, async: false

  alias Arbiter.Vault

  setup do
    # Snapshot and restore the env vars + config fallback so cases that clear
    # them don't leak into the running vault (or other tests).
    prev_env = System.get_env("ARBITER_CLOAK_KEY")
    prev_old_env = System.get_env("ARBITER_CLOAK_KEY_OLD")
    prev_gen_env = System.get_env("ARBITER_CLOAK_KEY_GENERATION")
    prev_cfg = Application.get_env(:arbiter, Vault)

    on_exit(fn ->
      if prev_env,
        do: System.put_env("ARBITER_CLOAK_KEY", prev_env),
        else: System.delete_env("ARBITER_CLOAK_KEY")

      if prev_old_env,
        do: System.put_env("ARBITER_CLOAK_KEY_OLD", prev_old_env),
        else: System.delete_env("ARBITER_CLOAK_KEY_OLD")

      if prev_gen_env,
        do: System.put_env("ARBITER_CLOAK_KEY_GENERATION", prev_gen_env),
        else: System.delete_env("ARBITER_CLOAK_KEY_GENERATION")

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

  describe "generation!/0" do
    test "defaults to 1 when ARBITER_CLOAK_KEY_GENERATION is unset" do
      System.delete_env("ARBITER_CLOAK_KEY_GENERATION")
      Application.delete_env(:arbiter, Vault)

      assert Vault.generation!() == 1
    end

    test "reads a positive integer from ARBITER_CLOAK_KEY_GENERATION" do
      System.put_env("ARBITER_CLOAK_KEY_GENERATION", "2")

      assert Vault.generation!() == 2
    end

    test "raises on a non-integer or non-positive value" do
      System.put_env("ARBITER_CLOAK_KEY_GENERATION", "not-a-number")

      assert_raise RuntimeError,
                   ~r/ARBITER_CLOAK_KEY_GENERATION must be a positive integer/,
                   fn ->
                     Vault.generation!()
                   end

      System.put_env("ARBITER_CLOAK_KEY_GENERATION", "0")

      assert_raise RuntimeError,
                   ~r/ARBITER_CLOAK_KEY_GENERATION must be a positive integer/,
                   fn ->
                     Vault.generation!()
                   end
    end
  end

  describe "rotation: init/1 cipher set" do
    test "generation 1, no old key (the pre-rotation / never-rotated state): only :default, tag V1" do
      System.put_env("ARBITER_CLOAK_KEY", Base.encode64(:crypto.strong_rand_bytes(32)))
      System.delete_env("ARBITER_CLOAK_KEY_OLD")
      System.delete_env("ARBITER_CLOAK_KEY_GENERATION")

      {:ok, config} = Vault.init([])

      assert Keyword.keys(config[:ciphers]) == [:default]
      {_mod, opts} = config[:ciphers][:default]
      assert opts[:tag] == "AES.GCM.V1"
    end

    test "bumping the generation without an old key breaks previous-generation ciphertext" do
      # This is deliberately what NOT to do mid-rotation (see the moduledoc):
      # bumping ARBITER_CLOAK_KEY_GENERATION without ARBITER_CLOAK_KEY_OLD set
      # leaves nothing registered for the previous generation's tag.
      System.put_env("ARBITER_CLOAK_KEY", Base.encode64(:crypto.strong_rand_bytes(32)))
      System.delete_env("ARBITER_CLOAK_KEY_OLD")
      System.put_env("ARBITER_CLOAK_KEY_GENERATION", "2")

      {:ok, config} = Vault.init([])

      assert Keyword.keys(config[:ciphers]) == [:default]
      {_mod, opts} = config[:ciphers][:default]
      assert opts[:tag] == "AES.GCM.V2"
    end

    test "generation bumped + old key set (an in-progress rotation): both ciphers, distinct tags" do
      System.put_env("ARBITER_CLOAK_KEY", Base.encode64(:crypto.strong_rand_bytes(32)))
      System.put_env("ARBITER_CLOAK_KEY_OLD", Base.encode64(:crypto.strong_rand_bytes(32)))
      System.put_env("ARBITER_CLOAK_KEY_GENERATION", "2")

      {:ok, config} = Vault.init([])

      assert Keyword.keys(config[:ciphers]) == [:default, :retired]
      {_mod, default_opts} = config[:ciphers][:default]
      {_mod, retired_opts} = config[:ciphers][:retired]
      assert default_opts[:tag] == "AES.GCM.V2"
      assert retired_opts[:tag] == "AES.GCM.V1"
      assert default_opts[:tag] == Vault.current_tag()
      assert retired_opts[:tag] == Vault.retired_tag()
    end

    test "mid-rotation: pre-rotation ciphertext still decrypts, new writes use the new cipher" do
      old_key = :crypto.strong_rand_bytes(32)
      new_key = :crypto.strong_rand_bytes(32)
      plaintext = "sct_rw_mid_rotation"

      # Simulate a row written before rotation: generation 1, no rotation env
      # vars set, so this is exactly Vault.init([])'s baseline single-cipher
      # config today.
      System.put_env("ARBITER_CLOAK_KEY", Base.encode64(old_key))
      System.delete_env("ARBITER_CLOAK_KEY_OLD")
      System.delete_env("ARBITER_CLOAK_KEY_GENERATION")
      {:ok, pre_rotation_config} = Vault.init([])
      old_ciphertext = Cloak.Vault.encrypt!(pre_rotation_config, plaintext)

      # Deploy the rotation: new key as :default, old key registered
      # decrypt-only, generation bumped — all three together, per the runbook.
      System.put_env("ARBITER_CLOAK_KEY", Base.encode64(new_key))
      System.put_env("ARBITER_CLOAK_KEY_OLD", Base.encode64(old_key))
      System.put_env("ARBITER_CLOAK_KEY_GENERATION", "2")
      {:ok, rotating_config} = Vault.init([])

      # Old ciphertext still decrypts while the retired cipher is registered.
      assert {:ok, ^plaintext} = Cloak.Vault.decrypt(rotating_config, old_ciphertext)

      # New encryptions use the default (new) cipher/tag.
      new_ciphertext = Cloak.Vault.encrypt!(rotating_config, plaintext)
      assert %{tag: tag} = Cloak.Tags.Decoder.decode(new_ciphertext)
      assert tag == "AES.GCM.V2"
      assert {:ok, ^plaintext} = Cloak.Vault.decrypt(rotating_config, new_ciphertext)

      # Complete the rotation: drop the old key, keep the generation bumped.
      # New (already-swept) ciphertext keeps decrypting; any *unswept*
      # previous-generation ciphertext would not — which is exactly why the
      # runbook requires Rotation.verify/0 to report zero before this step.
      System.delete_env("ARBITER_CLOAK_KEY_OLD")
      {:ok, post_rotation_config} = Vault.init([])
      assert {:ok, ^plaintext} = Cloak.Vault.decrypt(post_rotation_config, new_ciphertext)
      assert {:error, _} = Cloak.Vault.decrypt(post_rotation_config, old_ciphertext)
    end
  end
end
