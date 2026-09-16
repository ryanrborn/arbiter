defmodule Arbiter.Sessions.SessionJsonlArchiveTest do
  @moduledoc """
  `Arbiter.Sessions.mark_ended/2` is the single place every session-ending
  path funnels through, so it is also where the session's own JSONL gets
  archived (§11, phase 9) — this proves the wiring end to end, complementing
  `Arbiter.Worker.SessionArchiveTest`'s unit coverage of `archive_session/4`
  itself.
  """
  use Arbiter.DataCase, async: false

  alias Arbiter.Sessions
  alias Arbiter.Sessions.Session
  alias Arbiter.Worker.SessionArchive

  setup do
    prev = Application.get_env(:arbiter, :output_log_root)

    root =
      Path.join(
        System.tmp_dir!(),
        "session-jsonl-archive-test-#{System.unique_integer([:positive])}"
      )

    Application.put_env(:arbiter, :output_log_root, root)

    cfg =
      Path.join(
        System.tmp_dir!(),
        "session-jsonl-archive-cfg-#{System.unique_integer([:positive])}"
      )

    on_exit(fn ->
      File.rm_rf(root)
      File.rm_rf(cfg)

      if prev do
        Application.put_env(:arbiter, :output_log_root, prev)
      else
        Application.delete_env(:arbiter, :output_log_root)
      end
    end)

    %{config_dir: cfg}
  end

  defp seed_session_jsonl(cfg, provider_session_id, body) do
    dir = Path.join([cfg, "projects", "-home-ryan-dev-arbiter"])
    File.mkdir_p!(dir)
    File.write!(Path.join(dir, provider_session_id <> ".jsonl"), body)
  end

  test "ending a coordinator session archives its own JSONL under the session id", %{
    config_dir: cfg
  } do
    provider_session_id = Ash.UUID.generate()
    seed_session_jsonl(cfg, provider_session_id, ~s({"type":"assistant","hello":"world"}\n))

    {:ok, session} =
      Ash.create(Session, %{
        cwd: "/tmp/work",
        config_dir: cfg,
        provider_session_id: provider_session_id
      })

    {:ok, session} = Sessions.mark_running(session)
    {:ok, _} = Sessions.mark_ended(session, "test")

    assert SessionArchive.archived?(session.id)
    assert {:ok, body} = SessionArchive.read(session.id)
    assert body =~ ~s("hello":"world")
  end

  test "a session that never opened an agent session archives nothing, and does not error" do
    {:ok, session} = Ash.create(Session, %{cwd: "/tmp/work"})
    {:ok, session} = Sessions.mark_running(session)

    assert {:ok, _} = Sessions.mark_ended(session, "test")
    refute SessionArchive.archived?(session.id)
  end
end
