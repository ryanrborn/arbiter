defmodule Arbiter.Agents.GeminiTest do
  use ExUnit.Case, async: false

  alias Arbiter.Agents.Gemini
  alias Arbiter.Agents.SecurityPolicy

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

      # Default policy is :auto — skip-permissions flag is NOT included.
      assert {:ok, argv} = Gemini.default_argv("the prompt", [])
      assert ["sh", "-c", _exec, "sh", ^agy_stub, "-p", "the prompt" | rest] = argv
      refute "--dangerously-skip-permissions" in rest
      refute "--skip-trust" in rest
    end

    test "agy: :bypass security mode includes --dangerously-skip-permissions", %{tmp: tmp} do
      agy_stub = Path.join(tmp, "agy")
      File.write!(agy_stub, "#!/bin/sh\nexit 0\n")
      File.chmod!(agy_stub, 0o755)

      bypass_policy =
        SecurityPolicy.merge(SecurityPolicy.base(), %{permissions: %{mode: :bypass}})

      assert {:ok, argv} = Gemini.default_argv("the prompt", security: bypass_policy)
      assert ["sh", "-c", _exec, "sh", ^agy_stub, "-p", "the prompt" | rest] = argv
      assert "--dangerously-skip-permissions" in rest
    end

    test "falls back to `gemini` when `agy` is missing", %{tmp: tmp} do
      gemini_stub = Path.join(tmp, "gemini")
      File.write!(gemini_stub, "#!/bin/sh\nexit 0\n")
      File.chmod!(gemini_stub, 0o755)

      # Default policy is :auto — skip-trust is NOT included.
      assert {:ok, argv} = Gemini.default_argv("the prompt", [])
      assert ["sh", "-c", _exec, "sh", ^gemini_stub, "-p", "the prompt" | rest] = argv
      refute "--skip-trust" in rest
      refute "-y" in rest
      refute "--dangerously-skip-permissions" in rest
    end

    test "gemini: :bypass security mode includes --skip-trust -y", %{tmp: tmp} do
      gemini_stub = Path.join(tmp, "gemini")
      File.write!(gemini_stub, "#!/bin/sh\nexit 0\n")
      File.chmod!(gemini_stub, 0o755)

      bypass_policy =
        SecurityPolicy.merge(SecurityPolicy.base(), %{permissions: %{mode: :bypass}})

      assert {:ok, argv} = Gemini.default_argv("the prompt", security: bypass_policy)
      assert ["sh", "-c", _exec, "sh", ^gemini_stub, "-p", "the prompt" | rest] = argv
      assert "--skip-trust" in rest
      assert "-y" in rest
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

    test "resolves :model_tier to a concrete Gemini model via the default tier map",
         %{tmp: tmp} do
      agy_stub = Path.join(tmp, "agy")
      File.write!(agy_stub, "#!/bin/sh\nexit 0\n")
      File.chmod!(agy_stub, 0o755)

      for {tier, model} <- [
            {"premium", "gemini-2.5-pro"},
            {"standard", "gemini-2.5-flash"},
            {"economy", "gemini-2.5-flash-lite"}
          ] do
        {:ok, argv} = Gemini.default_argv("the prompt", model_tier: tier)
        assert "--model" in argv
        assert model in argv
      end
    end

    test ":model wins over :model_tier when both are set", %{tmp: tmp} do
      agy_stub = Path.join(tmp, "agy")
      File.write!(agy_stub, "#!/bin/sh\nexit 0\n")
      File.chmod!(agy_stub, 0o755)

      {:ok, argv} =
        Gemini.default_argv("the prompt", model: "custom-model", model_tier: "economy")

      assert "custom-model" in argv
      refute "gemini-2.5-flash-lite" in argv
    end

    test ":model_tier can be overridden per-workspace via tier_models config", %{tmp: tmp} do
      agy_stub = Path.join(tmp, "agy")
      File.write!(agy_stub, "#!/bin/sh\nexit 0\n")
      File.chmod!(agy_stub, 0o755)

      Gemini.Config.put_active(%{
        "tier_models" => %{"premium" => "gemini-ultra"}
      })

      on_exit(fn -> Gemini.Config.clear() end)

      {:ok, argv} = Gemini.default_argv("the prompt", model_tier: "premium")
      assert "gemini-ultra" in argv
      refute "gemini-2.5-pro" in argv
    end

    test ":thinking opt is empty in argv by default (env-var path)", %{tmp: tmp} do
      agy_stub = Path.join(tmp, "agy")
      File.write!(agy_stub, "#!/bin/sh\nexit 0\n")
      File.chmod!(agy_stub, 0o755)

      {:ok, argv} = Gemini.default_argv("the prompt", thinking: "high")
      # No CLI flag is committed by default — workspace can opt in via
      # thinking_argv overrides if it pins a CLI flag.
      refute Enum.any?(argv, &String.starts_with?(&1, "--thinking"))
      refute Enum.any?(argv, &String.starts_with?(&1, "--reasoning"))
    end

    test ":thinking argv can be overridden per-workspace via thinking_argv config",
         %{tmp: tmp} do
      agy_stub = Path.join(tmp, "agy")
      File.write!(agy_stub, "#!/bin/sh\nexit 0\n")
      File.chmod!(agy_stub, 0o755)

      Gemini.Config.put_active(%{
        "thinking_argv" => %{"medium" => ["--thinking-budget", "8192"]}
      })

      on_exit(fn -> Gemini.Config.clear() end)

      {:ok, argv} = Gemini.default_argv("the prompt", thinking: "medium")
      assert "--thinking-budget" in argv
      assert "8192" in argv
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

    test "exports GEMINI_THINKING_LEVEL for low/medium/high :thinking" do
      for level <- ["low", "medium", "high"] do
        env = Gemini.spawn_env(thinking: level)

        assert {"GEMINI_THINKING_LEVEL", ^level} =
                 Enum.find(env, &match?({"GEMINI_THINKING_LEVEL", _}, &1))
      end
    end

    test "omits GEMINI_THINKING_LEVEL when :thinking is none / nil" do
      refute Enum.any?(
               Gemini.spawn_env(thinking: "none"),
               &match?({"GEMINI_THINKING_LEVEL", _}, &1)
             )

      refute Enum.any?(Gemini.spawn_env([]), &match?({"GEMINI_THINKING_LEVEL", _}, &1))
    end

    test "composes thinking + api key" do
      env = Gemini.spawn_env(api_key: "k", thinking: "high")

      assert {"GEMINI_API_KEY", "k"} in env
      assert {"GOOGLE_GENAI_API_KEY", "k"} in env
      assert {"GEMINI_THINKING_LEVEL", "high"} in env
    end
  end
end
