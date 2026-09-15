defmodule Arbiter.Sessions.StreamTurnActivityTest do
  @moduledoc """
  Production-path coverage for `Arbiter.Sessions.Stream`'s `last_turn_at`
  stamping (§4.6 item 2, phase 10 review finding: nothing outside tests ever
  called `Sessions.touch_turn/1`). Split from `StreamTest` because this needs
  a real DB-backed session (`Sessions.launch/1`) and DB access from inside the
  reader process, so it runs `async: false` under `Arbiter.DataCase`'s shared
  sandbox rather than the fabricated in-memory sessions `StreamTest` uses.
  """
  use Arbiter.DataCase, async: false

  @moduletag :tmp_dir

  alias Arbiter.Sessions
  alias Arbiter.Sessions.Frame
  alias Arbiter.Sessions.Stream
  alias Arbiter.Test.NoopRunner
  alias Arbiter.Test.ScriptedPty

  test "pane output stamps last_turn_at even with nobody attached", %{tmp_dir: tmp_dir} do
    {:ok, session} = Sessions.launch(cwd: tmp_dir, runner: NoopRunner, provision: false)
    on_exit(fn -> Stream.stop(session.id) end)

    ScriptedPty.install(session.id, snapshot: "", cols: 80, rows: 24, title: "scripted")
    assert is_nil(session.last_turn_at)

    {:ok, _} =
      Stream.attach(session,
        terminal: ScriptedPty,
        pipe_dir: tmp_dir,
        poll_interval_ms: 5,
        alive_interval_ms: 20,
        linger_ms: 0
      )

    ScriptedPty.emit(session.id, "agent is working")
    assert_receive {:session_stdout, _id, frame}, 1_000
    assert {:ok, _seq, "agent is working"} = Frame.decode(frame)

    wait_until(fn ->
      {:ok, reloaded} = Sessions.get(session.id)
      not is_nil(reloaded.last_turn_at)
    end)
  end

  defp wait_until(fun, timeout \\ 2_000) do
    deadline = System.monotonic_time(:millisecond) + timeout
    do_wait_until(fun, deadline)
  end

  defp do_wait_until(fun, deadline) do
    cond do
      fun.() ->
        :ok

      System.monotonic_time(:millisecond) >= deadline ->
        flunk("condition not met within the deadline")

      true ->
        Process.sleep(10)
        do_wait_until(fun, deadline)
    end
  end
end
