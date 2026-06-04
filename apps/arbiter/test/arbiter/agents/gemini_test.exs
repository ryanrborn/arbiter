defmodule Arbiter.Agents.GeminiTest do
  use ExUnit.Case, async: false

  alias Arbiter.Agents.Gemini

  describe "behaviour" do
    test "module declares the Agent behaviour" do
      behaviours =
        Gemini.module_info(:attributes) |> Keyword.get_values(:behaviour) |> List.flatten()

      assert Arbiter.Agents.Agent in behaviours
    end

    test "provider/0 returns \"gemini\"" do
      assert Gemini.provider() == "gemini"
    end

    test "done_sentinel/0 matches `arb done`" do
      assert Regex.match?(Gemini.done_sentinel(), "I am done — arb done")
      refute Regex.match?(Gemini.done_sentinel(), "arb doneness")
    end
  end

  describe "default_argv/2 executable resolution" do
    setup do
      tmp =
        Path.join(System.tmp_dir!(), "arbiter-gemini-stub-#{System.unique_integer([:positive])}")

      File.mkdir_p!(tmp)

      old_path = System.get_env("PATH") || ""
      System.put_env("PATH", tmp)

      on_exit(fn ->
        System.put_env("PATH", old_path)
        File.rm_rf!(tmp)
      end)

      {:ok, tmp: tmp, old_path: old_path}
    end

    test "returns {:error, ...} when neither `agy` nor `gemini` is on PATH", %{old_path: old_path} do
      System.put_env("PATH", "/nonexistent-dir-for-test")

      try do
        assert {:error, {:executable_not_found, "agy or gemini"}} =
                 Gemini.default_argv("hello", [])
      after
        System.put_env("PATH", old_path)
      end
    end

    test "favors `agy` when both `agy` and `gemini` exist", %{tmp: tmp} do
      agy_stub = Path.join(tmp, "agy")
      gemini_stub = Path.join(tmp, "gemini")
      File.write!(agy_stub, "#!/bin/sh\nexit 0\n")
      File.write!(gemini_stub, "#!/bin/sh\nexit 0\n")
      File.chmod!(agy_stub, 0o755)
      File.chmod!(gemini_stub, 0o755)

      assert {:ok, argv} = Gemini.default_argv("the prompt", [])
      assert ["sh", "-c", _exec, "sh", ^agy_stub, "-p", "the prompt" | rest] = argv
      assert "--dangerously-skip-permissions" in rest
      refute "--skip-trust" in rest
    end

    test "falls back to `gemini` when `agy` is missing", %{tmp: tmp} do
      gemini_stub = Path.join(tmp, "gemini")
      File.write!(gemini_stub, "#!/bin/sh\nexit 0\n")
      File.chmod!(gemini_stub, 0o755)

      assert {:ok, argv} = Gemini.default_argv("the prompt", [])
      assert ["sh", "-c", _exec, "sh", ^gemini_stub, "-p", "the prompt" | rest] = argv
      assert "--skip-trust" in rest
      assert "-y" in rest
      refute "--dangerously-skip-permissions" in rest
    end

    test "passes through `:model` opt as `--model <name>`", %{tmp: tmp} do
      agy_stub = Path.join(tmp, "agy")
      File.write!(agy_stub, "#!/bin/sh\nexit 0\n")
      File.chmod!(agy_stub, 0o755)

      assert {:ok, argv} = Gemini.default_argv("the prompt", model: "gemini-flash")
      assert ["sh", "-c", _exec, "sh", ^agy_stub, "-p", "the prompt" | rest] = argv
      assert "--model" in rest
      assert "gemini-flash" in rest
    end
  end

  describe "spawn_env/1" do
    setup do
      on_exit(fn -> Gemini.Config.clear() end)
      :ok
    end

    test "exports GEMINI_API_KEY and GOOGLE_GENAI_API_KEY from `opts[:api_key]`" do
      assert Gemini.spawn_env(api_key: "my-token") == [
               {"GEMINI_API_KEY", "my-token"},
               {"GOOGLE_GENAI_API_KEY", "my-token"}
             ]
    end
  end
end
