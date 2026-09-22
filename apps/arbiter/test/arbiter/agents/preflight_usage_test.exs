defmodule Arbiter.Agents.PreflightUsageTest do
  @moduledoc """
  bd-adyhvn acceptance 3: the dispatch auth pre-flight (`claude --print
  --output-format json ping`) writes one `source: :preflight` ledger row per
  call, carrying the task it was checking for when there is one.
  """
  use Arbiter.DataCase, async: false

  alias Arbiter.Agents.Claude
  alias Arbiter.Agents.Preflight
  alias Arbiter.Usage
  alias Arbiter.Usage.Event
  require Ash.Query

  @usage_json ~s({"type":"result","subtype":"success","is_error":false,) <>
                ~s("duration_ms":900,"num_turns":1,"result":"ping","session_id":"sess-pf-1",) <>
                ~s("total_cost_usd":0.0122,) <>
                ~s("usage":{"input_tokens":4,"output_tokens":5,) <>
                ~s("cache_creation_input_tokens":0,"cache_read_input_tokens":38952}})

  # input_tokens 401 / duration_ms 402 are the numbers that `\b401\b` and
  # `\b402\b` in StopReason would read as an auth / payment failure if the
  # structured success payload reached the classifier.
  @trap_json ~s({"type":"result","subtype":"success","is_error":false,) <>
               ~s("duration_ms":402,"result":"ping","session_id":"sess-pf-2",) <>
               ~s("total_cost_usd":0.01,) <>
               ~s("usage":{"input_tokens":401,"output_tokens":3,) <>
               ~s("cache_creation_input_tokens":0,"cache_read_input_tokens":9}})

  defp echo(json), do: ["sh", "-c", "cat <<'JSON'\n#{json}\nJSON"]

  test "records a preflight row with the task it was checking for" do
    assert :ok =
             Preflight.check(Claude,
               probe_command: echo(@usage_json),
               probe_env: [],
               usage_task_id: "bd-pf-target",
               usage_workspace_id: "ws-pf-target"
             )

    [ev] = Event |> Ash.Query.filter(source == :preflight) |> Ash.read!()

    assert ev.task_id == "bd-pf-target"
    assert ev.workspace_id == "ws-pf-target"
    assert ev.cache_read_tokens == 38_952
    assert ev.tokens_in == 4
    assert ev.session_id == "sess-pf-1"
  end

  test "a task-less pre-flight (CredentialWatchdog) still records its spend" do
    assert :ok =
             Preflight.check(Claude,
               probe_command: echo(@usage_json),
               probe_env: [],
               usage_workspace_id: "ws-pf-watchdog"
             )

    [ev] = Event |> Ash.Query.filter(source == :preflight) |> Ash.read!()
    assert ev.task_id == nil

    {:ok, by_task} = Usage.summarize(by: :task, workspace_id: "ws-pf-watchdog")
    assert by_task == []
  end

  test "the structured success payload never trips a provider-error signature" do
    assert :ok =
             Preflight.check(Claude,
               probe_command: echo(@trap_json),
               probe_env: [],
               usage_workspace_id: "ws-pf-trap"
             )

    [ev] = Event |> Ash.Query.filter(source == :preflight) |> Ash.read!()
    assert ev.tokens_in == 401
  end

  test "a real auth failure is still refused, and the attempt is still recorded" do
    assert {:error, reason} =
             Preflight.check(Claude,
               probe_command: [
                 "sh",
                 "-c",
                 "echo 'API Error: 401 Invalid authentication credentials'; exit 1"
               ],
               probe_env: [],
               usage_workspace_id: "ws-pf-401"
             )

    assert reason.category == :auth_expired

    [ev] = Event |> Ash.Query.filter(source == :preflight) |> Ash.read!()
    assert ev.exit_status == 1
    assert ev.tokens_in == nil
  end

  test "an unprobeable adapter writes nothing (no port ran, no spend)" do
    defmodule NoProbeAdapter do
      @moduledoc false
    end

    assert :skipped = Preflight.check(NoProbeAdapter, [])
    assert Event |> Ash.Query.filter(source == :preflight) |> Ash.read!() == []
  end

  # bd-96mn8i round 5 finding 1: every test above replays a hand-built or
  # verbatim-captured fixture through `probe_command:` — proof that the
  # PARSER matches codex's `turn.completed` shape, but not proof that a real
  # `codex exec` invocation reaches that parser end to end. This is that
  # proof: no `probe_command:` override, so `Preflight.check/2` falls
  # through to `Codex.auth_probe_argv/1` and spawns the actual installed
  # `codex` CLI (bd-96mn8i round 3 review finding 1). Opt-in (`:live_codex_cli`,
  # excluded by default in `test/test_helper.exs`) because it spends real
  # quota against whatever account this host is logged into:
  #
  #     mix test --include live_codex_cli test/arbiter/agents/preflight_usage_test.exs
  #
  # Skips (not fails) when this host has no codex CLI on PATH — an
  # environment gap, not a red suite.
  @tag :live_codex_cli
  test "a live codex exec round-trip writes a preflight row with real, non-zero tokens" do
    if System.find_executable("codex") do
      assert :ok =
               Preflight.check(Arbiter.Agents.Codex,
                 usage_workspace_id: "ws-pf-live-codex",
                 timeout_ms: 60_000
               )

      [ev] =
        Event
        |> Ash.Query.filter(source == :preflight and workspace_id == "ws-pf-live-codex")
        |> Ash.read!()

      assert ev.provider == "codex"
      assert is_integer(ev.tokens_in) and ev.tokens_in > 0
      assert is_integer(ev.tokens_out)
    else
      IO.puts("SKIP: no codex CLI on PATH on this host — live round-trip not exercised")
    end
  end
end
