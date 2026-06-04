defmodule Arbiter.Agents.Claude.ConfigTest do
  use ExUnit.Case, async: false

  alias Arbiter.Agents.Claude.Config

  setup do
    on_exit(fn -> Config.clear() end)
    :ok
  end

  describe "thinking_argv/1" do
    setup do
      Config.put_active(%{})
      :ok
    end

    test "none returns empty list" do
      assert Config.thinking_argv("none") == []
    end

    test "nil returns empty list" do
      assert Config.thinking_argv(nil) == []
    end

    test "empty string returns empty list" do
      assert Config.thinking_argv("") == []
    end

    test "unknown level returns empty list" do
      assert Config.thinking_argv("extreme") == []
    end

    for level <- ~w[low medium high xhigh max] do
      test "#{level} maps to --effort flag" do
        assert Config.thinking_argv(unquote(level)) == ["--effort", unquote(level)]
      end
    end

    test "workspace override is respected" do
      Config.put_active(%{"thinking_argv" => %{"high" => ["--effort", "max"]}})
      assert Config.thinking_argv("high") == ["--effort", "max"]
    end
  end

  describe "default_thinking_argv/0" do
    test "all non-none entries use --effort flag" do
      defaults = Config.default_thinking_argv()

      for {level, argv} <- defaults, level != "none" do
        assert ["--effort", ^level] = argv,
               "expected #{level} to map to [\"--effort\", \"#{level}\"], got #{inspect(argv)}"
      end
    end

    test "none entry is empty list" do
      assert Config.default_thinking_argv()["none"] == []
    end

    test "includes xhigh and max for future high-effort tiers" do
      defaults = Config.default_thinking_argv()
      assert Map.has_key?(defaults, "xhigh")
      assert Map.has_key?(defaults, "max")
    end
  end
end
