defmodule Arbiter.Quota.CloudProbeTest do
  @moduledoc """
  Orchestration tests for the periodic Codex / Gemini CLI / Antigravity quota
  prober (bd-ajh7bd). The per-provider persistence + broadcast is covered by
  `Arbiter.Quota.CodexTest` and `Arbiter.Quota.GoogleQuotaTest`; here we only
  assert the prober fans a refresh out to every workspace on a cycle, honours
  the enable switch, and can be driven synchronously.
  """
  use Arbiter.DataCase, async: false

  alias Arbiter.Quota.CloudProbe
  alias Arbiter.Tasks.Workspace

  defp workspace!(name), do: Ash.create!(Workspace, %{name: name})

  defp start_probe(opts) do
    pid = start_supervised!({CloudProbe, Keyword.put(opts, :name, nil)})
    pid
  end

  describe "probe/1" do
    test "refreshes every workspace via the injected refresh_fun" do
      alpha = workspace!("alpha")
      beta = workspace!("beta")
      test_pid = self()

      pid =
        start_probe(
          enabled: true,
          interval_ms: 3_600_000,
          refresh_fun: fn ws_id -> send(test_pid, {:refreshed, ws_id}) end
        )

      CloudProbe.probe(pid)

      assert_receive {:refreshed, ws_a}, 2_000
      assert_receive {:refreshed, ws_b}, 2_000
      assert Enum.sort([ws_a, ws_b]) == Enum.sort([alpha.id, beta.id])
    end

    test "does nothing when disabled" do
      workspace!("gamma")
      test_pid = self()

      pid =
        start_probe(
          enabled: false,
          interval_ms: 3_600_000,
          refresh_fun: fn ws_id -> send(test_pid, {:refreshed, ws_id}) end
        )

      CloudProbe.probe(pid)

      refute_receive {:refreshed, _}, 300
    end

    test "a raising refresh_fun for one workspace doesn't stop the others" do
      workspace!("one")
      workspace!("two")
      test_pid = self()

      pid =
        start_probe(
          enabled: true,
          interval_ms: 3_600_000,
          refresh_fun: fn ws_id ->
            send(test_pid, {:refreshed, ws_id})
            raise "boom"
          end
        )

      CloudProbe.probe(pid)

      # Both workspaces still get their refresh attempted despite one raising.
      assert_receive {:refreshed, _}, 2_000
      assert_receive {:refreshed, _}, 2_000
      # The GenServer survives the crashing children.
      assert Process.alive?(pid)
    end
  end

  describe "probe/1 oauth usage de-duplication (bd-5xuneh)" do
    defp workspace_with_token!(name, token) do
      Ash.create!(Workspace, %{
        name: name,
        worker_env: %{"CLAUDE_CODE_OAUTH_TOKEN" => %{"value" => token}}
      })
    end

    setup do
      Application.put_env(:arbiter, :oauth_usage_http_stub, true)

      on_exit(fn ->
        Application.put_env(:arbiter, :oauth_usage_http_stub, true)
        Arbiter.Quota.OAuthUsage.reset_cooldown!("shared-token")
        Arbiter.Quota.OAuthUsage.reset_cooldown!("distinct-token")
      end)

      :ok
    end

    test "fires exactly one /api/oauth/usage request per distinct token, and writes every workspace in the group",
         context do
      # CloudProbe fans oauth-usage refreshes out onto dynamically-spawned
      # Task processes, so the private per-pid Req.Test ownership (the
      # default) can't see the stub set below from the test process.
      Req.Test.set_req_test_to_shared(context)

      alpha = workspace_with_token!("alpha", "shared-token")
      beta = workspace_with_token!("beta", "shared-token")
      gamma = workspace_with_token!("gamma", "distinct-token")

      test_pid = self()

      Req.Test.stub(Arbiter.Quota.OAuthUsage.HTTP, fn conn ->
        token =
          conn
          |> Plug.Conn.get_req_header("authorization")
          |> List.first()
          |> String.replace_prefix("Bearer ", "")

        send(test_pid, {:oauth_usage_call, token})
        Req.Test.json(conn, %{"seven_day_sonnet" => %{"utilization" => 42}})
      end)

      pid =
        start_probe(
          enabled: true,
          interval_ms: 3_600_000,
          refresh_fun: fn _ws_id -> :ok end
        )

      CloudProbe.probe(pid)

      assert_receive {:oauth_usage_call, "shared-token"}, 2_000
      assert_receive {:oauth_usage_call, "distinct-token"}, 2_000
      # No second call for the shared-token group (alpha + beta covered by one).
      refute_receive {:oauth_usage_call, _}, 300

      for ws <- [alpha, beta, gamma] do
        assert Arbiter.Quota.serialize(ws.id).per_model_utilization == %{"sonnet" => 0.42}
      end
    end
  end

  describe "state/1" do
    test "reports enabled + a probe counter" do
      pid = start_probe(enabled: true, interval_ms: 3_600_000, refresh_fun: fn _ -> :ok end)
      assert %{enabled: true, probe_count: 0} = CloudProbe.state(pid)

      CloudProbe.probe(pid)
      assert %{probe_count: 1} = CloudProbe.state(pid)
    end
  end
end
