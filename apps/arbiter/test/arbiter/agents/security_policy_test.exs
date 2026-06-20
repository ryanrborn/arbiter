defmodule Arbiter.Agents.SecurityPolicyTest do
  # async: false — one test toggles the :acolyte_security_policy app env.
  use ExUnit.Case, async: false

  alias Arbiter.Agents.SecurityPolicy
  alias Arbiter.Tasks.Workspace

  describe "base/0 and default/0" do
    test "base is the safe baseline: bypass mode, non-empty safe_defaults, worktree fs" do
      p = SecurityPolicy.base()

      assert p.permissions.mode == :bypass
      assert p.permissions.allow == []
      assert p.permissions.deny == []
      refute Enum.empty?(p.permissions.safe_defaults)
      assert :no_destructive_fs in p.permissions.safe_defaults
      assert p.sandbox == %{enabled: true, filesystem: :worktree, network: true}
    end

    test "default/0 overlays the :acolyte_security_policy app env" do
      prev = Application.get_env(:arbiter, :acolyte_security_policy)

      on_exit(fn ->
        case prev do
          nil -> Application.delete_env(:arbiter, :acolyte_security_policy)
          v -> Application.put_env(:arbiter, :acolyte_security_policy, v)
        end
      end)

      Application.put_env(:arbiter, :acolyte_security_policy, %{
        "permissions" => %{"mode" => "strict"},
        "sandbox" => %{"network" => false}
      })

      p = SecurityPolicy.default()
      assert p.permissions.mode == :strict
      assert p.sandbox.network == false
      # safe_defaults still inherited from base (not cleared by the override).
      refute Enum.empty?(p.permissions.safe_defaults)
    end
  end

  describe "resolve/2 precedence" do
    test "nil workspace yields the install default" do
      assert SecurityPolicy.resolve(nil) == SecurityPolicy.default()
    end

    test "workspace config overrides the default and unions deny lists" do
      ws = %Workspace{
        config: %{
          "agent" => %{
            "security" => %{
              "permissions" => %{"mode" => "strict", "deny" => ["Bash(docker:*)"]},
              "sandbox" => %{"network" => false}
            }
          }
        }
      }

      p = SecurityPolicy.resolve(ws)
      assert p.permissions.mode == :strict
      assert "Bash(docker:*)" in p.permissions.deny
      assert p.sandbox.network == false
      assert p.sandbox.filesystem == :worktree
    end

    test "per-dispatch override wins over workspace" do
      ws = %Workspace{
        config: %{"agent" => %{"security" => %{"permissions" => %{"mode" => "strict"}}}}
      }

      p = SecurityPolicy.resolve(ws, %{"permissions" => %{"mode" => "bypass"}})
      assert p.permissions.mode == :bypass
    end

    test "deny unions across workspace and override (additive, not replace)" do
      ws = %Workspace{
        config: %{"agent" => %{"security" => %{"permissions" => %{"deny" => ["A"]}}}}
      }

      p = SecurityPolicy.resolve(ws, %{"permissions" => %{"deny" => ["B"]}})
      assert "A" in p.permissions.deny
      assert "B" in p.permissions.deny
    end

    test "workspace config overrides via security.mode" do
      ws = %Workspace{
        config: %{
          "security" => %{"mode" => "auto"}
        }
      }

      p = SecurityPolicy.resolve(ws)
      assert p.permissions.mode == :auto
    end

    test "workspace config overrides via agent.config.security_mode" do
      ws = %Workspace{
        config: %{
          "agent" => %{
            "config" => %{"security_mode" => "strict"}
          }
        }
      }

      p = SecurityPolicy.resolve(ws)
      assert p.permissions.mode == :strict
    end
  end

  describe "merge/2 leniency" do
    test "ignores unknown / malformed values, keeping the safer inherited value" do
      p =
        SecurityPolicy.merge(SecurityPolicy.base(), %{
          "permissions" => %{"mode" => "nonsense"},
          "sandbox" => %{"filesystem" => "wormhole", "network" => "not-a-bool"}
        })

      # All fall back to base.
      assert p.permissions.mode == :bypass
      assert p.sandbox.filesystem == :worktree
      assert p.sandbox.network == true
    end

    test "safe_defaults are replaced (not unioned) and unknown categories dropped" do
      p =
        SecurityPolicy.merge(SecurityPolicy.base(), %{
          "permissions" => %{"safe_defaults" => ["no_force_push", "bogus_category"]}
        })

      assert p.permissions.safe_defaults == [:no_force_push]
    end

    test "an empty safe_defaults opts the domain out" do
      p =
        SecurityPolicy.merge(SecurityPolicy.base(), %{"permissions" => %{"safe_defaults" => []}})

      assert p.permissions.safe_defaults == []
    end

    test "accepts atom-keyed override maps (app env / programmatic)" do
      p = SecurityPolicy.merge(SecurityPolicy.base(), %{permissions: %{mode: :strict}})
      assert p.permissions.mode == :strict
    end
  end

  describe "summary/1 and one_line/1" do
    test "summary is JSON-friendly and string-keyed" do
      s = SecurityPolicy.summary(SecurityPolicy.base())

      assert s["mode"] == "bypass"
      assert is_list(s["safe_defaults"])
      assert s["sandbox"]["filesystem"] == "worktree"
      assert s["sandbox"]["network"] == true
    end

    test "one_line summarizes mode, fs, net, deny count" do
      line = SecurityPolicy.one_line(SecurityPolicy.base())
      assert line =~ "bypass"
      assert line =~ "fs=worktree"
      assert line =~ "net=on"
    end

    test "one_line shows net=tools-off when network: false" do
      policy = SecurityPolicy.merge(SecurityPolicy.base(), %{sandbox: %{network: false}})
      line = SecurityPolicy.one_line(policy)
      assert line =~ "net=tools-off"
      refute line =~ "net=off"
    end
  end
end
