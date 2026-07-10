defmodule Arbiter.Agents.SecurityPolicyTest do
  # async: false — one test toggles the :worker_security_policy app env.
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

    test "default/0 overlays the :worker_security_policy app env" do
      prev = Application.get_env(:arbiter, :worker_security_policy)

      on_exit(fn ->
        case prev do
          nil -> Application.delete_env(:arbiter, :worker_security_policy)
          v -> Application.put_env(:arbiter, :worker_security_policy, v)
        end
      end)

      Application.put_env(:arbiter, :worker_security_policy, %{
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

    test "DEPRECATED: workspace config overrides via security.mode (backward compat only)" do
      ws = %Workspace{
        config: %{
          "security" => %{"mode" => "auto"}
        }
      }

      p = SecurityPolicy.resolve(ws)
      assert p.permissions.mode == :auto
    end

    test "DEPRECATED: workspace config overrides via agent.config.security_mode (backward compat only)" do
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

    test "canonical path: workspace.config[\"agent\"][\"security\"][\"permissions\"][\"mode\"]" do
      ws = %Workspace{
        config: %{
          "agent" => %{
            "security" => %{
              "permissions" => %{"mode" => "strict"}
            }
          }
        }
      }

      p = SecurityPolicy.resolve(ws)
      assert p.permissions.mode == :strict
    end

    test "canonical path takes precedence over deprecated alt paths" do
      ws = %Workspace{
        config: %{
          "agent" => %{
            "security" => %{
              "permissions" => %{"mode" => "auto"}
            },
            "config" => %{"security_mode" => "strict"}
          },
          "security" => %{"mode" => "bypass"}
        }
      }

      p = SecurityPolicy.resolve(ws)
      # Canonical path should win over the alt paths
      assert p.permissions.mode == :auto
    end
  end

  describe "resolve/3 per-repo overrides" do
    # A workspace whose `device` repo runs a stricter posture than the
    # workspace-wide default, and adds an extra deny rule.
    defp multi_repo_ws do
      %Workspace{
        config: %{
          "agent" => %{
            "security" => %{
              "permissions" => %{"mode" => "auto", "deny" => ["Bash(docker:*)"]},
              "sandbox" => %{"network" => true},
              "repos" => %{
                "device" => %{
                  "permissions" => %{"mode" => "strict", "deny" => ["Bash(curl:*)"]},
                  "sandbox" => %{"network" => false}
                }
              }
            }
          }
        }
      }
    end

    test "repo override replaces scalar fields for that repo only" do
      ws = multi_repo_ws()

      device = SecurityPolicy.resolve(ws, %{}, "device")
      assert device.permissions.mode == :strict
      assert device.sandbox.network == false

      # A different repo (no override) sees the workspace-wide posture.
      other = SecurityPolicy.resolve(ws, %{}, "server")
      assert other.permissions.mode == :auto
      assert other.sandbox.network == true
    end

    test "repo override unions deny onto the workspace deny (additive)" do
      ws = multi_repo_ws()
      device = SecurityPolicy.resolve(ws, %{}, "device")

      # Both the workspace-wide and repo-specific deny rules are present.
      assert "Bash(docker:*)" in device.permissions.deny
      assert "Bash(curl:*)" in device.permissions.deny

      # The non-overridden repo carries only the workspace-wide deny.
      other = SecurityPolicy.resolve(ws, %{}, "server")
      assert "Bash(docker:*)" in other.permissions.deny
      refute "Bash(curl:*)" in other.permissions.deny
    end

    test "nil/blank repo resolves identically to resolve/2 (backward compatible)" do
      ws = multi_repo_ws()

      base = SecurityPolicy.resolve(ws)
      assert SecurityPolicy.resolve(ws, %{}, nil) == base
      assert SecurityPolicy.resolve(ws, %{}, "") == base
      # Workspace-wide posture, unaffected by the repo block.
      assert base.permissions.mode == :auto
    end

    test "an unknown repo name falls back to the workspace-wide posture" do
      ws = multi_repo_ws()
      p = SecurityPolicy.resolve(ws, %{}, "does-not-exist")
      assert p.permissions.mode == :auto
      assert p.sandbox.network == true
    end

    test "explicit per-dispatch override still wins over the repo layer" do
      ws = multi_repo_ws()
      p = SecurityPolicy.resolve(ws, %{"permissions" => %{"mode" => "bypass"}}, "device")
      assert p.permissions.mode == :bypass
      # deny from both workspace and repo layers is still unioned under it.
      assert "Bash(docker:*)" in p.permissions.deny
      assert "Bash(curl:*)" in p.permissions.deny
    end

    test "a workspace with no repos block is unaffected by a repo name" do
      ws = %Workspace{
        config: %{"agent" => %{"security" => %{"permissions" => %{"mode" => "strict"}}}}
      }

      assert SecurityPolicy.resolve(ws, %{}, "device") == SecurityPolicy.resolve(ws)
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
