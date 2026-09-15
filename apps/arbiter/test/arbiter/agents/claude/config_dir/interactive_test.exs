defmodule Arbiter.Agents.Claude.ConfigDir.InteractiveTest do
  @moduledoc """
  The interactive-session variant of `Arbiter.Agents.Claude.ConfigDir`
  (bd-aprlbb, RFC §9.2 / §8.1–§8.2 / §10.2 layer 3).

  Acceptance criterion 2: `.claude.json` answers the three interactive gates a
  fresh `CLAUDE_CONFIG_DIR` blocks on, so an automated launch reaches a prompt
  instead of hanging on a wizard nobody can click through.
  """
  use ExUnit.Case, async: true

  alias Arbiter.Agents.Claude.ConfigDir.Interactive

  setup do
    tmp = Path.join(System.tmp_dir!(), "bd-aprlbb-cfg-#{System.unique_integer([:positive])}")
    config = Path.join(tmp, "config")
    source = Path.join(tmp, "operator")
    File.mkdir_p!(source)
    on_exit(fn -> File.rm_rf(tmp) end)
    {:ok, tmp: tmp, config: config, source: source}
  end

  defp claude_json!(config),
    do: config |> Path.join(".claude.json") |> File.read!() |> Jason.decode!()

  describe "the three onboarding gates (§9.2)" do
    test "writes .claude.json answering theme, onboarding and cwd trust", %{
      config: config,
      tmp: tmp
    } do
      cwd = Path.join(tmp, "workspace")
      assert :ok = Interactive.ensure(config, cwd: cwd, source_dir: nil)

      json = claude_json!(config)

      # Gate 1 — theme picker.
      assert is_binary(json["theme"]) and json["theme"] != ""

      # Gate 2 — login-method wizard.
      assert json["hasCompletedOnboarding"] == true
      assert is_binary(json["lastOnboardingVersion"]) and json["lastOnboardingVersion"] != ""

      # Gate 3 — "is this a folder you trust?" for the session cwd.
      assert %{"hasTrustDialogAccepted" => true} = json["projects"][cwd]
    end

    test "is idempotent and preserves unrelated keys already on disk", %{
      config: config,
      tmp: tmp
    } do
      cwd = Path.join(tmp, "workspace")
      assert :ok = Interactive.ensure(config, cwd: cwd, source_dir: nil)

      path = Path.join(config, ".claude.json")

      path
      |> File.read!()
      |> Jason.decode!()
      |> Map.put("numStartups", 7)
      |> Jason.encode!()
      |> then(&File.write!(path, &1))

      assert :ok = Interactive.ensure(config, cwd: cwd, source_dir: nil)

      json = claude_json!(config)
      assert json["numStartups"] == 7
      assert json["hasCompletedOnboarding"] == true
      assert %{"hasTrustDialogAccepted" => true} = json["projects"][cwd]
    end

    test "a corrupt .claude.json is replaced rather than fatal", %{config: config, tmp: tmp} do
      cwd = Path.join(tmp, "workspace")
      File.mkdir_p!(config)
      File.write!(Path.join(config, ".claude.json"), "{not json")

      assert :ok = Interactive.ensure(config, cwd: cwd, source_dir: nil)
      assert claude_json!(config)["hasCompletedOnboarding"] == true
    end

    test "takes lastOnboardingVersion from the operator's own .claude.json when readable", %{
      config: config,
      source: source,
      tmp: tmp
    } do
      File.write!(
        Path.join(source, ".claude.json"),
        Jason.encode!(%{"lastOnboardingVersion" => "9.9.9"})
      )

      assert :ok =
               Interactive.ensure(config, cwd: Path.join(tmp, "workspace"), source_dir: source)

      assert claude_json!(config)["lastOnboardingVersion"] == "9.9.9"
    end
  end

  describe "settings.json — the §10.2 layer-3 deny rules" do
    test "carries the hardened baseline plus a deny on the primary checkout", %{
      config: config,
      tmp: tmp
    } do
      checkout = "/home/someone/dev/arbiter"

      assert :ok =
               Interactive.ensure(config,
                 cwd: Path.join(tmp, "workspace"),
                 source_dir: nil,
                 primary_checkout: checkout
               )

      settings = config |> Path.join("settings.json") |> File.read!() |> Jason.decode!()
      deny = settings["permissions"]["deny"]

      assert "Write(#{checkout}/**)" in deny
      assert "Edit(#{checkout}/**)" in deny
      assert "NotebookEdit(#{checkout}/**)" in deny

      # the install-wide hardened floor is still there
      assert "Bash(rm -rf:*)" in deny
    end

    test "omits the checkout deny when no primary checkout resolves", %{config: config, tmp: tmp} do
      assert :ok =
               Interactive.ensure(config,
                 cwd: Path.join(tmp, "workspace"),
                 source_dir: nil,
                 primary_checkout: nil
               )

      settings = config |> Path.join("settings.json") |> File.read!() |> Jason.decode!()
      refute Enum.any?(settings["permissions"]["deny"], &String.contains?(&1, "arbiter/**"))
    end
  end

  describe "auth modes (§8.1)" do
    test "mode B copies the operator's credentials into the session config dir", %{
      config: config,
      source: source,
      tmp: tmp
    } do
      File.write!(
        Path.join(source, ".credentials.json"),
        ~s({"claudeAiOauth":{"accessToken":"sk-secret"}})
      )

      assert :ok =
               Interactive.ensure(config,
                 cwd: Path.join(tmp, "workspace"),
                 source_dir: source,
                 auth_mode: :seeded_credentials
               )

      copied = Path.join(config, ".credentials.json")
      assert File.exists?(copied)
      # copied, never symlinked — both sides refresh it (§8.2)
      assert {:ok, %{type: :regular}} = File.lstat(copied)
      assert File.read!(copied) =~ "sk-secret"
    end

    test "mode A never seeds credentials, and removes a stale copy", %{
      config: config,
      source: source,
      tmp: tmp
    } do
      File.write!(Path.join(source, ".credentials.json"), ~s({"claudeAiOauth":{}}))
      File.mkdir_p!(config)
      File.write!(Path.join(config, ".credentials.json"), ~s({"stale":true}))

      assert :ok =
               Interactive.ensure(config,
                 cwd: Path.join(tmp, "workspace"),
                 source_dir: source,
                 auth_mode: :oauth_token
               )

      refute File.exists?(Path.join(config, ".credentials.json"))
    end
  end
end
