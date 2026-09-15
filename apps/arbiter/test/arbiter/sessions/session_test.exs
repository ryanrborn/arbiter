defmodule Arbiter.Sessions.SessionTest do
  @moduledoc """
  The `sessions` resource — RFC §7.4 item 4 (bd-bpt0ag, phase 1).

  Acceptance criterion 1: the resource and migration match the RFC's field
  list, and `Usage.Event.session_id` rows written by the **existing** ingest
  join back to a session row by string.
  """
  use Arbiter.DataCase, async: false

  alias Arbiter.Sessions
  alias Arbiter.Sessions.Session
  alias Arbiter.Sessions.UsageIngest
  alias Arbiter.Tasks.Workspace

  require Ash.Query

  defp tmp_dir!(tag) do
    dir =
      Path.join(
        System.tmp_dir!(),
        "bd-bpt0ag-#{tag}-#{System.unique_integer([:positive])}-#{:erlang.unique_integer([:positive])}"
      )

    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf(dir) end)
    dir
  end

  defp create!(attrs) do
    Ash.create!(Session, Map.merge(%{cwd: "/tmp/session-cwd"}, Map.new(attrs)))
  end

  describe "attributes (RFC §7.4 item 4)" do
    test "a row carries every field the RFC names" do
      {:ok, ws} = Ash.create(Workspace, %{name: "sessions-attrs", prefix: "sat"})

      session =
        create!(%{
          provider: :claude_code,
          workspace_id: ws.id,
          config_dir: "/tmp/cfg",
          cwd: "/tmp/work",
          provider_session_id: "prov-1",
          auth_mode: :seeded_credentials,
          remote_control: true
        })

      # Identity + binding.
      assert is_binary(session.id)
      assert session.provider == :claude_code
      assert session.workspace_id == ws.id

      # Process handles — derived from the id, never passed in, so the scope
      # unit and socket path can always be recomputed from a row.
      assert session.scope_unit == "arb-session-#{session.id}.scope"
      assert session.tmux_socket =~ "session-#{session.id}.sock"

      # Provisioning + auth.
      assert session.config_dir == "/tmp/cfg"
      assert session.cwd == "/tmp/work"
      assert session.provider_session_id == "prov-1"
      assert session.auth_mode == :seeded_credentials
      assert session.remote_control == true

      # Lifecycle.
      assert %DateTime{} = session.started_at
      assert session.ended_at == nil
      assert session.last_client_at == nil
      assert session.status == :starting
      assert session.end_reason == nil
    end

    test "workspace_id is nullable — a nil binding means cross-workspace" do
      session = create!(%{})

      assert session.workspace_id == nil
      assert session.provider == :claude_code
      assert session.auth_mode == :seeded_credentials
      assert session.remote_control == false
    end

    test "provider session id is updatable — a session rolls onto a new id (§7.5)" do
      session = create!(%{provider_session_id: "launch-sid"})

      {:ok, rolled} =
        Ash.update(session, %{provider_session_id: "rolled-sid"},
          action: :record_provider_session
        )

      assert rolled.provider_session_id == "rolled-sid"
      assert rolled.status == :starting
    end

    test "an unknown provider is rejected" do
      assert {:error, _} = Ash.create(Session, %{provider: :telepathy, cwd: "/tmp/x"})
    end
  end

  describe "joining the usage ledger by string (AC 1)" do
    test "rows the existing ingest wrote join to a session by provider session id" do
      dir = tmp_dir!("join")
      sid = "prov-#{System.unique_integer([:positive])}"
      at = DateTime.utc_now()

      File.write!(
        Path.join(dir, sid <> ".jsonl"),
        ~s({"type":"assistant","timestamp":"#{DateTime.to_iso8601(at)}","sessionId":"#{sid}","message":{"id":"m1","model":"claude-opus-5","usage":{"input_tokens":11,"output_tokens":22,"cache_read_input_tokens":0,"cache_creation_input_tokens":0}}}) <>
          "\n" <>
          ~s({"type":"cost-state","sessionId":"#{sid}","totalCostUSD":1.25,"totalDuration":1000,"startTime":#{DateTime.to_unix(at, :millisecond)},"modelUsage":{"claude-opus-5":{"costUSD":1.25}}}) <>
          "\n"
      )

      # The ingest shipped in bd-be804c, untouched by this phase.
      assert {:ok, %{rows_written: 1}} = UsageIngest.ingest(dirs: [dir])

      session = create!(%{provider_session_id: sid})

      assert [event] = Sessions.usage_events(session)
      assert event.source == :coordinator_session
      assert event.session_id == sid
      assert event.tokens_in == 11
      assert event.tokens_out == 22
    end

    test "a session with no provider session id yet has no ledger rows" do
      session = create!(%{})

      assert Sessions.usage_events(session) == []
    end
  end
end
