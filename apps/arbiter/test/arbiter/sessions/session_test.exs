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

    test "name is nullable, settable at create, and updatable afterwards (bd-o2vtsz)" do
      unnamed = create!(%{})
      assert unnamed.name == nil

      named = create!(%{name: "refinement session"})
      assert named.name == "refinement session"

      {:ok, renamed} = Sessions.rename(named, "second pass")
      assert renamed.name == "second pass"

      {:ok, cleared} = Sessions.rename(renamed, nil)
      assert cleared.name == nil
    end

    test "remote_control under mode A (oauth_token) is refused (§8.3)" do
      assert {:error, error} =
               Ash.create(
                 Session,
                 %{cwd: "/tmp/session-cwd", auth_mode: :oauth_token, remote_control: true}
               )

      assert Exception.message(error) =~ "remote_control"
    end

    test "remote_control under mode B (seeded_credentials) is allowed" do
      session = create!(%{auth_mode: :seeded_credentials, remote_control: true})
      assert session.remote_control == true
    end
  end

  describe "the migrated table (AC 1)" do
    # The resource passing is not the same as the migration being right: this
    # migration is hand-written with no committed `resource_snapshots` entry
    # (see its moduledoc for why), so nothing else would notice the two
    # drifting apart. Asserted against the live schema rather than the DSL.
    test "has exactly the columns RFC §7.4 item 4, phase 3 and phase 10 name, and no others" do
      columns =
        Repo.query!("PRAGMA table_info(sessions)").rows
        |> Enum.map(fn [_cid, name, _type, notnull, _default, pk] ->
          {name, notnull == 1, pk == 1}
        end)
        |> Enum.sort()

      assert columns == [
               {"auth_mode", true, false},
               {"bridge_status", false, false},
               {"can_dispatch", true, false},
               {"config_dir", false, false},
               {"cwd", true, false},
               {"end_reason", false, false},
               {"ended_at", false, false},
               {"id", true, true},
               {"inserted_at", true, false},
               {"issue_id", false, false},
               {"keep_alive", true, false},
               {"last_client_at", false, false},
               {"last_turn_at", false, false},
               {"mcp_token_revoked_at", false, false},
               {"name", false, false},
               {"provider", true, false},
               {"provider_session_id", false, false},
               {"remote_control", true, false},
               {"root_dir", false, false},
               {"scope_unit", true, false},
               {"started_at", true, false},
               {"status", true, false},
               {"tmux_socket", true, false},
               {"updated_at", true, false},
               {"workspace_id", false, false}
             ]
    end

    test "indexes the two columns that are read by key" do
      indexes =
        Repo.query!("PRAGMA index_list(sessions)").rows
        |> Enum.map(fn [_seq, name, unique | _] -> {name, unique == 1} end)
        |> Enum.sort()

      assert {"sessions_provider_session_id_index", false} in indexes
      assert {"sessions_status_index", false} in indexes
      assert {"sessions_scope_unit_index", true} in indexes
      # bd-1lszsc: the refine binding — the lookup index, and the partial
      # unique one that holds "one live refine session per issue".
      assert {"sessions_issue_id_index", false} in indexes
      assert {"sessions_live_issue_binding_index", true} in indexes
    end

    test "the issue binding is unique only among live rows (bd-1lszsc)" do
      issue_id = "bd-#{System.unique_integer([:positive])}"
      live = create!(%{issue_id: issue_id})

      assert {:error, %Ash.Error.Invalid{}} = Ash.create(Session, %{issue_id: issue_id})

      # Ending it takes the row out of the partial index, so the issue can be
      # refined again — the whole history stays on the table.
      {:ok, _ended} = Ash.update(live, %{end_reason: "done"}, action: :mark_ended)
      assert {:ok, %Session{}} = Ash.create(Session, %{issue_id: issue_id})
    end

    test "one row per scope is enforced by the database, not just by the id" do
      session = create!(%{})

      assert {:error, %Exqlite.Error{message: message}} =
               Repo.query(
                 "INSERT INTO sessions (id, provider, scope_unit, tmux_socket, cwd, " <>
                   "auth_mode, remote_control, started_at, status, inserted_at, updated_at) " <>
                   "VALUES (?, 'claude_code', ?, '/tmp/other.sock', '/tmp', " <>
                   "'seeded_credentials', 0, ?, 'running', ?, ?)",
                 [
                   Ash.UUID.generate(),
                   session.scope_unit,
                   session.started_at,
                   session.started_at,
                   session.started_at
                 ]
               )

      assert message =~ "UNIQUE constraint failed: sessions.scope_unit"
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
