defmodule Arbiter.Quota.GateProviderTest do
  @moduledoc """
  Provider-aware dispatch gating (bd-2mpo3f).

  Before this, `Arbiter.Quota.Gate` read only the Anthropic snapshot, so a
  Codex / Gemini / Antigravity worker was dispatched even when that provider was
  out of quota. These specs pin the normalized snapshot (`Gate.Snapshot`), the
  per-provider snapshot lookup (`Quota.latest_for_workspace/2`), and the
  end-to-end hold through `Dispatch.dispatch/2` for an over-quota Codex account.
  """
  use Arbiter.DataCase, async: false

  alias Arbiter.Quota
  alias Arbiter.Quota.AnthropicQuota
  alias Arbiter.Quota.CodexQuota
  alias Arbiter.Quota.Gate
  alias Arbiter.Quota.Gate.Snapshot
  alias Arbiter.Quota.GoogleQuota
  alias Arbiter.Tasks.Issue
  alias Arbiter.Tasks.Workspace
  alias Arbiter.Worker
  alias Arbiter.Workflows.DispatchQueue
  alias Arbiter.Workflows.DispatchQueueSupervisor

  defp ws(config \\ %{}), do: %Workspace{id: "ws-x", config: config}

  defp now, do: DateTime.utc_now() |> DateTime.truncate(:second)

  defp ahead(secs),
    do: DateTime.utc_now() |> DateTime.add(secs, :second) |> DateTime.truncate(:second)

  defp behind(secs), do: ahead(-secs)

  defp codex_quota(attrs) do
    %CodexQuota{provider_account_id: "acct-x", provider: "codex", captured_at: now()}
    |> struct(attrs)
  end

  defp google_quota(attrs) do
    %GoogleQuota{provider_account_id: "acct-x", provider: "gemini_cli", captured_at: now()}
    |> struct(attrs)
  end

  # A synthetic Antigravity row with a persisted per-bucket `models` list, in
  # the same shape `Arbiter.Quota.CloudCode.antigravity/1` writes (bd-7qj58o).
  defp antigravity_quota(models) do
    %GoogleQuota{
      provider_account_id: "acct-x",
      provider: "antigravity",
      captured_at: now(),
      reset_at: ahead(3600),
      snapshot: %{"models" => models}
    }
  end

  defp agy_bucket(group, window, remaining_percentage, reset_at) do
    %{
      "model_id" => "#{group}_#{window}",
      "remaining_percentage" => remaining_percentage,
      "reset_at" => reset_at && DateTime.to_iso8601(reset_at)
    }
  end

  describe "Gate.Snapshot.normalize/1" do
    test "nil normalizes to nil (fail-open)" do
      assert Snapshot.normalize(nil) == nil
    end

    test "Anthropic maps the 5h window onto the primary slot" do
      reset = ahead(3600)

      s =
        Snapshot.normalize(%AnthropicQuota{
          provider_account_id: "acct-x",
          provider: "claude",
          status_5h: "allowed",
          utilization_5h: 0.42,
          reset_5h_at: reset,
          overage_status: "in_overage",
          captured_at: now()
        })

      assert s.provider == "claude"
      assert s.utilization == 0.42
      assert s.status == "allowed"
      assert s.reset_at == reset
      assert s.overage_status == "in_overage"
    end

    test "Codex maps the session window and rescales used-percent to a fraction" do
      reset = ahead(3600)

      s =
        Snapshot.normalize(
          codex_quota(%{
            session_used_percent: 92.0,
            session_reset_at: reset,
            limit_reached: false
          })
        )

      assert s.provider == "codex"
      assert_in_delta s.utilization, 0.92, 0.0001
      assert s.reset_at == reset
      # limit_reached: false is plan-allowed, so the status must not read as
      # "not allowed" (which would hold every dispatch).
      refute Gate.over_cap?(
               codex_quota(%{session_used_percent: 10.0, limit_reached: false}),
               ws()
             )
    end

    test "Codex limit_reached surfaces as a not-allowed status" do
      s = Snapshot.normalize(codex_quota(%{limit_reached: true}))
      assert s.status != nil
      assert s.status != "allowed"
    end

    test "Google maps the representative used-percent onto the primary slot" do
      s = Snapshot.normalize(google_quota(%{used_percent: 95.0, reset_at: ahead(600)}))

      assert s.provider == "gemini_cli"
      assert_in_delta s.utilization, 0.95, 0.0001
    end
  end

  describe "Gate.Throttle.check/4 — Codex" do
    test "holds when the session window is at/over the threshold" do
      assert {:hold, reason} =
               Gate.Throttle.check(
                 nil,
                 codex_quota(%{session_used_percent: 92.0, session_reset_at: ahead(3600)}),
                 ws(),
                 []
               )

      assert reason.provider == "codex"
    end

    test "holds when Codex reports limit_reached even at low utilization" do
      assert {:hold, _} =
               Gate.Throttle.check(
                 nil,
                 codex_quota(%{
                   session_used_percent: 3.0,
                   session_reset_at: ahead(3600),
                   limit_reached: true
                 }),
                 ws(),
                 []
               )
    end

    test "allows when there is headroom" do
      assert Gate.Throttle.check(
               nil,
               codex_quota(%{session_used_percent: 12.0, session_reset_at: ahead(3600)}),
               ws(),
               []
             ) == :allow
    end

    test "stale snapshot (session window already reset) fails open" do
      assert Gate.Throttle.check(
               nil,
               codex_quota(%{
                 session_used_percent: 99.0,
                 session_reset_at: behind(60),
                 limit_reached: true
               }),
               ws(),
               []
             ) == :allow
    end

    test "respects a per-workspace threshold override" do
      w = ws(%{"quota" => %{"throttle_threshold" => 0.5}})

      assert {:hold, _} =
               Gate.Throttle.check(
                 nil,
                 codex_quota(%{session_used_percent: 60.0, session_reset_at: ahead(3600)}),
                 w,
                 []
               )
    end
  end

  describe "Gate.Throttle.check/4 — Google (Gemini CLI / Antigravity)" do
    test "holds when the representative model is at/over the threshold" do
      assert {:hold, reason} =
               Gate.Throttle.check(
                 nil,
                 google_quota(%{used_percent: 97.0, reset_at: ahead(3600)}),
                 ws(),
                 []
               )

      assert reason.provider == "gemini_cli"
    end

    test "allows when there is headroom" do
      assert Gate.Throttle.check(
               nil,
               google_quota(%{used_percent: 5.0, reset_at: ahead(3600)}),
               ws(),
               []
             ) == :allow
    end

    test "stale snapshot fails open" do
      assert Gate.Throttle.check(
               nil,
               google_quota(%{used_percent: 99.0, reset_at: behind(60)}),
               ws(),
               []
             ) == :allow
    end
  end

  describe "Gate.Throttle.check/4 — Antigravity sub-buckets (bd-7qj58o AC3/AC4)" do
    test "holds when the 5h bucket is at/over cap" do
      quota =
        antigravity_quota([
          agy_bucket("gemini_models", "5h", 3.0, ahead(3600)),
          agy_bucket("gemini_models", "weekly", 50.0, ahead(86_400)),
          agy_bucket("claude_and_gpt_models", "5h", 90.0, ahead(3600)),
          agy_bucket("claude_and_gpt_models", "weekly", 90.0, ahead(86_400))
        ])

      assert {:hold, reason} = Gate.Throttle.check(nil, quota, ws(), [])
      assert reason.window == "5h"
      assert reason.provider == "antigravity"
    end

    test "holds on the weekly bucket per the existing long-window rule, even with 5h headroom" do
      quota =
        antigravity_quota([
          agy_bucket("gemini_models", "5h", 90.0, ahead(3600)),
          agy_bucket("gemini_models", "weekly", 5.0, ahead(86_400)),
          agy_bucket("claude_and_gpt_models", "5h", 90.0, ahead(3600)),
          agy_bucket("claude_and_gpt_models", "weekly", 90.0, ahead(86_400))
        ])

      assert {:hold, reason} = Gate.Throttle.check(nil, quota, ws(), [])
      assert reason.window == "weekly"
    end

    test "allows when every bucket has headroom" do
      quota =
        antigravity_quota([
          agy_bucket("gemini_models", "5h", 80.0, ahead(3600)),
          agy_bucket("gemini_models", "weekly", 80.0, ahead(86_400)),
          agy_bucket("claude_and_gpt_models", "5h", 80.0, ahead(3600)),
          agy_bucket("claude_and_gpt_models", "weekly", 80.0, ahead(86_400))
        ])

      assert Gate.Throttle.check(nil, quota, ws(), []) == :allow
    end

    test "a claude-*/gpt-* model gates on the \"Claude and GPT models\" bucket, not Gemini's" do
      quota =
        antigravity_quota([
          agy_bucket("gemini_models", "5h", 3.0, ahead(3600)),
          agy_bucket("gemini_models", "weekly", 3.0, ahead(86_400)),
          agy_bucket("claude_and_gpt_models", "5h", 80.0, ahead(3600)),
          agy_bucket("claude_and_gpt_models", "weekly", 80.0, ahead(86_400))
        ])

      # The Gemini Models bucket is blown, but this dispatch is routed to a
      # claude-* model — it must read the healthy Claude/GPT bucket, not the
      # unrelated Gemini one.
      assert Gate.Throttle.check(nil, quota, ws(), model: "claude-opus-4-6-thinking") == :allow
    end

    test "a gpt-* model also gates on the \"Claude and GPT models\" bucket" do
      quota =
        antigravity_quota([
          agy_bucket("gemini_models", "5h", 80.0, ahead(3600)),
          agy_bucket("gemini_models", "weekly", 80.0, ahead(86_400)),
          agy_bucket("claude_and_gpt_models", "5h", 3.0, ahead(3600)),
          agy_bucket("claude_and_gpt_models", "weekly", 80.0, ahead(86_400))
        ])

      assert {:hold, reason} = Gate.Throttle.check(nil, quota, ws(), model: "gpt-5.1")
      assert reason.window == "5h"
    end

    test "a gemini-* model gates on the \"Gemini Models\" bucket, not Claude/GPT's" do
      quota =
        antigravity_quota([
          agy_bucket("gemini_models", "5h", 80.0, ahead(3600)),
          agy_bucket("gemini_models", "weekly", 80.0, ahead(86_400)),
          agy_bucket("claude_and_gpt_models", "5h", 3.0, ahead(3600)),
          agy_bucket("claude_and_gpt_models", "weekly", 3.0, ahead(86_400))
        ])

      assert Gate.Throttle.check(nil, quota, ws(), model: "gemini-3.8-flash-medium") == :allow
    end

    test "with no model hint, gates conservatively on the worst of both groups" do
      quota =
        antigravity_quota([
          agy_bucket("gemini_models", "5h", 80.0, ahead(3600)),
          agy_bucket("gemini_models", "weekly", 80.0, ahead(86_400)),
          agy_bucket("claude_and_gpt_models", "5h", 3.0, ahead(3600)),
          agy_bucket("claude_and_gpt_models", "weekly", 80.0, ahead(86_400))
        ])

      assert {:hold, _} = Gate.Throttle.check(nil, quota, ws(), [])
    end

    test "a snapshot with no parseable buckets falls back to the representative figure" do
      quota = antigravity_quota([]) |> struct(used_percent: 97.0, reset_at: ahead(3600))

      assert {:hold, reason} = Gate.Throttle.check(nil, quota, ws(), [])
      assert reason.window == "used"
    end
  end

  describe "Gate.Continue.check/4 — non-Anthropic providers" do
    test "tags overage when Codex is past its cap" do
      assert {:overage, spend} =
               Gate.Continue.check(
                 nil,
                 codex_quota(%{limit_reached: true, session_reset_at: ahead(3600)}),
                 ws(),
                 []
               )

      assert is_float(spend)
    end

    test "does not tag overage merely at the throttle threshold" do
      assert Gate.Continue.check(
               nil,
               codex_quota(%{session_used_percent: 99.0, session_reset_at: ahead(3600)}),
               ws(),
               []
             ) == :allow
    end
  end

  describe "Quota.latest_for_workspace/2 (P5: resolves the workspace to its account)" do
    setup do
      {:ok, workspace} =
        Ash.create(Workspace, %{
          name: "lfp-#{System.unique_integer([:positive])}",
          prefix: "lf#{System.unique_integer([:positive])}"
        })

      {:ok, workspace: workspace}
    end

    test "reads each provider from its own table", %{workspace: workspace} do
      Ash.create!(AnthropicQuota, %{
        provider_account_id: quota_account_id!(workspace.id, "claude"),
        provider: "claude",
        utilization_5h: 0.1,
        captured_at: now()
      })

      Ash.create!(CodexQuota, %{
        provider_account_id: quota_account_id!(workspace.id, "codex"),
        provider: "codex",
        session_used_percent: 91.0,
        captured_at: now()
      })

      # `:gemini` resolves dynamically (bd-7qj58o) to whichever quota code
      # matches the executable that would actually run on this host — seed
      # that code so the test doesn't depend on whether `agy` happens to be
      # on PATH.
      gemini_code = Quota.provider_code(:gemini)

      Ash.create!(GoogleQuota, %{
        provider_account_id: quota_account_id!(workspace.id, gemini_code),
        provider: gemini_code,
        used_percent: 77.0,
        captured_at: now()
      })

      assert %AnthropicQuota{} = Quota.latest_for_workspace(workspace.id, :claude)

      assert %CodexQuota{session_used_percent: 91.0} =
               Quota.latest_for_workspace(workspace.id, :codex)

      assert %GoogleQuota{used_percent: 77.0} =
               Quota.latest_for_workspace(workspace.id, :gemini)

      other_code = if gemini_code == "gemini_cli", do: :antigravity, else: :gemini_cli
      assert Quota.latest_for_workspace(workspace.id, other_code) == nil
      assert Quota.latest_for_workspace(workspace.id, :nonesuch) == nil
    end
  end

  describe "Dispatch.dispatch/2 — Codex over quota" do
    setup do
      # The Codex/Google snapshots come from the CloudProbe, not the Anthropic
      # proxy, so leave the proxy at its test default (disabled) to prove the
      # non-Anthropic gate does not depend on it.
      {:ok, workspace} =
        Ash.create(Workspace, %{
          name: "cxg-#{System.unique_integer([:positive])}",
          prefix: "cx#{System.unique_integer([:positive])}",
          config: %{
            "agent" => %{"type" => "codex"},
            "quota" => %{"on_exhaustion" => "throttle"}
          }
        })

      {:ok, task} = Ash.create(Issue, %{title: "codex work", workspace_id: workspace.id})

      on_exit(fn ->
        if pid = DispatchQueueSupervisor.whereis(workspace.id) do
          if Process.alive?(pid), do: GenServer.stop(pid, :normal)
        end
      end)

      {:ok, workspace: workspace, task: task}
    end

    test "holds the dispatch and queues the intent", %{workspace: workspace, task: task} do
      Ash.create!(CodexQuota, %{
        provider_account_id: quota_account_id!(workspace.id, "codex"),
        provider: "codex",
        session_used_percent: 99.0,
        session_reset_at: ahead(3600),
        limit_reached: true,
        captured_at: now()
      })

      assert {:error, {:quota_held, held_id}} =
               Arbiter.Worker.Dispatch.dispatch(task.id, start_driver: false)

      assert held_id == task.id

      {:ok, reloaded} = Ash.get(Issue, task.id)
      assert reloaded.status == :open
      assert Worker.whereis(task.id) == nil
      assert DispatchQueue.held?(workspace.id, task.id)
    end

    test "a healthy Codex snapshot lets the dispatch through", %{
      workspace: workspace,
      task: task
    } do
      Ash.create!(CodexQuota, %{
        provider_account_id: quota_account_id!(workspace.id, "codex"),
        provider: "codex",
        session_used_percent: 4.0,
        session_reset_at: ahead(3600),
        limit_reached: false,
        captured_at: now()
      })

      assert {:ok, result} =
               Arbiter.Worker.Dispatch.dispatch(task.id, repo: "r", start_driver: false)

      assert result.task.status == :in_progress
    end

    test "an over-quota Anthropic snapshot does NOT hold a Codex dispatch", %{
      workspace: workspace,
      task: task
    } do
      # Anthropic is blown, Codex has headroom — the Codex worker must still run.
      Ash.create!(AnthropicQuota, %{
        provider_account_id: quota_account_id!(workspace.id, "claude"),
        provider: "claude",
        status_5h: "rejected",
        utilization_5h: 0.99,
        reset_5h_at: ahead(3600),
        captured_at: now()
      })

      Ash.create!(CodexQuota, %{
        provider_account_id: quota_account_id!(workspace.id, "codex"),
        provider: "codex",
        session_used_percent: 4.0,
        session_reset_at: ahead(3600),
        captured_at: now()
      })

      assert {:ok, result} =
               Arbiter.Worker.Dispatch.dispatch(task.id, repo: "r", start_driver: false)

      assert result.task.status == :in_progress
    end

    test "an explicit agent_type override picks that provider's snapshot", %{
      workspace: workspace
    } do
      # Workspace default is codex (healthy); the dispatch forces gemini, which
      # is blown — the gate must consult Google, not Codex.
      {:ok, gtask} = Ash.create(Issue, %{title: "gemini work", workspace_id: workspace.id})

      Ash.create!(CodexQuota, %{
        provider_account_id: quota_account_id!(workspace.id, "codex"),
        provider: "codex",
        session_used_percent: 1.0,
        session_reset_at: ahead(3600),
        captured_at: now()
      })

      Ash.create!(GoogleQuota, %{
        provider_account_id: quota_account_id!(workspace.id, Quota.provider_code(:gemini)),
        provider: Quota.provider_code(:gemini),
        used_percent: 99.0,
        reset_at: ahead(3600),
        captured_at: now()
      })

      assert {:error, {:quota_held, _}} =
               Arbiter.Worker.Dispatch.dispatch(gtask.id,
                 start_driver: false,
                 agent_type: :gemini
               )
    end
  end

  describe "Dispatch.dispatch/2 — Antigravity model-hint threading (bd-7qj58o AC4)" do
    # These drive the gate through `Quota.provider_code(:gemini)`, which
    # probes PATH live — pin `agy` onto PATH (mirrors
    # `provider_code_gemini_test.exs`) so the antigravity row these tests
    # seed is actually the one the gate looks up, regardless of whether this
    # host happens to have `agy` installed.
    setup do
      tmp =
        Path.join(
          System.tmp_dir!(),
          "arbiter-dispatch-hint-stub-#{System.unique_integer([:positive])}"
        )

      File.mkdir_p!(tmp)
      old_path = System.get_env("PATH") || ""
      agy_path = Path.join(tmp, "agy")
      File.write!(agy_path, "#!/bin/sh\nexit 0\n")
      File.chmod!(agy_path, 0o755)
      System.put_env("PATH", tmp <> ":" <> old_path)

      on_exit(fn ->
        System.put_env("PATH", old_path)
        File.rm_rf!(tmp)
      end)

      {:ok, workspace} =
        Ash.create(Workspace, %{
          name: "agyh-#{System.unique_integer([:positive])}",
          prefix: "ah#{System.unique_integer([:positive])}",
          config: %{
            "agent" => %{"type" => "gemini", "config" => %{"model_tier" => "premium"}},
            "routing" => %{
              "policy" => "by_priority",
              "rules" => %{"P0" => %{"model" => "claude-opus-4-6-thinking"}}
            },
            "quota" => %{"on_exhaustion" => "throttle"}
          }
        })

      {:ok, task} =
        Ash.create(Issue, %{
          title: "agy flagship work",
          workspace_id: workspace.id,
          priority: 0
        })

      on_exit(fn ->
        if pid = DispatchQueueSupervisor.whereis(workspace.id) do
          if Process.alive?(pid), do: GenServer.stop(pid, :normal)
        end
      end)

      {:ok, workspace: workspace, task: task}
    end

    test "a routing-pinned config[\"model\"] gates the Claude/GPT bucket, not model_tier's Gemini one (finding 1)",
         %{workspace: workspace, task: task} do
      # `model_tier` resolves to a Gemini model ("premium" → gemini-3.1-pro-high),
      # but the P0 routing rule pins `config["model"]` to a claude-* id, which
      # wins per `Gemini.resolve_model/2`'s own precedence. The Gemini bucket
      # has headroom while Claude/GPT is blown — a hint that only looked at
      # model_tier would fail open here.
      Ash.create!(GoogleQuota, %{
        provider_account_id: quota_account_id!(workspace.id, "antigravity"),
        provider: "antigravity",
        captured_at: now(),
        reset_at: ahead(3600),
        snapshot: %{
          "models" => [
            agy_bucket("gemini_models", "5h", 80.0, ahead(3600)),
            agy_bucket("gemini_models", "weekly", 80.0, ahead(86_400)),
            agy_bucket("claude_and_gpt_models", "5h", 3.0, ahead(3600)),
            agy_bucket("claude_and_gpt_models", "weekly", 80.0, ahead(86_400))
          ]
        }
      })

      assert {:error, {:quota_held, held_id}} =
               Arbiter.Worker.Dispatch.dispatch(task.id, start_driver: false)

      assert held_id == task.id
      assert DispatchQueue.held?(workspace.id, task.id)
    end

    test "a nested per-provider tier_models override is honoured for the hint (finding 2)", %{} do
      # No routing rule fires, so the hint falls back to model_tier ->
      # tier_models. Scope the override under agent.config["gemini"] the way
      # a multi-provider pool must (bd-a6vu3c) — the hint has to read it via
      # `ProviderConfig.apply_overrides/2`, same as the real dispatch does.
      {:ok, ws} =
        Ash.create(Workspace, %{
          name: "agyo-#{System.unique_integer([:positive])}",
          prefix: "ao#{System.unique_integer([:positive])}",
          config: %{
            "agent" => %{
              "type" => "gemini",
              "config" => %{
                "model_tier" => "premium",
                "gemini" => %{"tier_models" => %{"premium" => "claude-sonnet-4-6"}}
              }
            },
            "quota" => %{"on_exhaustion" => "throttle"}
          }
        })

      on_exit(fn ->
        if pid = DispatchQueueSupervisor.whereis(ws.id) do
          if Process.alive?(pid), do: GenServer.stop(pid, :normal)
        end
      end)

      {:ok, task} =
        Ash.create(Issue, %{title: "agy override work", workspace_id: ws.id, priority: 4})

      Ash.create!(GoogleQuota, %{
        provider_account_id: quota_account_id!(ws.id, "antigravity"),
        provider: "antigravity",
        captured_at: now(),
        reset_at: ahead(3600),
        snapshot: %{
          "models" => [
            agy_bucket("gemini_models", "5h", 80.0, ahead(3600)),
            agy_bucket("gemini_models", "weekly", 80.0, ahead(86_400)),
            agy_bucket("claude_and_gpt_models", "5h", 3.0, ahead(3600)),
            agy_bucket("claude_and_gpt_models", "weekly", 80.0, ahead(86_400))
          ]
        }
      })

      assert {:error, {:quota_held, held_id}} =
               Arbiter.Worker.Dispatch.dispatch(task.id, start_driver: false)

      assert held_id == task.id
      assert DispatchQueue.held?(ws.id, task.id)
    end
  end

  describe "Workflows.QuotaGate.Default — provider-aware cap clamp" do
    alias Arbiter.Workflows.QuotaGate

    defp provider_workspace(type) do
      {:ok, workspace} =
        Ash.create(Workspace, %{
          name: "qgd-#{System.unique_integer([:positive])}",
          prefix: "qg#{System.unique_integer([:positive])}",
          config: %{"agent" => %{"type" => type}}
        })

      workspace
    end

    test "holds when the workspace's default provider (codex) is over the ceiling" do
      workspace = provider_workspace("codex")

      Ash.create!(CodexQuota, %{
        provider_account_id: quota_account_id!(workspace.id, "codex"),
        provider: "codex",
        session_used_percent: 93.0,
        session_reset_at: ahead(3600),
        captured_at: now()
      })

      assert QuotaGate.Default.quota_headroom(workspace.id) == 0
    end

    test "allows when the codex workspace has headroom" do
      workspace = provider_workspace("codex")

      Ash.create!(CodexQuota, %{
        provider_account_id: quota_account_id!(workspace.id, "codex"),
        provider: "codex",
        session_used_percent: 20.0,
        session_reset_at: ahead(3600),
        captured_at: now()
      })

      assert QuotaGate.Default.quota_headroom(workspace.id) == :unlimited
    end

    test "a blown Anthropic snapshot does not clamp a codex workspace" do
      workspace = provider_workspace("codex")

      Ash.create!(AnthropicQuota, %{
        provider_account_id: quota_account_id!(workspace.id, "claude"),
        provider: "claude",
        utilization_5h: 0.99,
        status_5h: "rejected",
        captured_at: now()
      })

      assert QuotaGate.Default.quota_headroom(workspace.id) == :unlimited
    end
  end

  describe "DispatchQueue drain — per-provider snapshots" do
    test "a Codex-held intent drains when Codex regains headroom" do
      Application.put_env(:arbiter, :test_dispatch_pid, self())
      on_exit(fn -> Application.delete_env(:arbiter, :test_dispatch_pid) end)

      {:ok, workspace} =
        Ash.create(Workspace, %{
          name: "cxd-#{System.unique_integer([:positive])}",
          prefix: "cd#{System.unique_integer([:positive])}",
          config: %{
            "agent" => %{"type" => "codex"},
            "quota" => %{"on_exhaustion" => "throttle"}
          }
        })

      {:ok, pid} =
        DispatchQueueSupervisor.start_dispatch_queue(workspace.id,
          dispatcher: __MODULE__.RecordingDispatcher,
          auto_subscribe: false
        )

      on_exit(fn -> if Process.alive?(pid), do: GenServer.stop(pid, :normal) end)

      {:ok, task} = Ash.create(Issue, %{title: "codex drain", workspace_id: workspace.id})

      Ash.create!(CodexQuota, %{
        provider_account_id: quota_account_id!(workspace.id, "codex"),
        provider: "codex",
        session_used_percent: 99.0,
        session_reset_at: ahead(3600),
        limit_reached: true,
        captured_at: now()
      })

      assert {:error, {:quota_held, _}} =
               Arbiter.Worker.Dispatch.dispatch(task.id, start_driver: false)

      assert length(DispatchQueue.state(pid).items) == 1

      # Codex frees up — the drain must re-check the CODEX table, not Anthropic.
      Ash.create!(CodexQuota, %{
        provider_account_id: quota_account_id!(workspace.id, "codex"),
        provider: "codex",
        session_used_percent: 5.0,
        session_reset_at: ahead(3600),
        limit_reached: false,
        captured_at: now()
      })

      :ok = DispatchQueue.drain(pid)

      assert_receive {:dispatched, dispatched_id, _opts}, 1000
      assert dispatched_id == task.id
      assert DispatchQueue.state(pid).items == []
    end
  end

  defmodule RecordingDispatcher do
    @moduledoc false
    def dispatch(task_id, opts) do
      if pid = Application.get_env(:arbiter, :test_dispatch_pid),
        do: send(pid, {:dispatched, task_id, opts})

      {:ok, %{task_id: task_id}}
    end
  end
end
