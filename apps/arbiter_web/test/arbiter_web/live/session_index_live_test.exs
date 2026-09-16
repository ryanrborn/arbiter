defmodule ArbiterWeb.SessionIndexLiveTest do
  @moduledoc """
  Cost/tokens column on `/sessions` (bd-9mrzti, follow-up to phase 7's live
  cost HUD on the session detail page, bd-67l88l).

  The column reads `Arbiter.Usage.summarize(by: :session)` — the same
  canonical rollup `arb usage --by session` uses — rather than tailing a
  session's JSONL itself, so these tests drive it by writing
  `Arbiter.Usage.Event` rows, not by faking terminal bytes.
  """
  use ArbiterWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Arbiter.Sessions
  alias Arbiter.Test.NoopRunner
  alias Arbiter.Usage.Event

  setup do
    Arbiter.Test.SessionEnv.sandbox("session-index-usage")
    put_env(:sessions_runner, NoopRunner)
    :ok
  end

  defp launch!(opts \\ []) do
    {:ok, session} = Sessions.launch(Keyword.put_new(opts, :runner, NoopRunner))
    session
  end

  defp put_env(key, value) do
    previous = Application.fetch_env(:arbiter, key)
    Application.put_env(:arbiter, key, value)

    on_exit(fn ->
      case previous do
        {:ok, old} -> Application.put_env(:arbiter, key, old)
        :error -> Application.delete_env(:arbiter, key)
      end
    end)
  end

  defp create_event!(attrs) do
    base = %{
      task_id: nil,
      source: :coordinator_session,
      step: :other,
      provider: "claude",
      model: "claude-opus-4-7",
      occurred_at: DateTime.utc_now()
    }

    {:ok, ev} = Ash.create(Event, Map.merge(base, attrs))
    ev
  end

  describe "the cost/tokens column" do
    test "shows an ended session's final totals, from the same source as `arb usage --by session`",
         %{conn: conn} do
      session = launch!()
      {:ok, _} = Sessions.record_provider_session(session, "prov-ended-1")

      create_event!(%{
        session_id: "prov-ended-1",
        cost_usd: 1.5,
        tokens_in: 1000,
        tokens_out: 500,
        raw: %{"arb_usage_source" => %{"cost_source" => "cost_state"}}
      })

      {:ok, _ended} = Sessions.kill(session.id, runner: NoopRunner, reason: "done")

      {:ok, view, _html} = live(conn, ~p"/sessions")

      assert has_element?(view, "#session-#{session.id}-usage", "$1.50")
      assert has_element?(view, "#session-#{session.id}-usage", "1.0k in")
      refute has_element?(view, "#session-#{session.id}-usage", "estimated")
    end

    test "marks an estimated cost the same way the detail page does", %{conn: conn} do
      session = launch!()
      {:ok, _} = Sessions.record_provider_session(session, "prov-est-1")

      create_event!(%{
        session_id: "prov-est-1",
        cost_usd: 2.0,
        tokens_in: 200,
        tokens_out: 100,
        raw: %{"arb_usage_source" => %{"cost_source" => "estimated"}}
      })

      {:ok, view, _html} = live(conn, ~p"/sessions")

      assert has_element?(view, "#session-#{session.id}-usage", "estimated")
    end

    test "shows an explicit empty state rather than $0.00 when a session has no metering data",
         %{conn: conn} do
      session = launch!()

      {:ok, view, _html} = live(conn, ~p"/sessions")

      assert has_element?(view, "#session-#{session.id}-usage-empty")
      refute has_element?(view, "#session-#{session.id}-usage", "$0.00")
    end

    test "a running session's figures refresh on the periodic tick without a page reload", %{
      conn: conn
    } do
      session = launch!()
      {:ok, _} = Sessions.record_provider_session(session, "prov-running-1")

      {:ok, view, _html} = live(conn, ~p"/sessions")

      assert has_element?(view, "#session-#{session.id}-usage-empty")

      create_event!(%{
        session_id: "prov-running-1",
        cost_usd: 0.75,
        tokens_in: 300,
        tokens_out: 150,
        raw: %{"arb_usage_source" => %{"cost_source" => "cost_state"}}
      })

      send(view.pid, :refresh_session_usage)

      assert has_element?(view, "#session-#{session.id}-usage", "$0.75")
      refute has_element?(view, "#session-#{session.id}-usage-empty")
    end
  end
end
