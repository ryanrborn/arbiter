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

  defp settings!(config),
    do: config |> Path.join("settings.json") |> File.read!() |> Jason.decode!()

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

    test "takes the operator's lastOnboardingVersion when it is newer than ours", %{
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

    test "keeps ours when the operator's is older — a low version re-triggers the screen", %{
      config: config,
      source: source,
      tmp: tmp
    } do
      # The dogfood host really is like this: `~/.claude.json` says 2.1.63
      # against a much newer CLI. Preferring it would hand every session the
      # "what's new" screen this module exists to pre-answer.
      File.write!(
        Path.join(source, ".claude.json"),
        Jason.encode!(%{"lastOnboardingVersion" => "0.0.1"})
      )

      assert :ok =
               Interactive.ensure(config, cwd: Path.join(tmp, "workspace"), source_dir: source)

      assert claude_json!(config)["lastOnboardingVersion"] != "0.0.1"
    end

    test "finds the operator's file beside their config dir, not only inside it", %{
      config: config,
      tmp: tmp
    } do
      # `~/.claude.json` sits next to `~/.claude`, which is the real layout.
      beside = Path.join(tmp, "operator-home")
      File.mkdir_p!(beside)
      File.write!(beside <> ".json", Jason.encode!(%{"lastOnboardingVersion" => "9.9.9"}))

      assert :ok =
               Interactive.ensure(config, cwd: Path.join(tmp, "workspace"), source_dir: beside)

      assert claude_json!(config)["lastOnboardingVersion"] == "9.9.9"
    end

    test "an unparseable version from someone else's file does not crash a launch", %{
      config: config,
      source: source,
      tmp: tmp
    } do
      File.write!(
        Path.join(source, ".claude.json"),
        Jason.encode!(%{"lastOnboardingVersion" => "not-a-version"})
      )

      assert :ok =
               Interactive.ensure(config, cwd: Path.join(tmp, "workspace"), source_dir: source)

      assert is_binary(claude_json!(config)["lastOnboardingVersion"])
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

      assert "Edit(#{checkout}/**)" in deny

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

  describe "Remote Control eligibility cache (bd-cdretj)" do
    test "mode B copies the operator's oauthAccount and GrowthBook cache so --remote-control's startup check has something to read",
         %{config: config, source: source, tmp: tmp} do
      File.write!(
        Path.join(source, ".claude.json"),
        Jason.encode!(%{
          "oauthAccount" => %{"organizationUuid" => "org-123"},
          "cachedGrowthBookFeatures" => %{"tengu_ccr_bridge" => true},
          "cachedGrowthBookFeaturesAt" => 1_789_659_549_691
        })
      )

      assert :ok =
               Interactive.ensure(config,
                 cwd: Path.join(tmp, "workspace"),
                 source_dir: source,
                 auth_mode: :seeded_credentials
               )

      json = claude_json!(config)
      assert json["oauthAccount"] == %{"organizationUuid" => "org-123"}
      assert json["cachedGrowthBookFeatures"] == %{"tengu_ccr_bridge" => true}
      assert json["cachedGrowthBookFeaturesAt"] == 1_789_659_549_691
    end

    test "mode A never seeds the eligibility cache alongside no credentials", %{
      config: config,
      source: source,
      tmp: tmp
    } do
      File.write!(
        Path.join(source, ".claude.json"),
        Jason.encode!(%{"oauthAccount" => %{"organizationUuid" => "org-123"}})
      )

      assert :ok =
               Interactive.ensure(config,
                 cwd: Path.join(tmp, "workspace"),
                 source_dir: source,
                 auth_mode: :oauth_token
               )

      refute Map.has_key?(claude_json!(config), "oauthAccount")
    end

    test "never overwrites what Claude Code has already fetched and written back on a live session",
         %{config: config, source: source, tmp: tmp} do
      File.write!(
        Path.join(source, ".claude.json"),
        Jason.encode!(%{"oauthAccount" => %{"organizationUuid" => "operator-org"}})
      )

      File.mkdir_p!(config)

      File.write!(
        Path.join(config, ".claude.json"),
        Jason.encode!(%{"oauthAccount" => %{"organizationUuid" => "session-live-org"}})
      )

      assert :ok =
               Interactive.ensure(config,
                 cwd: Path.join(tmp, "workspace"),
                 source_dir: source,
                 auth_mode: :seeded_credentials
               )

      assert claude_json!(config)["oauthAccount"] == %{"organizationUuid" => "session-live-org"}
    end
  end

  # bd-5xlkkj — the post-merge live check of phase 5 found a freshly provisioned
  # session still stopping on two prompts nobody was there to answer, and running
  # under the *headless worker's* profile. These pin the fixes against the keys
  # Claude Code 2.1.272 actually reads (verified against the installed binary:
  # `bO=["acceptEdits","auto","bypassPermissions","default","dontAsk","plan"]`,
  # and `enabledMcpjsonServers` / `skipAutoPermissionPrompt` in the settings
  # schema).
  describe "first-launch prompts (bd-5xlkkj)" do
    test "pre-approves the session's project MCP server in the user settings", %{
      config: config,
      tmp: tmp
    } do
      assert :ok =
               Interactive.ensure(config,
                 cwd: Path.join(tmp, "workspace"),
                 source_dir: nil,
                 mcp_servers: ["arbiter"]
               )

      assert settings!(config)["enabledMcpjsonServers"] == ["arbiter"]
    end

    test "pre-approves it in .claude.json's project entry too", %{config: config, tmp: tmp} do
      cwd = Path.join(tmp, "workspace")

      assert :ok = Interactive.ensure(config, cwd: cwd, source_dir: nil, mcp_servers: ["arbiter"])

      assert claude_json!(config)["projects"][cwd]["enabledMcpjsonServers"] == ["arbiter"]
    end

    test "omits the pre-approval entirely when the session has no MCP server", %{
      config: config,
      tmp: tmp
    } do
      cwd = Path.join(tmp, "workspace")

      assert :ok = Interactive.ensure(config, cwd: cwd, source_dir: nil, mcp_servers: [])

      refute Map.has_key?(settings!(config), "enabledMcpjsonServers")
      refute Map.has_key?(claude_json!(config)["projects"][cwd], "enabledMcpjsonServers")
    end

    test "launches in auto mode, never bypassPermissions", %{config: config, tmp: tmp} do
      assert :ok = Interactive.ensure(config, cwd: Path.join(tmp, "workspace"), source_dir: nil)

      settings = settings!(config)

      assert settings["permissions"]["defaultMode"] == "auto"
      refute settings["permissions"]["defaultMode"] == "bypassPermissions"
      refute settings |> Jason.encode!() |> String.contains?("bypassPermissions")
    end

    test "pre-answers the auto-mode notices so auto mode costs no prompt either", %{
      config: config,
      tmp: tmp
    } do
      assert :ok = Interactive.ensure(config, cwd: Path.join(tmp, "workspace"), source_dir: nil)

      # `shouldShowAutoModeEntryWarning` is false when userSettings carries this.
      assert settings!(config)["skipAutoPermissionPrompt"] == true

      # The "auto mode is now the default" notice reads .claude.json.
      json = claude_json!(config)
      assert json["hasSeenAutoDefaultNotice"] == true
      assert json["hasSeenAutoModeEntryWarning"] == true
    end

    test "the interactive profile does not deny Monitor / ScheduleWakeup", %{
      config: config,
      tmp: tmp
    } do
      assert :ok = Interactive.ensure(config, cwd: Path.join(tmp, "workspace"), source_dir: nil)

      deny = settings!(config)["permissions"]["deny"]

      # A coordinator session needs Monitor for the /events stream (docs/monitoring.md).
      refute "Monitor" in deny
      refute "ScheduleWakeup" in deny
    end

    test "but keeps the destructive, secret-read, PR-create and checkout denies", %{
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

      deny = settings!(config)["permissions"]["deny"]

      assert "Bash(rm -rf:*)" in deny
      assert "Read(**/.env)" in deny
      assert "Bash(gh pr create:*)" in deny
      assert "Bash(glab mr create:*)" in deny
      assert "Edit(#{checkout}/**)" in deny
    end

    test "arms the event monitor via a SessionStart hook (bd-aqafdr)", %{
      config: config,
      tmp: tmp
    } do
      assert :ok =
               Interactive.ensure(config,
                 cwd: Path.join(tmp, "workspace"),
                 source_dir: nil,
                 mcp_servers: ["arbiter"]
               )

      settings = settings!(config)
      assert [%{"matcher" => matcher, "hooks" => [hook]}] = settings["hooks"]["SessionStart"]

      # startup, resume AND compaction — a hook that fired only on cold start
      # could be skipped the way a CLAUDE.md section is not.
      assert matcher =~ "startup"
      assert matcher =~ "resume"
      assert matcher =~ "compact"

      assert hook["type"] == "command"
      # Never spawns the monitor loop directly (a hook is a synchronous shell
      # command, not a way to start a background process the model can see) —
      # it injects the instruction to arm it via the model's own Monitor tool.
      output = System.cmd("sh", ["-c", hook["command"]]) |> elem(0) |> Jason.decode!()
      context = output["hookSpecificOutput"]["additionalContext"]

      assert context =~ "Monitor"
      assert context =~ "monitor.sh"
      assert context =~ "coordinator_inbox"
    end

    test "omits the event-monitor hook when the session has no MCP server", %{
      config: config,
      tmp: tmp
    } do
      assert :ok =
               Interactive.ensure(config,
                 cwd: Path.join(tmp, "workspace"),
                 source_dir: nil,
                 mcp_servers: []
               )

      refute Map.has_key?(settings!(config), "hooks")
    end

    test "the session profile ignores the headless worker's install-wide override", %{
      config: config,
      tmp: tmp
    } do
      previous = Application.get_env(:arbiter, :worker_security_policy)

      Application.put_env(:arbiter, :worker_security_policy, %{
        "permissions" => %{"mode" => "bypass"}
      })

      on_exit(fn ->
        if previous do
          Application.put_env(:arbiter, :worker_security_policy, previous)
        else
          Application.delete_env(:arbiter, :worker_security_policy)
        end
      end)

      assert :ok = Interactive.ensure(config, cwd: Path.join(tmp, "workspace"), source_dir: nil)

      assert settings!(config)["permissions"]["defaultMode"] == "auto"
    end
  end
end
