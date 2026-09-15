defmodule Arbiter.Sessions.StreamExitLifecycleTest do
  @moduledoc """
  bd-bsdeb2: a session's payload exiting on its own — `/exit`, a crash, the
  scope unit disappearing — must mark the row `:ended` the same way an
  operator's Kill does, not just tell attached clients about it.

  `Arbiter.Sessions.Stream` already notices the dead pane in its `:alive`
  poll (see `Arbiter.Sessions.StreamTest` "exit (AC 6)") and broadcasts
  `{:session_exit, id, ...}`; this only covers that noticing also ends the
  row, revoking its MCP token, before that broadcast reaches anyone.
  """
  use Arbiter.DataCase, async: false

  alias Arbiter.MCP.Scope
  alias Arbiter.Sessions
  alias Arbiter.Sessions.Session
  alias Arbiter.Sessions.Stream
  alias Arbiter.Test.ScriptedPty

  @moduletag :tmp_dir

  @opts [
    terminal: ScriptedPty,
    poll_interval_ms: 5,
    alive_interval_ms: 20,
    linger_ms: 0
  ]

  setup %{tmp_dir: tmp_dir} do
    {:ok, session} = Ash.create(Session, %{cwd: "/tmp/work"})
    {:ok, session} = Sessions.mark_running(session)

    ScriptedPty.install(session.id, snapshot: "SNAPSHOT", cols: 80, rows: 24, title: "scripted")

    on_exit(fn -> Stream.stop(session.id) end)

    %{session: session, opts: Keyword.put(@opts, :pipe_dir, tmp_dir)}
  end

  test "a pane that dies while a client is attached ends the row as exited", %{
    session: session,
    opts: opts
  } do
    token = Sessions.mint_mcp_token(session)
    {:ok, _} = Stream.attach(session, opts)

    ScriptedPty.put(session.id, alive?: false)

    assert_receive {:session_exit, _id, %{reason: "exited"}}, 2_000

    {:ok, ended} = Sessions.get(session.id)
    assert ended.status == :ended
    assert ended.end_reason == "exited"
    assert ended.ended_at

    assert {:error, :revoked} = Scope.from_token(token)
  end
end
