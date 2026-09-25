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

    test "strict -> no flag (bd-25ivqe: --sandbox drops the allowlist gate, see moduledoc)" do
      assert Security.permission_argv(mode("strict")) == []
    end
  end

  describe "tool_permission/1 — the agy `toolPermission` value" do
    test "strict never resolves to always-proceed (bd-7s29yq AC1)" do
      refute Security.tool_permission(mode("strict")) == "always-proceed"
    end

    test "strict resolves to proceed-in-sandbox, not agy's own `strict` value (bd-25ivqe)" do
      # agy's `toolPermission: "strict"` auto-denies every tool call in headless
      # mode regardless of `permissions.allow` content — confirmed live against
      # the installed agy 1.2.8: a bare `command(arb)`, a wildcard `command(*)`,
      # and even the literal full command string all still came back
      # `permission check failed for unsandboxed ...` under `"strict"`.
      # `"proceed-in-sandbox"` is the value that actually consults
      # `permissions.allow` headlessly (confirmed live the same way: the exact
      # same settings document, only `toolPermission` changed, let an
      # allow-listed command through and denied a non-allow-listed one).
      assert Security.tool_permission(mode("strict")) == "proceed-in-sandbox"
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

    test "strict mode reports toolPermission proceed-in-sandbox, not the inherited always-proceed" do
      settings = Security.settings(mode("strict"))

      assert settings["toolPermission"] == "proceed-in-sandbox"
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

    test "strict mode always allows the worker-protocol bootstrap commands (bd-25ivqe AC1)" do
      settings = Security.settings(mode("strict"))
      allow = settings["permissions"]["allow"]
      deny = settings["permissions"]["deny"]

      assert "command(arb)" in allow
      assert "command(git status)" in allow
      assert "command(git diff)" in allow
      assert "command(git log)" in allow

      # The bootstrap baseline widens `allow` with read/exec commands only —
      # it must never carry an out-of-worktree write, so `write_file(/etc/**)`
      # stays denied under :strict the same way it does under :bypass.
      assert "write_file(/etc/**)" in deny
      refute Enum.any?(allow, &String.starts_with?(&1, "write_file("))
    end

    test "the bootstrap baseline is present alongside operator allow rules, not replaced by them" do
      p = policy(%{"permissions" => %{"mode" => "strict", "allow" => ["Bash(mix test:*)"]}})
      allow = Security.settings(p)["permissions"]["allow"]

      assert "command(arb)" in allow
      assert "command(mix test)" in allow
    end

    test "the bootstrap baseline also applies to a worktree-backed review-agent policy" do
      review =
        Arbiter.Worker.Dispatch.review_security_policy(
          SecurityPolicy.merge(SecurityPolicy.base(), %{"permissions" => %{"mode" => "strict"}}),
          review_checkout: %{path: "/tmp/some-review-checkout"}
        )

      allow = Security.allow_rules(review)
      assert "command(arb)" in allow
      assert "command(git status)" in allow
    end

    test "an operator deny still wins over the bootstrap allow baseline (AC2)" do
      p =
        policy(%{
          "permissions" => %{"mode" => "strict", "deny" => ["Bash(arb:*)"]}
        })

      settings = Security.settings(p)
      assert "command(arb)" in settings["permissions"]["allow"]
      assert "command(arb)" in settings["permissions"]["deny"]
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

    test "`pwd` is allowed in every mode, so `pwd && git status` is not soft-denied (bd-7wymls)" do
      allow =
        Security.allow_rules(
          SecurityPolicy.merge(SecurityPolicy.base(), %{"permissions" => %{"mode" => "strict"}})
        )

      assert "command(pwd)" in allow
      # Deliberately NOT a general read escape hatch.
      refute "command(cat)" in allow
      refute "command(ls)" in allow
    end

    test "rules with no agy analogue are dropped rather than emitted verbatim" do
      # Monitor / ScheduleWakeup are Claude tool names; agy's rule grammar has
      # only command()/read_file()/write_file()/url().
      deny = Security.settings(policy())["permissions"]["deny"]

      refute "Monitor" in deny
      refute "ScheduleWakeup" in deny
    end
  end

  describe "bootstrap_command?/1 — is a denied command one the worker protocol requires?" do
    test "the worker-protocol commands are required" do
      assert Security.bootstrap_command?("arb inbox bd-3a5qr2")
      assert Security.bootstrap_command?("arb")
      assert Security.bootstrap_command?("git status")
      assert Security.bootstrap_command?("git diff --stat main..HEAD")
      assert Security.bootstrap_command?("  git log --oneline -5")
    end

    test "anything else is not — including a chain that merely starts with an allowed command" do
      refute Security.bootstrap_command?("pwd && git status")
      refute Security.bootstrap_command?("echo probe > /tmp/x")
      refute Security.bootstrap_command?("git push origin main")
      refute Security.bootstrap_command?("arbiter-thing")
      refute Security.bootstrap_command?("git statusx")
      refute Security.bootstrap_command?("arb inbox && rm -rf .")
      refute Security.bootstrap_command?(nil)
      refute Security.bootstrap_command?("")
    end
  end

  describe "settings_json/2" do
    test "is pretty-printed, decodable JSON" do
      json = Security.settings_json(mode("strict"))
      assert {:ok, decoded} = Jason.decode(json)
      assert decoded["toolPermission"] == "proceed-in-sandbox"
    end
  end

  # bd-7s29yq / bd-25ivqe. All fixtures below are REAL events captured from
  # the installed `agy` (1.2.8), one line of
  # `agy -p ... --output-format stream-json`, against a `HOME` whose
  # `settings.json` is `Security.settings_json/2`'s own output verbatim:
  #
  #   * agy_init_strict.json          — the `init` event for a `:strict`
  #     policy, argv WITHOUT `--sandbox` (this ticket's fix).
  #   * agy_init_inherited.json       — the pre-fix posture: HOME carrying the
  #     operator's own `~/.gemini/antigravity-cli/settings.json`.
  #   * agy_run_command_allowed.json  — `run_command("arb --version")`
  #     against the bootstrap allow baseline: `state: "DONE"`, real output.
  #   * agy_run_command_denied.json   — `run_command("mix test")`, NOT on the
  #     allow list: `state: "ERROR"`, agy's real denial wording.
  #
  # `agy_init_inherited.json` is the control: it is what every agy worker
  # reported before bd-7s29yq, and it is why the first assertion below is not
  # vacuous. The `run_command` pair is what closes bd-25ivqe's post-merge
  # verification gap — the original fix asserted only on the *generated
  # settings document*, never on agy's actual matching behavior, and that
  # gap is exactly what let a non-functional `toolPermission: "strict"`
  # merge and fail live.
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

  describe "AC6 (post-merge verification gap) — captured `run_command` matching against the generated allow list" do
    test "a bootstrap-allowed command (`arb`) actually runs, not just parses as allowed" do
      event = fixture("agy_run_command_allowed.json")
      step = event["step_update"]

      assert step["state"] == "DONE"
      assert step["tool_name"] == "run_command"
      assert step["tool_info"]["parameters"]["CommandLine"] == "arb --version"
      assert step["tool_info"]["output"] =~ "arb"
    end

    test "a command outside the allow list is auto-denied, not silently permitted" do
      event = fixture("agy_run_command_denied.json")
      step = event["step_update"]

      assert step["state"] == "ERROR"
      assert step["tool_info"]["error"]["message"] =~ "permission check failed"
    end
  end
end
