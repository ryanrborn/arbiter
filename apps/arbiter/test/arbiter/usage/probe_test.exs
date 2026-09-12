defmodule Arbiter.Usage.ProbeTest do
  @moduledoc """
  bd-adyhvn: one-shot `claude --print --output-format json` round-trips (the
  dispatch auth pre-flight, and formerly the quota RefreshProbe, deleted in
  bd-atyrrq) read `usage` out of their own stdout and write it to the ledger.
  """
  use Arbiter.DataCase, async: false

  alias Arbiter.Usage.Event
  alias Arbiter.Usage.Probe
  require Ash.Query

  @result_json ~s({"type":"result","subtype":"success","is_error":false,) <>
                 ~s("duration_ms":1234,"num_turns":1,"result":"ok","session_id":"sess-probe-1",) <>
                 ~s("total_cost_usd":0.0181,) <>
                 ~s("usage":{"input_tokens":4,"output_tokens":7,) <>
                 ~s("cache_creation_input_tokens":11,"cache_read_input_tokens":57062}})

  describe "parse/1" do
    test "extracts the token counts from the CLI's own result object" do
      {usage, _rest} = Probe.parse([@result_json])

      assert usage.tokens_in == 4
      assert usage.tokens_out == 7
      assert usage.cache_creation_tokens == 11
      assert usage.cache_read_tokens == 57_062
      assert usage.cost_usd == 0.0181
      assert usage.duration_ms == 1234
      assert usage.session_id == "sess-probe-1"
    end

    test "removes the success result object from the lines handed to the classifier" do
      # The JSON blob carries token counts that the StopReason signatures would
      # otherwise read as provider errors (`\\b401\\b`, `\\b402\\b`). It is the
      # CLI's structured success payload, not diagnostic output — the classifier
      # must never see it.
      {_usage, rest} = Probe.parse(["warming up", @result_json])
      assert rest == ["warming up"]
    end

    test "a 401-token success payload does not classify as auth_expired" do
      json =
        ~s({"type":"result","subtype":"success","is_error":false,"duration_ms":402,) <>
          ~s("session_id":"s","total_cost_usd":0.01,) <>
          ~s("usage":{"input_tokens":401,"output_tokens":3,) <>
          ~s("cache_creation_input_tokens":0,"cache_read_input_tokens":9}})

      {usage, rest} = Probe.parse([json])
      assert usage.tokens_in == 401
      assert rest == []
      assert Arbiter.Worker.StopReason.classify(0, rest).category == :exited_without_done
    end

    test "keeps an is_error result object visible to the classifier" do
      json =
        ~s({"type":"result","subtype":"error_during_execution","is_error":true,) <>
          ~s("result":"API Error: 401 invalid authentication credentials"})

      {usage, rest} = Probe.parse([json])
      assert usage == nil
      assert rest == [json]
    end

    test "non-JSON output parses to no usage and is left intact" do
      {usage, rest} = Probe.parse(["pong", "ok"])
      assert usage == nil
      assert rest == ["pong", "ok"]
    end
  end

  describe "record/3" do
    test "writes a probe row attributed to its workspace with real tokens" do
      {usage, _rest} = Probe.parse([@result_json])

      assert :ok =
               Probe.record(:probe, usage,
                 workspace_id: "ws-probe-rec",
                 provider: "claude",
                 exit_status: 0
               )

      [ev] =
        Event
        |> Ash.Query.filter(workspace_id == "ws-probe-rec")
        |> Ash.read!()

      assert ev.source == :probe
      assert ev.task_id == nil
      assert ev.workspace_id == "ws-probe-rec"
      assert ev.cache_read_tokens == 57_062
      assert ev.tokens_in == 4
      assert ev.session_id == "sess-probe-1"
      assert ev.step == :other
    end

    test "writes a preflight row carrying the task it was checking for" do
      {usage, _rest} = Probe.parse([@result_json])

      assert :ok =
               Probe.record(:preflight, usage,
                 workspace_id: "ws-pf-rec",
                 task_id: "bd-pf-target",
                 provider: "claude",
                 exit_status: 0
               )

      [ev] = Event |> Ash.Query.filter(workspace_id == "ws-pf-rec") |> Ash.read!()

      assert ev.source == :preflight
      assert ev.task_id == "bd-pf-target"
    end

    test "still records the attempt when the CLI returned no usage payload" do
      assert :ok =
               Probe.record(:preflight, nil,
                 workspace_id: "ws-pf-nousage",
                 provider: "claude",
                 exit_status: 1,
                 duration_ms: 50
               )

      [ev] = Event |> Ash.Query.filter(workspace_id == "ws-pf-nousage") |> Ash.read!()

      assert ev.source == :preflight
      assert ev.tokens_in == nil
      assert ev.cost_usd == nil
      assert is_binary(ev.cost_note)
    end
  end
end
