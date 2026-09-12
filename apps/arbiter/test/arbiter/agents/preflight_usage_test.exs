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
end
