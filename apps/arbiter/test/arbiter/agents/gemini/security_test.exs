defmodule Arbiter.Agents.Gemini.SecurityTest do
  use ExUnit.Case, async: true

  alias Arbiter.Agents.Gemini.Security
  alias Arbiter.Agents.SecurityPolicy

  defp policy(overrides \\ %{}), do: SecurityPolicy.merge(SecurityPolicy.base(), overrides)

  defp mode(m), do: policy(%{"permissions" => %{"mode" => m}})

  describe "permission_argv/1" do
    test "bypass -> --dangerously-skip-permissions" do
      assert Security.permission_argv(mode("bypass")) == ["--dangerously-skip-permissions"]
    end

    test "auto -> no flag (the generated settings carry the posture)" do
      assert Security.permission_argv(mode("auto")) == []
    end

    test "strict -> --sandbox" do
      assert Security.permission_argv(mode("strict")) == ["--sandbox"]
    end
  end

  describe "tool_permission/1 — the agy `toolPermission` value" do
    test "strict never resolves to always-proceed (bd-7s29yq AC1)" do
      refute Security.tool_permission(mode("strict")) == "always-proceed"
      assert Security.tool_permission(mode("strict")) == "strict"
    end

    test "auto and bypass are always-proceed — headless cannot answer a prompt" do
      assert Security.tool_permission(mode("auto")) == "always-proceed"
      assert Security.tool_permission(mode("bypass")) == "always-proceed"
    end
  end

  describe "settings/2" do
    test "the default (bypass) policy generates a non-empty deny list" do
      settings = Security.settings(policy())

      assert settings["toolPermission"] == "always-proceed"
      assert settings["allowNonWorkspaceAccess"] == false
      assert is_list(settings["permissions"]["deny"])
      assert settings["permissions"]["deny"] != []
    end

    test "strict mode reports toolPermission strict, not the inherited always-proceed" do
      settings = Security.settings(mode("strict"))

      assert settings["toolPermission"] == "strict"
      assert settings["permissions"]["deny"] != []
    end

    test "deny rules are emitted in agy's own grammar, never Claude's" do
      deny = Security.settings(policy())["permissions"]["deny"]

      assert "command(rm -rf)" in deny
      assert "command(git push --force)" in deny
      assert "command(gh pr create)" in deny
      # No Claude-flavoured rule survives the translation.
      refute Enum.any?(deny, &String.starts_with?(&1, "Bash("))
      refute Enum.any?(deny, &String.starts_with?(&1, "Read("))
    end

    test "secret-read denies become read_file rules" do
      deny = Security.settings(policy())["permissions"]["deny"]

      assert "read_file(**/.env)" in deny
      assert "read_file(**/.ssh/**)" in deny
    end

    test "outside-write denies become write_file rules" do
      deny = Security.settings(policy())["permissions"]["deny"]

      assert "write_file(/etc/**)" in deny
    end

    test "operator allow rules are translated too" do
      p = policy(%{"permissions" => %{"mode" => "strict", "allow" => ["Bash(mix test:*)"]}})

      assert "command(mix test)" in Security.settings(p)["permissions"]["allow"]
    end

    test "a policy with network: false denies url(*) as well as the curl/wget commands" do
      p = policy(%{"sandbox" => %{"network" => false}})
      deny = Security.settings(p)["permissions"]["deny"]

      assert "url(*)" in deny
      assert "command(curl)" in deny
    end

    test "network: true leaves url(*) alone" do
      refute "url(*)" in Security.settings(policy())["permissions"]["deny"]
    end

    test "a known worktree is trusted so agy never gates on folder trust" do
      settings = Security.settings(policy(), worktree: "/tmp/wt")
      assert settings["trustedWorkspaces"] == ["/tmp/wt"]
    end

    test "no worktree in hand omits trustedWorkspaces entirely" do
      refute Map.has_key?(Security.settings(policy()), "trustedWorkspaces")
    end

    test "a worktree-backed review spawn's read-only deny survives translation" do
      # Arbiter.Worker.Dispatch.review_security_policy/2 merges these three bare
      # Claude tool names into EVERY worktree-backed review dispatch. They are
      # what makes "you are not the author; do not modify the branch" a property
      # of the spawn; if they are dropped an agy reviewer can rewrite the branch
      # it is reviewing while a Claude reviewer cannot.
      review =
        SecurityPolicy.merge(SecurityPolicy.base(), %{
          "permissions" => %{"deny" => ["Edit", "Write", "NotebookEdit"]}
        })

      assert "write_file(**)" in Security.deny_rules(review)
    end

    test "the exact policy Dispatch.review_security_policy/2 produces denies writes" do
      # Built through Dispatch itself, so a change to the reviewer posture that
      # agy cannot express fails here rather than silently.
      policy =
        Arbiter.Worker.Dispatch.review_security_policy(
          SecurityPolicy.base(),
          review_checkout: %{path: "/tmp/some-review-checkout"}
        )

      assert "write_file(**)" in Security.deny_rules(policy)
    end

    test "bare Read / WebFetch tool names map onto agy's whole-path rules" do
      deny =
        Security.deny_rules(
          SecurityPolicy.merge(SecurityPolicy.base(), %{
            "permissions" => %{"deny" => ["Read", "WebFetch"]}
          })
        )

      assert "read_file(**)" in deny
      assert "url(*)" in deny
    end

    test "a bare tool name in `allow` translates too (load-bearing under :strict)" do
      allow =
        Security.allow_rules(
          SecurityPolicy.merge(SecurityPolicy.base(), %{
            "permissions" => %{"mode" => "strict", "allow" => ["Read", "Edit"]}
          })
        )

      assert "read_file(**)" in allow
      assert "write_file(**)" in allow
    end

    test "rules with no agy analogue are dropped rather than emitted verbatim" do
      # Monitor / ScheduleWakeup are Claude tool names; agy's rule grammar has
      # only command()/read_file()/write_file()/url().
      deny = Security.settings(policy())["permissions"]["deny"]

      refute "Monitor" in deny
      refute "ScheduleWakeup" in deny
    end
  end

  describe "settings_json/2" do
    test "is pretty-printed, decodable JSON" do
      json = Security.settings_json(mode("strict"))
      assert {:ok, decoded} = Jason.decode(json)
      assert decoded["toolPermission"] == "strict"
    end
  end

  # bd-7s29yq AC1. Both fixtures are REAL `init` events captured from the
  # installed `agy` while implementing this ticket, one line of
  # `agy -p ... --output-format stream-json`:
  #
  #   * agy_init_strict.json    — HOME seeded by `Gemini.ConfigDir.ensure/1`
  #     with a `:strict` policy (so `settings.json` came out of
  #     `Security.settings_json/2` verbatim), spawned with `--sandbox`.
  #   * agy_init_inherited.json — the pre-fix posture: HOME carrying the
  #     operator's own `~/.gemini/antigravity-cli/settings.json`.
  #
  # The second one is the control. It is what every agy worker reported before
  # this change, and it is why the first assertion below is not vacuous.
  describe "AC1 — captured agy `init` events" do
    test "a :strict spawn against our generated settings does not report always-proceed" do
      event = fixture("agy_init_strict.json")

      assert event["event"] == "init"
      refute event["init"]["permission_mode"] == "always-proceed"
      assert event["init"]["permission_mode"] == Security.tool_permission(mode("strict"))
    end

    test "the inherited-operator-settings control DOES report always-proceed" do
      assert fixture("agy_init_inherited.json")["init"]["permission_mode"] == "always-proceed"
    end

    defp fixture(name) do
      [__DIR__, "..", "..", "..", "fixtures", name]
      |> Path.join()
      |> Path.expand()
      |> File.read!()
      |> Jason.decode!()
    end
  end
end
