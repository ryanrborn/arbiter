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

  describe "probe/1 oauth usage polling (bd-4fbpto)" do
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

        for token <- ["shared-token", "distinct-token", "credentials-file-token", "solo-token"] do
          Arbiter.Quota.OAuthUsage.reset_cooldown!(token)
        end
      end)

      :ok
    end

    # bd-4fbpto: the workspace `worker_env` token bd-5xuneh started passing
    # explicitly is scope/rate-limited for `/api/oauth/usage` and every poll
    # using it silently failed. This asserts the fix — CloudProbe never
    # resolves or sends a per-workspace token; it lets
    # `Arbiter.Quota.OAuthUsage.fetch/1`'s own default (the credentials file)
    # authenticate the one account-wide call, and every workspace's `worker_env`
    # token (distinct or shared) is irrelevant to the request that goes out.
    test "fires exactly one /api/oauth/usage request per cycle, ignoring per-workspace tokens, and writes every workspace",
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
          refresh_fun: fn _ws_id -> :ok end,
          oauth_opts: [token: "credentials-file-token"]
        )

      CloudProbe.probe(pid)

      assert_receive {:oauth_usage_call, "credentials-file-token"}, 2_000
      # Exactly one call for the whole cycle — neither workspace token is ever sent.
      refute_receive {:oauth_usage_call, _}, 300

      for ws <- [alpha, beta, gamma] do
        assert Arbiter.Quota.serialize(ws.id).per_model_utilization == %{"sonnet" => 0.42}
      end
    end

    # bd-b0zody: the probe cycle is the *only* thing keeping Claude's snapshot
    # current for a fleet making no proxied traffic, so a probe must land the
    # columns the dispatch gate reads — not just the per-model garnish.
    test "a probe cycle writes the primary gate columns with the poll's provenance",
         context do
      Req.Test.set_req_test_to_shared(context)

      ws = workspace_with_token!("solo", "shared-token")
      resets_at = DateTime.utc_now() |> DateTime.add(3600, :second) |> DateTime.to_iso8601()

      Req.Test.stub(Arbiter.Quota.OAuthUsage.HTTP, fn conn ->
        Req.Test.json(conn, %{
          "five_hour" => %{"utilization" => 91, "resets_at" => resets_at},
          "seven_day" => %{"utilization" => 12, "resets_at" => resets_at},
          "limits" => [%{"group" => "session", "is_active" => true}]
        })
      end)

      :ok = Phoenix.PubSub.subscribe(Arbiter.PubSub, "quota:#{ws.id}")

      pid =
        start_probe(
          enabled: true,
          interval_ms: 3_600_000,
          refresh_fun: fn _ws_id -> :ok end,
          oauth_opts: [token: "credentials-file-token"]
        )

      CloudProbe.probe(pid)

      assert_receive {:quota_updated, _ws_id, %{utilization_5h: 0.91}}, 2_000

      q = Arbiter.Quota.latest(ws.id)
      assert q.status_5h == "allowed"
      assert q.utilization_7d == 0.12
      assert q.representative_claim == "five_hour"
      assert q.capture_source == "oauth_poll"
      refute Arbiter.Quota.Gate.stale?(q)
      # 0.91 is past the 0.85 5h ceiling: a polled row alone holds dispatch.
      assert %{window: "5h", signal: :utilization} = Arbiter.Quota.Gate.gating_window(q, nil)
    end

    # Acceptance criterion 2 (bd-4fbpto): the snapshot must keep advancing on
    # the probe's own cadence, not just recover once — two consecutive cycles,
    # two consecutive `captured_at` bumps.
    test "two consecutive probe cycles each advance captured_at and keep capture_source == oauth_poll",
         context do
      Req.Test.set_req_test_to_shared(context)
      ws = workspace_with_token!("solo", "shared-token")

      stub_utilization = fn util ->
        Req.Test.stub(Arbiter.Quota.OAuthUsage.HTTP, fn conn ->
          Req.Test.json(conn, %{"five_hour" => %{"utilization" => util}})
        end)
      end

      :ok = Phoenix.PubSub.subscribe(Arbiter.PubSub, "quota:#{ws.id}")

      pid =
        start_probe(
          enabled: true,
          interval_ms: 3_600_000,
          refresh_fun: fn _ws_id -> :ok end,
          oauth_opts: [token: "credentials-file-token"]
        )

      stub_utilization.(10)
      CloudProbe.probe(pid)
      assert_receive {:quota_updated, _ws_id, %{utilization_5h: 0.10}}, 2_000
      first = Arbiter.Quota.latest(ws.id)
      assert first.capture_source == "oauth_poll"

      # Backdate the first row's `captured_at` (second-resolution) into a
      # distinct second so "advances" is unambiguous, matching acceptance
      # criterion 2's "show two consecutive cycles advancing" — without
      # sleeping past a real second boundary (see quota_test.exs for the same
      # pattern).
      backdated = DateTime.add(first.captured_at, -2, :second)

      {:ok, _} =
        Arbiter.Repo.query(
          "UPDATE anthropic_quotas SET captured_at = ? WHERE workspace_id = ? AND provider = 'claude'",
          [backdated, ws.id]
        )

      first = %{first | captured_at: backdated}

      stub_utilization.(20)
      CloudProbe.probe(pid)
      assert_receive {:quota_updated, _ws_id, %{utilization_5h: 0.20}}, 2_000
      second = Arbiter.Quota.latest(ws.id)
      assert second.capture_source == "oauth_poll"
      assert DateTime.compare(second.captured_at, first.captured_at) == :gt
    end

    # `CloudProbe.probe/1` only blocks for the synchronous fan-out; the
    # oauth-usage poll itself completes on a spawned Task, which reports back
    # to the `CloudProbe` GenServer via `handle_info`. The stub's
    # `:oauth_call_made` only proves the HTTP call landed, not that the
    # GenServer has processed the result yet (`Logger.warning` + `send/2`
    # still have to happen on the Task first) — so after it fires, poll the
    # GenServer's own state (via a synchronous call, serialized behind
    # whatever is already in its mailbox) until `oauth_consecutive_failures`
    # reaches `expected_failures`, rather than guessing a sleep duration.
    defp await_oauth_cycle(pid, expected_failures) do
      assert_receive :oauth_call_made, 2_000
      wait_until(fn -> CloudProbe.state(pid).oauth_consecutive_failures == expected_failures end)
    end

    defp wait_until(fun, timeout_ms \\ 2_000) do
      deadline = System.monotonic_time(:millisecond) + timeout_ms
      do_wait_until(fun, deadline)
    end

    defp do_wait_until(fun, deadline) do
      cond do
        fun.() ->
          :ok

        System.monotonic_time(:millisecond) >= deadline ->
          flunk("condition not met within #{deadline}ms")

        true ->
          Process.sleep(5)
          do_wait_until(fun, deadline)
      end
    end

    test "a failed poll is logged at warning, not swallowed at debug", context do
      Req.Test.set_req_test_to_shared(context)
      ws = workspace_with_token!("solo", "shared-token")
      test_pid = self()

      Req.Test.stub(Arbiter.Quota.OAuthUsage.HTTP, fn conn ->
        send(test_pid, :oauth_call_made)
        Plug.Conn.send_resp(conn, 429, "")
      end)

      pid =
        start_probe(
          enabled: true,
          interval_ms: 3_600_000,
          refresh_fun: fn _ws_id -> :ok end,
          oauth_opts: [token: "solo-token"]
        )

      log =
        ExUnit.CaptureLog.capture_log([level: :warning], fn ->
          CloudProbe.probe(pid)
          await_oauth_cycle(pid, 1)
        end)

      assert log =~ "oauth usage refresh"
      assert log =~ ws.id
    end

    test "escalates to the coordinator mailbox after the consecutive-failure threshold, once",
         context do
      Req.Test.set_req_test_to_shared(context)
      _ws = workspace_with_token!("solo", "shared-token")
      test_pid = self()

      Req.Test.stub(Arbiter.Quota.OAuthUsage.HTTP, fn conn ->
        send(test_pid, :oauth_call_made)
        Plug.Conn.send_resp(conn, 429, "")
      end)

      pid =
        start_probe(
          enabled: true,
          interval_ms: 3_600_000,
          refresh_fun: fn _ws_id -> :ok end,
          oauth_opts: [token: "solo-token"]
        )

      ExUnit.CaptureLog.capture_log(fn ->
        for n <- 1..3 do
          # Each cycle must hit the network (and re-trigger the stub's 429) to
          # be an independent, observable failure — without this reset, the
          # 180s cooldown after cycle 1's real 429 would short-circuit cycles
          # 2-3 straight to `{:error, :cooling_down}` with no HTTP call to
          # synchronize on.
          Arbiter.Quota.OAuthUsage.reset_cooldown!("solo-token")
          CloudProbe.probe(pid)
          await_oauth_cycle(pid, n)
        end
      end)

      coordinator = Arbiter.Messages.Message.coordinator_ref()
      [msg] = Arbiter.Messages.Message.inbox(coordinator)
      assert msg.kind == :escalation
      assert msg.subject =~ "quota poll failing"

      # A fourth consecutive failure does not raise a second mailbox item.
      ExUnit.CaptureLog.capture_log(fn ->
        Arbiter.Quota.OAuthUsage.reset_cooldown!("solo-token")
        CloudProbe.probe(pid)
        await_oauth_cycle(pid, 4)
      end)

      assert length(Arbiter.Messages.Message.inbox(coordinator)) == 1
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
