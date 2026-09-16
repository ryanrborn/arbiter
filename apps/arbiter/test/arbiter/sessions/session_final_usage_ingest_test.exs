defmodule Arbiter.Sessions.SessionFinalUsageIngestTest do
  @moduledoc """
  `Arbiter.Sessions.mark_ended/2` also triggers one last synchronous sweep of
  the ending session's own JSONL (bd-9mrzti finding 1/3) — the periodic
  `Arbiter.Sessions.UsageIngest` sweep only looks at *non-ended* sessions, so
  without this a session's final turns would sit unswept on a row nothing
  will read again, and `/sessions` would show a stale total forever.
  """
  use Arbiter.DataCase, async: false

  alias Arbiter.Sessions
  alias Arbiter.Sessions.Session
  alias Arbiter.Usage
  alias Arbiter.Usage.Event

  require Ash.Query

  defp rows_for(session_id) do
    Event
    |> Ash.Query.filter(session_id == ^session_id)
    |> Ash.read!()
  end

  defp seed_session_jsonl(cfg, provider_session_id) do
    dir = Path.join([cfg, "projects", "-home-ryan-dev-arbiter"])
    File.mkdir_p!(dir)

    line =
      ~s({"type":"assistant","timestamp":"#{DateTime.to_iso8601(DateTime.utc_now())}",) <>
        ~s("sessionId":"#{provider_session_id}","message":{"id":"m1","model":"claude-opus-5",) <>
        ~s("usage":{"input_tokens":10,"output_tokens":100,"cache_read_input_tokens":0,) <>
        ~s("cache_creation_input_tokens":0}}})

    File.write!(Path.join(dir, provider_session_id <> ".jsonl"), line <> "\n")
  end

  setup do
    cfg =
      Path.join(
        System.tmp_dir!(),
        "session-final-usage-ingest-#{System.unique_integer([:positive])}"
      )

    on_exit(fn -> File.rm_rf(cfg) end)
    %{config_dir: cfg}
  end

  test "ending a browser-hosted session writes its final usage row", %{config_dir: cfg} do
    provider_session_id = Ash.UUID.generate()
    seed_session_jsonl(cfg, provider_session_id)

    {:ok, session} =
      Ash.create(Session, %{
        cwd: "/tmp/work",
        config_dir: cfg,
        provider_session_id: provider_session_id
      })

    {:ok, session} = Sessions.mark_running(session)
    assert rows_for(provider_session_id) == []

    {:ok, _ended} = Sessions.mark_ended(session, "test")

    assert [ev] = rows_for(provider_session_id)
    assert ev.tokens_in == 10
    assert ev.tokens_out == 100

    assert {:ok, [rollup]} = Usage.summarize(by: :session, session_ids: [provider_session_id])
    assert rollup.group == provider_session_id
    assert rollup.tokens_in == 10
  end

  test "a session with no JSONL still ends cleanly, without error" do
    {:ok, session} = Ash.create(Session, %{cwd: "/tmp/work"})
    {:ok, session} = Sessions.mark_running(session)

    assert {:ok, _ended} = Sessions.mark_ended(session, "test")
  end
end
