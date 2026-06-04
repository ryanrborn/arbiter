defmodule Arbiter.Agents.Gemini.ConfigTest do
  use ExUnit.Case, async: false

  alias Arbiter.Agents.Gemini.Config

  setup do
    on_exit(fn -> Config.clear() end)
    :ok
  end

  describe "put_active/1 and resolve/0" do
    test "seeds and resolves active configuration" do
      Config.put_active(%{"model" => "flash-3.5", "credentials_ref" => "literal-key"})

      assert {:ok, cfg} = Config.resolve()
      assert cfg.model == "flash-3.5"
      assert cfg.credentials_ref == "literal-key"
    end
  end

  describe "resolve_api_key/0" do
    test "resolves env variable" do
      System.put_env("TEST_GEMINI_KEY", "env-secret")
      on_exit(fn -> System.delete_env("TEST_GEMINI_KEY") end)

      Config.put_active(%{"credentials_ref" => "env:TEST_GEMINI_KEY"})
      assert Config.resolve_api_key() == "env-secret"
    end

    test "resolves literal token" do
      Config.put_active(%{"credentials_ref" => "literal-token"})
      assert Config.resolve_api_key() == "literal-token"
    end

    test "falls back to ambient env variable if not configured" do
      System.put_env("GEMINI_API_KEY", "ambient-secret")
      on_exit(fn -> System.delete_env("GEMINI_API_KEY") end)

      Config.put_active(%{})
      assert Config.resolve_api_key() == "ambient-secret"
    end

    test "rotates through api_keys non-empty list" do
      System.put_env("ROT1", "val1")
      System.put_env("ROT2", "val2")

      on_exit(fn ->
        System.delete_env("ROT1")
        System.delete_env("ROT2")
      end)

      Config.put_active(%{"api_keys" => ["env:ROT1", "env:ROT2"]})

      assert Config.resolve_api_key() == "val1"
      assert Config.resolve_api_key() == "val2"
      assert Config.resolve_api_key() == "val1"
    end
  end
end
