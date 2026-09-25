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

    test "forge-qualified slug matches bare repos key (bd-36p5rh)" do
      ws = multi_repo_ws()

      # Caller has forge-qualified slug; config is keyed by bare name
      device = SecurityPolicy.resolve(ws, %{}, "some-org/device")
      # Should find the per-repo override, not fall back to workspace-wide
      assert device.permissions.mode == :strict
      assert device.sandbox.network == false

      # Non-overridden repo still falls back to workspace-wide
      other = SecurityPolicy.resolve(ws, %{}, "some-org/server")
      assert other.permissions.mode == :auto
      assert other.sandbox.network == true
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

    # bd-4420va: a pinned `safe_defaults` list used to *replace* the baseline
    # wholesale, so a workspace that pinned it before a new category shipped
    # (vstim pinning the 4 categories that existed pre-v0.1.78) silently never
    # got the new ones (:no_public_upload, :no_pr_create, :no_async_wait,
    # :no_gh_publish never applied). The legacy key is now read-but-inert: it
    # no longer narrows the resolved set. `safe_defaults_exclude` is the only
    # supported way to drop a category (see the next describe block).
    test "a legacy pinned safe_defaults list no longer narrows the resolved set" do
      p =
        SecurityPolicy.merge(SecurityPolicy.base(), %{
          "permissions" => %{
            "safe_defaults" => ["no_destructive_fs", "no_force_push", "no_secret_reads", "no_outside_writes"]
          }
        })

      assert :no_public_upload in p.permissions.safe_defaults
      assert :no_pr_create in p.permissions.safe_defaults
      assert :no_async_wait in p.permissions.safe_defaults
      assert :no_gh_publish in p.permissions.safe_defaults
      assert Enum.sort(p.permissions.safe_defaults) == Enum.sort(SecurityPolicy.safe_default_categories())
    end

    test "an empty legacy safe_defaults no longer opts the domain out (must exclude by name now)" do
      p =
        SecurityPolicy.merge(SecurityPolicy.base(), %{"permissions" => %{"safe_defaults" => []}})

      assert Enum.sort(p.permissions.safe_defaults) == Enum.sort(SecurityPolicy.safe_default_categories())
    end

    test "unknown category names in safe_defaults_exclude are dropped" do
      p =
        SecurityPolicy.merge(SecurityPolicy.base(), %{
          "permissions" => %{"safe_defaults_exclude" => ["no_force_push", "bogus_category"]}
        })

      refute :no_force_push in p.permissions.safe_defaults
      assert :no_destructive_fs in p.permissions.safe_defaults
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

  # bd-5xlkkj gave interactive coordinator sessions their own profile. The whole
  # point was that the headless worker's posture does not move with it, so this
  # pins the worker side rather than the new side.
  describe "the headless worker profile is unchanged by the session profile (bd-5xlkkj)" do
    test "base/0 still bypasses the interactive classifier" do
      assert SecurityPolicy.base().permissions.mode == :bypass
      assert SecurityPolicy.default().permissions.mode == :bypass
    end

    test "base/0 still denies the async-wait tools a --print worker cannot use" do
      assert :no_async_wait in SecurityPolicy.base().permissions.safe_defaults

      deny = Arbiter.Agents.Claude.Security.deny_rules(SecurityPolicy.base())
      assert "Monitor" in deny
      assert "ScheduleWakeup" in deny
    end

    test "the worker's generated settings still say bypassPermissions" do
      settings = Arbiter.Agents.Claude.Security.settings(SecurityPolicy.default())
      assert settings["permissions"]["defaultMode"] == "bypassPermissions"
    end
  end

  describe "interactive_session/0 (bd-5xlkkj)" do
    test "runs in auto mode — a human is at the keyboard, so the classifier can ask" do
      assert SecurityPolicy.interactive_session().permissions.mode == :auto
    end

    # bd-80talz: :no_gh_publish is worker-only too. An operator or coordinator
    # session commenting on an issue is ordinary work.
    test "drops only :no_async_wait and :no_gh_publish from the baseline categories" do
      worker = SecurityPolicy.base().permissions.safe_defaults
      session = SecurityPolicy.interactive_session().permissions.safe_defaults

      assert worker -- session == [:no_async_wait, :no_gh_publish]
      assert session -- worker == []
    end

    test "keeps the destructive, secret-read and PR-create denies" do
      deny = Arbiter.Agents.Claude.Security.deny_rules(SecurityPolicy.interactive_session())

      assert "Bash(rm -rf:*)" in deny
      assert "Bash(git push --force:*)" in deny
      assert "Read(**/.env)" in deny
      assert "Edit(~/.ssh/**)" in deny
      assert "Bash(gh pr create:*)" in deny
      assert "Bash(glab mr create:*)" in deny
      refute "Monitor" in deny
      refute "ScheduleWakeup" in deny
    end

    test "denies minting a coordinator token from inside the session" do
      deny = Arbiter.Agents.Claude.Security.deny_rules(SecurityPolicy.interactive_session())

      assert "Bash(arb mcp token mint:*)" in deny
    end

    test "does not add the token-mint deny to the worker baseline" do
      deny = Arbiter.Agents.Claude.Security.deny_rules(SecurityPolicy.base())

      refute "Bash(arb mcp token mint:*)" in deny
    end

    test "reads its own config key, not the worker's" do
      previous = Application.get_env(:arbiter, :worker_security_policy)

      Application.put_env(:arbiter, :worker_security_policy, %{
        "permissions" => %{"mode" => "strict"}
      })

      on_exit(fn ->
        if previous do
          Application.put_env(:arbiter, :worker_security_policy, previous)
        else
          Application.delete_env(:arbiter, :worker_security_policy)
        end
      end)

      assert SecurityPolicy.default().permissions.mode == :strict
      assert SecurityPolicy.interactive_session().permissions.mode == :auto
    end
  end

  # bd-80talz: an agy worker uploaded mockup "screenshots" to files.catbox.moe
  # and a public gist on the operator's account, and tried 0x0.st, transfer.sh
  # and envs.sh. Nothing in the default posture stopped it.
  describe "the public upload/paste host baseline (bd-80talz)" do
    test "is a default safe-default category for workers and sessions alike" do
      assert :no_public_upload in SecurityPolicy.safe_default_categories()
      assert :no_public_upload in SecurityPolicy.base().permissions.safe_defaults
      assert :no_public_upload in SecurityPolicy.resolve(nil).permissions.safe_defaults
      assert :no_public_upload in SecurityPolicy.interactive_session().permissions.safe_defaults
    end

    test "the gist/issue-comment denies bind workers, not interactive sessions" do
      assert :no_gh_publish in SecurityPolicy.resolve(nil).permissions.safe_defaults
      refute :no_gh_publish in SecurityPolicy.interactive_session().permissions.safe_defaults

      worker = Arbiter.Agents.Claude.Security.deny_rules(SecurityPolicy.resolve(nil))
      session = Arbiter.Agents.Claude.Security.deny_rules(SecurityPolicy.interactive_session())

      assert "Bash(gh issue comment:*)" in worker
      assert "Bash(gh gist create:*)" in worker
      refute Enum.any?(session, &(&1 =~ "gh issue comment" or &1 =~ "gh gist"))

      # The host denies still bind the session.
      assert "Bash(curl *catbox.moe*)" in session
      assert "WebFetch(domain:*.catbox.moe)" in session
    end

    test "documents at least the hosts the incident used or tried" do
      hosts = SecurityPolicy.public_upload_hosts()

      for host <- ~w(catbox.moe 0x0.st transfer.sh file.io envs.sh pastebin.com) do
        assert host in hosts, "#{host} missing from public_upload_hosts/0"
      end
    end

    test "lists bare registrable domains, so a subdomain rule can be derived from each" do
      for host <- SecurityPolicy.public_upload_hosts() do
        refute String.contains?(host, ["/", "*", " ", ":"]), "#{inspect(host)} is not a bare host"
      end

      # litterbox is catbox's temporary host, litter.catbox.moe — covered by
      # catbox.moe's subdomain rule rather than listed on its own.
      refute "litter.catbox.moe" in SecurityPolicy.public_upload_hosts()
    end
  end

  # bd-4420va: vstim pinned `agent.security.permissions.safe_defaults` to the
  # 4 categories that existed before v0.1.78 (#2061 / bd-80talz added 4 more).
  # A pinned list used to *replace* the baseline, so vstim silently never got
  # :no_public_upload, :no_pr_create, :no_async_wait or :no_gh_publish, with
  # nothing surfacing the gap. `safe_defaults_exclude` is now the only
  # supported way to drop a category by name.
  describe "a pinned safe_defaults list does not opt a workspace out of new categories (bd-4420va)" do
    @vstim_pinned_config %{
      "agent" => %{
        "security" => %{
          "permissions" => %{
            "safe_defaults" => [
              "no_destructive_fs",
              "no_force_push",
              "no_secret_reads",
              "no_outside_writes"
            ]
          }
        }
      }
    }

    test "resolves :no_public_upload (and every other current default) despite the old pinned list" do
      p = SecurityPolicy.resolve(%{config: @vstim_pinned_config})

      for category <- SecurityPolicy.safe_default_categories() do
        assert category in p.permissions.safe_defaults,
               "expected #{category} to still be resolved for a workspace with an old pinned safe_defaults list"
      end
    end

    test "an explicit safe_defaults_exclude still drops a category by name, and is the only way to" do
      config =
        put_in(
          @vstim_pinned_config,
          ["agent", "security", "permissions", "safe_defaults_exclude"],
          ["no_public_upload"]
        )

      p = SecurityPolicy.resolve(%{config: config})

      refute :no_public_upload in p.permissions.safe_defaults
      # Everything else (including the other categories missing from the
      # legacy pinned list) still resolves.
      assert :no_pr_create in p.permissions.safe_defaults
      assert :no_async_wait in p.permissions.safe_defaults
      assert :no_gh_publish in p.permissions.safe_defaults
    end

    test "the resolved summary names the workspace's excluded/missing default categories" do
      config =
        put_in(
          @vstim_pinned_config,
          ["agent", "security", "permissions", "safe_defaults_exclude"],
          ["no_public_upload", "no_secret_reads"]
        )

      summary = SecurityPolicy.resolve(%{config: config}) |> SecurityPolicy.summary()

      assert Enum.sort(summary["safe_defaults_exclude"]) == ["no_public_upload", "no_secret_reads"]
    end
  end
end
