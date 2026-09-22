defmodule Arbiter.Quota.CloudProbeTest do
  @moduledoc """
  Orchestration tests for the periodic Codex / Gemini CLI / Antigravity quota
  prober (bd-ajh7bd). The per-provider persistence + broadcast is covered by
  `Arbiter.Quota.CodexTest` and `Arbiter.Quota.GoogleQuotaTest`; here we only
  assert the prober fans a refresh out to every workspace on a cycle, honours
  the enable switch, and can be driven synchronously.
  """
  use Arbiter.DataCase, async: false

  alias Arbiter.Agents.CredentialWatchdog
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
        assert Arbiter.Quota.serialize(quota_account_id!(ws.id)).per_model_utilization == %{
                 "sonnet" => 0.42
               }
      end
    end

    # P6 (`docs/provider-account-design.md` §5 row 10, §9): CloudProbe iterates
    # provider accounts, not a single install-wide token — bd-4fbpto's single
    # shared fetch (above) was only correct while the install had one account.
    # Two workspaces on two distinct accounts must each get their own fetch,
    # authenticated with that account's own `cli_credentials_file` credential.
    test "issues one /api/oauth/usage request per distinct account, each with its own credential",
         context do
      alias Arbiter.Accounts.{ProviderAccount, ProviderCredential, WorkspaceProviderAccount}

      Req.Test.set_req_test_to_shared(context)

      account_a = Ash.create!(ProviderAccount, %{provider: :claude, slug: "cp-acct-a"})
      account_b = Ash.create!(ProviderAccount, %{provider: :claude, slug: "cp-acct-b"})

      Ash.create!(ProviderCredential, %{
        provider_account_id: account_a.id,
        kind: :cli_credentials_file,
        env_var: "CLAUDE_CODE_OAUTH_TOKEN",
        fingerprint: "cp-fp-a",
        secret: "cp-token-a"
      })

      Ash.create!(ProviderCredential, %{
        provider_account_id: account_b.id,
        kind: :cli_credentials_file,
        env_var: "CLAUDE_CODE_OAUTH_TOKEN",
        fingerprint: "cp-fp-b",
        secret: "cp-token-b"
      })

      alpha = workspace_with_token!("cp-alpha", "irrelevant")
      beta = workspace_with_token!("cp-beta", "irrelevant")

      Ash.create!(WorkspaceProviderAccount, %{
        workspace_id: alpha.id,
        provider: :claude,
        provider_account_id: account_a.id
      })

      Ash.create!(WorkspaceProviderAccount, %{
        workspace_id: beta.id,
        provider: :claude,
        provider_account_id: account_b.id
      })

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

      on_exit(fn ->
        Arbiter.Quota.OAuthUsage.reset_account_cooldown!(account_a.id)
        Arbiter.Quota.OAuthUsage.reset_account_cooldown!(account_b.id)
      end)

      pid =
        start_probe(
          enabled: true,
          interval_ms: 3_600_000,
          refresh_fun: fn _ws_id -> :ok end,
          oauth_opts: []
        )

      CloudProbe.probe(pid)

      assert_receive {:oauth_usage_call, "cp-token-a"}, 2_000
      assert_receive {:oauth_usage_call, "cp-token-b"}, 2_000
      refute_receive {:oauth_usage_call, _}, 300

      assert Arbiter.Quota.serialize(account_a.id).per_model_utilization == %{"sonnet" => 0.42}
      assert Arbiter.Quota.serialize(account_b.id).per_model_utilization == %{"sonnet" => 0.42}
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

      q = Arbiter.Quota.latest(quota_account_id!(ws.id))
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
      first = Arbiter.Quota.latest(quota_account_id!(ws.id))
      assert first.capture_source == "oauth_poll"

      # Backdate the first row's `captured_at` (second-resolution) into a
      # distinct second so "advances" is unambiguous, matching acceptance
      # criterion 2's "show two consecutive cycles advancing" — without
      # sleeping past a real second boundary (see quota_test.exs for the same
      # pattern).
      backdated = DateTime.add(first.captured_at, -2, :second)

      {:ok, _} =
        Arbiter.Repo.query(
          "UPDATE anthropic_quotas SET captured_at = ? WHERE provider_account_id = ? AND provider = 'claude'",
          [backdated, quota_account_id!(ws.id)]
        )

      first = %{first | captured_at: backdated}

      stub_utilization.(20)
      CloudProbe.probe(pid)
      assert_receive {:quota_updated, _ws_id, %{utilization_5h: 0.20}}, 2_000
      second = Arbiter.Quota.latest(quota_account_id!(ws.id))
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
          # 2-3 straight to `{:error, {:backoff, 429}}` with no HTTP call to
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

  describe "probe/1 oauth usage 401 streak -> CredentialWatchdog (bd-1pmf9h)" do
    defp start_watchdog do
      {:ok, pid} =
        start_supervised(%{
          id: make_ref(),
          start: {CredentialWatchdog, :start_link, [[name: nil, enabled: false]]}
        })

      pid
    end

    setup do
      Application.put_env(:arbiter, :oauth_usage_http_stub, true)

      on_exit(fn ->
        Application.put_env(:arbiter, :oauth_usage_http_stub, true)
        Arbiter.Quota.OAuthUsage.reset_cooldown!("401-token")
      end)

      :ok
    end

    defp stub_status(status) do
      Req.Test.stub(Arbiter.Quota.OAuthUsage.HTTP, fn conn ->
        Plug.Conn.send_resp(conn, status, "")
      end)
    end

    defp stub_ok do
      Req.Test.stub(Arbiter.Quota.OAuthUsage.HTTP, fn conn ->
        Req.Test.json(conn, %{"five_hour" => %{"utilization" => 1}})
      end)
    end

    test "two consecutive 401s trip the watchdog's expired flag for Claude", context do
      Req.Test.set_req_test_to_shared(context)
      _ws = workspace_with_token!("solo", "401-token")
      watchdog = start_watchdog()

      pid =
        start_probe(
          enabled: true,
          interval_ms: 3_600_000,
          refresh_fun: fn _ws_id -> :ok end,
          oauth_opts: [token: "401-token"],
          credential_watchdog: watchdog
        )

      refute CredentialWatchdog.expired?(Arbiter.Agents.Claude, watchdog)

      stub_status(401)

      ExUnit.CaptureLog.capture_log(fn ->
        CloudProbe.probe(pid)
        wait_until(fn -> CloudProbe.state(pid).oauth_consecutive_401s == 1 end)
      end)

      refute CredentialWatchdog.expired?(Arbiter.Agents.Claude, watchdog)

      ExUnit.CaptureLog.capture_log(fn ->
        CloudProbe.probe(pid)
        wait_until(fn -> CloudProbe.state(pid).oauth_consecutive_401s == 2 end)
      end)

      assert CredentialWatchdog.expired?(Arbiter.Agents.Claude, watchdog)
    end

    test "a rate-limited/backoff tick between two 401s does not reset the streak", context do
      Req.Test.set_req_test_to_shared(context)
      _ws = workspace_with_token!("solo", "401-token")
      watchdog = start_watchdog()

      pid =
        start_probe(
          enabled: true,
          interval_ms: 3_600_000,
          refresh_fun: fn _ws_id -> :ok end,
          oauth_opts: [token: "401-token"],
          credential_watchdog: watchdog
        )

      stub_status(401)

      ExUnit.CaptureLog.capture_log(fn ->
        CloudProbe.probe(pid)
        wait_until(fn -> CloudProbe.state(pid).oauth_consecutive_401s == 1 end)
      end)

      # A real 429 in between is a distinct, non-auth signal — it must not
      # erase the 401 streak the way it silently did in production (bd-1pmf9h).
      stub_status(429)

      ExUnit.CaptureLog.capture_log(fn ->
        CloudProbe.probe(pid)
        Process.sleep(50)
      end)

      assert CloudProbe.state(pid).oauth_consecutive_401s == 1
      refute CredentialWatchdog.expired?(Arbiter.Agents.Claude, watchdog)

      # The 429 above put the client on a cooldown, so the *next* tick should
      # hit the client-side `{:backoff, 429}` skip rather than the network at
      # all — stub the transport to fail the test if it's actually called,
      # proving the cooldown short-circuits it, and confirm the 401 streak
      # (the label this PR introduces for that skip) is left untouched.
      Req.Test.stub(Arbiter.Quota.OAuthUsage.HTTP, fn _conn ->
        flunk("expected the client-side cooldown to skip the network call")
      end)

      ExUnit.CaptureLog.capture_log(fn ->
        CloudProbe.probe(pid)
        Process.sleep(50)
      end)

      assert CloudProbe.state(pid).oauth_consecutive_401s == 1
      refute CredentialWatchdog.expired?(Arbiter.Agents.Claude, watchdog)

      Arbiter.Quota.OAuthUsage.reset_cooldown!("401-token")
      stub_status(401)

      ExUnit.CaptureLog.capture_log(fn ->
        CloudProbe.probe(pid)
        wait_until(fn -> CloudProbe.state(pid).oauth_consecutive_401s == 2 end)
      end)

      assert CredentialWatchdog.expired?(Arbiter.Agents.Claude, watchdog)
    end

    test "the streak keeps re-arming past the threshold after a spurious recovery clears the mark (regression)",
         context do
      Req.Test.set_req_test_to_shared(context)
      _ws = workspace_with_token!("solo", "401-token")
      watchdog = start_watchdog()

      pid =
        start_probe(
          enabled: true,
          interval_ms: 3_600_000,
          refresh_fun: fn _ws_id -> :ok end,
          oauth_opts: [token: "401-token"],
          credential_watchdog: watchdog
        )

      stub_status(401)

      ExUnit.CaptureLog.capture_log(fn ->
        CloudProbe.probe(pid)
        wait_until(fn -> CloudProbe.state(pid).oauth_consecutive_401s == 1 end)
        CloudProbe.probe(pid)
        wait_until(fn -> CloudProbe.state(pid).oauth_consecutive_401s == 2 end)
      end)

      assert CredentialWatchdog.expired?(Arbiter.Agents.Claude, watchdog)

      # Simulate the watchdog's own CLI probe reporting a spurious recovery
      # (exactly what happened for 15h straight in the original incident) —
      # this must not permanently blind the 401 streak to further outage.
      :ok = CredentialWatchdog.mark_recovered(Arbiter.Agents.Claude, watchdog)
      _ = :sys.get_state(watchdog)
      refute CredentialWatchdog.expired?(Arbiter.Agents.Claude, watchdog)

      ExUnit.CaptureLog.capture_log(fn ->
        CloudProbe.probe(pid)
        wait_until(fn -> CloudProbe.state(pid).oauth_consecutive_401s == 3 end)
      end)

      assert CredentialWatchdog.expired?(Arbiter.Agents.Claude, watchdog)
    end

    # Regression for the HIGH finding on bd-3j92yv: pre-P6 there was one
    # fetch for the whole fleet, so any fetch error was necessarily a
    # whole-cycle failure. Post-P6 each account fetches independently, so a
    # naive "any success this cycle resets the streak" (as `collapse_uniform
    # _failure/1` + the old uniform-`length/1` check produced) would let a
    # healthy sibling account silently erase a genuinely broken account's
    # 401 streak forever — this proves the fix keeps counting it.
    test "one account 401ing every cycle still trips the watchdog even while a sibling account succeeds",
         context do
      alias Arbiter.Accounts.{ProviderAccount, ProviderCredential, WorkspaceProviderAccount}

      Req.Test.set_req_test_to_shared(context)

      account_broken = Ash.create!(ProviderAccount, %{provider: :claude, slug: "cp-401-broken"})
      account_ok = Ash.create!(ProviderAccount, %{provider: :claude, slug: "cp-401-ok"})

      Ash.create!(ProviderCredential, %{
        provider_account_id: account_broken.id,
        kind: :cli_credentials_file,
        env_var: "CLAUDE_CODE_OAUTH_TOKEN",
        fingerprint: "cp-401-fp-broken",
        secret: "cp-401-token-broken"
      })

      Ash.create!(ProviderCredential, %{
        provider_account_id: account_ok.id,
        kind: :cli_credentials_file,
        env_var: "CLAUDE_CODE_OAUTH_TOKEN",
        fingerprint: "cp-401-fp-ok",
        secret: "cp-401-token-ok"
      })

      ws_broken = workspace_with_token!("cp-401-ws-broken", "irrelevant")
      ws_ok = workspace_with_token!("cp-401-ws-ok", "irrelevant")

      Ash.create!(WorkspaceProviderAccount, %{
        workspace_id: ws_broken.id,
        provider: :claude,
        provider_account_id: account_broken.id
      })

      Ash.create!(WorkspaceProviderAccount, %{
        workspace_id: ws_ok.id,
        provider: :claude,
        provider_account_id: account_ok.id
      })

      watchdog = start_watchdog()

      on_exit(fn ->
        Arbiter.Quota.OAuthUsage.reset_account_cooldown!(account_broken.id)
        Arbiter.Quota.OAuthUsage.reset_account_cooldown!(account_ok.id)
      end)

      Req.Test.stub(Arbiter.Quota.OAuthUsage.HTTP, fn conn ->
        token =
          conn
          |> Plug.Conn.get_req_header("authorization")
          |> List.first()
          |> String.replace_prefix("Bearer ", "")

        if token == "cp-401-token-broken" do
          Plug.Conn.send_resp(conn, 401, "")
        else
          Req.Test.json(conn, %{"five_hour" => %{"utilization" => 1}})
        end
      end)

      pid =
        start_probe(
          enabled: true,
          interval_ms: 3_600_000,
          refresh_fun: fn _ws_id -> :ok end,
          oauth_opts: [],
          credential_watchdog: watchdog
        )

      refute CredentialWatchdog.expired?(Arbiter.Agents.Claude, watchdog)

      ExUnit.CaptureLog.capture_log(fn ->
        CloudProbe.probe(pid)
        wait_until(fn -> CloudProbe.state(pid).oauth_consecutive_401s == 1 end)
      end)

      refute CredentialWatchdog.expired?(Arbiter.Agents.Claude, watchdog)

      ExUnit.CaptureLog.capture_log(fn ->
        CloudProbe.probe(pid)
        wait_until(fn -> CloudProbe.state(pid).oauth_consecutive_401s == 2 end)
      end)

      assert CredentialWatchdog.expired?(Arbiter.Agents.Claude, watchdog)

      # The healthy sibling account kept polling successfully the whole time.
      assert Arbiter.Quota.serialize(account_ok.id).oauth_utilization_5h == 0.01
    end

    test "a success resets the 401 streak", context do
      Req.Test.set_req_test_to_shared(context)
      _ws = workspace_with_token!("solo", "401-token")
      watchdog = start_watchdog()

      pid =
        start_probe(
          enabled: true,
          interval_ms: 3_600_000,
          refresh_fun: fn _ws_id -> :ok end,
          oauth_opts: [token: "401-token"],
          credential_watchdog: watchdog
        )

      stub_status(401)

      ExUnit.CaptureLog.capture_log(fn ->
        CloudProbe.probe(pid)
        wait_until(fn -> CloudProbe.state(pid).oauth_consecutive_401s == 1 end)
      end)

      stub_ok()
      CloudProbe.probe(pid)
      wait_until(fn -> CloudProbe.state(pid).oauth_consecutive_401s == 0 end)

      stub_status(401)

      ExUnit.CaptureLog.capture_log(fn ->
        CloudProbe.probe(pid)
        wait_until(fn -> CloudProbe.state(pid).oauth_consecutive_401s == 1 end)
      end)

      refute CredentialWatchdog.expired?(Arbiter.Agents.Claude, watchdog)
    end
  end

  describe "probe/1 codex 401 streak -> CredentialWatchdog (bd-1fpjgx)" do
    # These drive `note_codex_result/2` directly via the same
    # `{:codex_refresh_result, result}` message `default_refresh/2` sends,
    # decoupled from the real `Arbiter.Quota.Codex` HTTP call (covered
    # separately by `Arbiter.Quota.CodexTest`'s `auth_expired` assertions).
    # "codex 401 streak actually reaches CredentialWatchdog" below proves the
    # two are wired together for real.
    defp codex_401_result,
      do: %{
        codex: nil,
        message: "Codex connected. Usage API temporarily unavailable (401).",
        auth_expired: true
      }

    defp codex_ok_result, do: %{codex: %{plan: "plus"}, message: nil, auth_expired: false}

    test "two consecutive 401s trip the watchdog's expired flag for Codex" do
      watchdog = start_watchdog()

      pid =
        start_probe(
          enabled: true,
          interval_ms: 3_600_000,
          refresh_fun: fn _ws_id -> :ok end,
          credential_watchdog: watchdog
        )

      refute CredentialWatchdog.expired?(Arbiter.Agents.Codex, watchdog)

      CloudProbe.probe(pid)
      send(pid, {:codex_refresh_result, codex_401_result()})
      wait_until(fn -> CloudProbe.state(pid).codex_consecutive_401s == 1 end)
      refute CredentialWatchdog.expired?(Arbiter.Agents.Codex, watchdog)

      CloudProbe.probe(pid)
      send(pid, {:codex_refresh_result, codex_401_result()})
      wait_until(fn -> CloudProbe.state(pid).codex_consecutive_401s == 2 end)
      assert CredentialWatchdog.expired?(Arbiter.Agents.Codex, watchdog)
    end

    # Host-global credentials: several workspaces' independent fetches this
    # cycle report the same 401, but only the first must count.
    test "a second workspace's 401 in the same cycle does not double-count the streak" do
      watchdog = start_watchdog()

      pid =
        start_probe(
          enabled: true,
          interval_ms: 3_600_000,
          refresh_fun: fn _ws_id -> :ok end,
          credential_watchdog: watchdog
        )

      CloudProbe.probe(pid)
      send(pid, {:codex_refresh_result, codex_401_result()})
      send(pid, {:codex_refresh_result, codex_401_result()})
      wait_until(fn -> CloudProbe.state(pid).codex_consecutive_401s == 1 end)
      Process.sleep(50)
      assert CloudProbe.state(pid).codex_consecutive_401s == 1
      refute CredentialWatchdog.expired?(Arbiter.Agents.Codex, watchdog)
    end

    test "a success resets the codex 401 streak" do
      watchdog = start_watchdog()

      pid =
        start_probe(
          enabled: true,
          interval_ms: 3_600_000,
          refresh_fun: fn _ws_id -> :ok end,
          credential_watchdog: watchdog
        )

      CloudProbe.probe(pid)
      send(pid, {:codex_refresh_result, codex_401_result()})
      wait_until(fn -> CloudProbe.state(pid).codex_consecutive_401s == 1 end)

      CloudProbe.probe(pid)
      send(pid, {:codex_refresh_result, codex_ok_result()})
      wait_until(fn -> CloudProbe.state(pid).codex_consecutive_401s == 0 end)

      CloudProbe.probe(pid)
      send(pid, {:codex_refresh_result, codex_401_result()})
      wait_until(fn -> CloudProbe.state(pid).codex_consecutive_401s == 1 end)
      refute CredentialWatchdog.expired?(Arbiter.Agents.Codex, watchdog)
    end

    test "a genuine recovery after expiry calls mark_recovered" do
      watchdog = start_watchdog()

      pid =
        start_probe(
          enabled: true,
          interval_ms: 3_600_000,
          refresh_fun: fn _ws_id -> :ok end,
          credential_watchdog: watchdog
        )

      CloudProbe.probe(pid)
      send(pid, {:codex_refresh_result, codex_401_result()})
      wait_until(fn -> CloudProbe.state(pid).codex_consecutive_401s == 1 end)
      CloudProbe.probe(pid)
      send(pid, {:codex_refresh_result, codex_401_result()})
      wait_until(fn -> CloudProbe.state(pid).codex_consecutive_401s == 2 end)
      assert CredentialWatchdog.expired?(Arbiter.Agents.Codex, watchdog)

      CloudProbe.probe(pid)
      send(pid, {:codex_refresh_result, codex_ok_result()})
      wait_until(fn -> CredentialWatchdog.expired?(Arbiter.Agents.Codex, watchdog) == false end)
    end

    # Proves `default_refresh/2` really sends `{:codex_refresh_result, _}` off
    # the real `Arbiter.Quota.Codex.fetch/2` call, not just that CloudProbe
    # reacts correctly to a hand-built message (covered above).
    test "codex 401 streak actually reaches CredentialWatchdog via the real Codex fetch",
         context do
      Req.Test.set_req_test_to_shared(context)
      ws = workspace!("codex-wired")
      watchdog = start_watchdog()

      auth_path =
        Path.join(
          System.tmp_dir!(),
          "codex_auth_probe_#{System.unique_integer([:positive])}.json"
        )

      File.write!(
        auth_path,
        Jason.encode!(%{"tokens" => %{"access_token" => "tok", "account_id" => "acct"}})
      )

      on_exit(fn -> File.rm(auth_path) end)

      original_codex_cfg = Application.get_env(:arbiter, :codex_quota, [])
      Application.put_env(:arbiter, :codex_quota, auth_path: auth_path)
      Application.put_env(:arbiter, :codex_quota_http_stub, true)

      on_exit(fn ->
        Application.put_env(:arbiter, :codex_quota, original_codex_cfg)
        Application.delete_env(:arbiter, :codex_quota_http_stub)
      end)

      Req.Test.stub(Arbiter.Quota.Codex.HTTP, fn conn ->
        Plug.Conn.send_resp(conn, 401, "")
      end)

      pid = start_probe(enabled: true, interval_ms: 3_600_000, credential_watchdog: watchdog)
      _ws = ws

      CloudProbe.probe(pid)
      wait_until(fn -> CloudProbe.state(pid).codex_consecutive_401s == 1 end)
      CloudProbe.probe(pid)
      wait_until(fn -> CloudProbe.state(pid).codex_consecutive_401s == 2 end)

      assert CredentialWatchdog.expired?(Arbiter.Agents.Codex, watchdog)
    end
  end

  describe "probe/1 antigravity auth-failure streak -> CredentialWatchdog (bd-1fpjgx)" do
    defp antigravity_auth_expired_result,
      do: %{
        provider: "antigravity",
        plan: "Unknown",
        models: [],
        message: "Antigravity CLI (agy) is not authenticated (exit 1); run `agy` to sign in.",
        captured_at: "2026-01-01T00:00:00Z",
        auth_expired: true
      }

    defp antigravity_healthy_result,
      do: %{
        provider: "antigravity",
        plan: "Unknown",
        models: [%{model_id: "gemini_models_5h"}],
        message: nil,
        captured_at: "2026-01-01T00:00:00Z",
        auth_expired: false
      }

    defp antigravity_not_installed_result,
      do: %{
        provider: "antigravity",
        plan: "Unknown",
        models: [],
        message: "Antigravity CLI (agy) is not installed on this host",
        captured_at: "2026-01-01T00:00:00Z",
        auth_expired: false
      }

    test "two consecutive auth failures trip the watchdog's expired flag for Gemini" do
      watchdog = start_watchdog()

      pid =
        start_probe(
          enabled: true,
          interval_ms: 3_600_000,
          refresh_fun: fn _ws_id -> :ok end,
          credential_watchdog: watchdog
        )

      refute CredentialWatchdog.expired?(Arbiter.Agents.Gemini, watchdog)

      CloudProbe.probe(pid)
      send(pid, {:antigravity_refresh_result, antigravity_auth_expired_result()})
      wait_until(fn -> CloudProbe.state(pid).antigravity_consecutive_auth_failures == 1 end)
      refute CredentialWatchdog.expired?(Arbiter.Agents.Gemini, watchdog)

      CloudProbe.probe(pid)
      send(pid, {:antigravity_refresh_result, antigravity_auth_expired_result()})
      wait_until(fn -> CloudProbe.state(pid).antigravity_consecutive_auth_failures == 2 end)
      assert CredentialWatchdog.expired?(Arbiter.Agents.Gemini, watchdog)
    end

    test "a healthy row resets the streak" do
      watchdog = start_watchdog()

      pid =
        start_probe(
          enabled: true,
          interval_ms: 3_600_000,
          refresh_fun: fn _ws_id -> :ok end,
          credential_watchdog: watchdog
        )

      CloudProbe.probe(pid)
      send(pid, {:antigravity_refresh_result, antigravity_auth_expired_result()})
      wait_until(fn -> CloudProbe.state(pid).antigravity_consecutive_auth_failures == 1 end)

      CloudProbe.probe(pid)
      send(pid, {:antigravity_refresh_result, antigravity_healthy_result()})
      wait_until(fn -> CloudProbe.state(pid).antigravity_consecutive_auth_failures == 0 end)

      CloudProbe.probe(pid)
      send(pid, {:antigravity_refresh_result, antigravity_auth_expired_result()})
      wait_until(fn -> CloudProbe.state(pid).antigravity_consecutive_auth_failures == 1 end)
      refute CredentialWatchdog.expired?(Arbiter.Agents.Gemini, watchdog)
    end

    test "a genuine recovery after expiry calls mark_recovered for Gemini" do
      watchdog = start_watchdog()

      pid =
        start_probe(
          enabled: true,
          interval_ms: 3_600_000,
          refresh_fun: fn _ws_id -> :ok end,
          credential_watchdog: watchdog
        )

      CloudProbe.probe(pid)
      send(pid, {:antigravity_refresh_result, antigravity_auth_expired_result()})
      wait_until(fn -> CloudProbe.state(pid).antigravity_consecutive_auth_failures == 1 end)
      CloudProbe.probe(pid)
      send(pid, {:antigravity_refresh_result, antigravity_auth_expired_result()})
      wait_until(fn -> CloudProbe.state(pid).antigravity_consecutive_auth_failures == 2 end)
      assert CredentialWatchdog.expired?(Arbiter.Agents.Gemini, watchdog)

      CloudProbe.probe(pid)
      send(pid, {:antigravity_refresh_result, antigravity_healthy_result()})

      wait_until(fn ->
        CredentialWatchdog.expired?(Arbiter.Agents.Gemini, watchdog) == false
      end)
    end

    # `agy` simply not being installed says nothing about the credential —
    # must not move the streak either way.
    test "agy not installed is neutral, not a recovery or a failure" do
      watchdog = start_watchdog()

      pid =
        start_probe(
          enabled: true,
          interval_ms: 3_600_000,
          refresh_fun: fn _ws_id -> :ok end,
          credential_watchdog: watchdog
        )

      CloudProbe.probe(pid)
      send(pid, {:antigravity_refresh_result, antigravity_auth_expired_result()})
      wait_until(fn -> CloudProbe.state(pid).antigravity_consecutive_auth_failures == 1 end)

      CloudProbe.probe(pid)
      send(pid, {:antigravity_refresh_result, antigravity_not_installed_result()})
      Process.sleep(50)

      assert CloudProbe.state(pid).antigravity_consecutive_auth_failures == 1
      refute CredentialWatchdog.expired?(Arbiter.Agents.Gemini, watchdog)
    end

    # Proves `default_refresh/2` really sends `{:antigravity_refresh_result,
    # _}` off the real `Arbiter.Quota.CloudCode.refresh/3` call.
    test "antigravity auth-failure streak actually reaches CredentialWatchdog via the real agy shell-out",
         context do
      Req.Test.set_req_test_to_shared(context)
      ws = workspace!("agy-wired")
      watchdog = start_watchdog()

      original_agy_cmd = Application.get_env(:arbiter, :agy_cmd)
      # `false` is a real executable (coreutils) that always exits 1 — the
      # same "not authenticated" fixture `CloudCodeTest`'s real shell-out
      # tests use.
      Application.put_env(:arbiter, :agy_cmd, "false")
      on_exit(fn -> Application.put_env(:arbiter, :agy_cmd, original_agy_cmd) end)

      pid = start_probe(enabled: true, interval_ms: 3_600_000, credential_watchdog: watchdog)
      _ws = ws

      CloudProbe.probe(pid)
      wait_until(fn -> CloudProbe.state(pid).antigravity_consecutive_auth_failures == 1 end)
      CloudProbe.probe(pid)
      wait_until(fn -> CloudProbe.state(pid).antigravity_consecutive_auth_failures == 2 end)

      assert CredentialWatchdog.expired?(Arbiter.Agents.Gemini, watchdog)
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
