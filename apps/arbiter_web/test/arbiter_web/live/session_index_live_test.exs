defmodule ArbiterWeb.SessionIndexLiveTest do
  @moduledoc """
  `/sessions` — the sessions index (bd-c76fu9 phase 5, bd-9mrzti's cost/tokens
  column, bd-a292yj's move of every per-session control into the dock).

  Since phase 3 of the session dock this is the *only* sessions page: there is
  no `/sessions/:id`, and what used to be tested there — keep_alive, kill from
  the session's own surface, the exit banner, the metadata, the non-loopback
  notice — is in `ArbiterWeb.SessionDockLiveTest`, against the dock window that
  owns it now. What is left here is what the index itself owns: launching,
  naming at launch, listing, handing a session to the dock, and Kill (a fleet
  act, shared with the dock through `SessionIndexLive.kill_modal/1`).

  The cost/tokens column reads `ArbiterWeb.SessionUsage` —
  `Arbiter.Usage.summarize(by: :session)`, the same canonical rollup `arb usage
  --by session` uses — rather than tailing a session's JSONL itself, so those
  tests drive it by writing `Arbiter.Usage.Event` rows, not by faking terminal
  bytes.
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

  describe "the sessions list" do
    test "is reachable from the app navigation", %{conn: conn} do
      {:ok, _view, html} = live(conn, ~p"/")
      assert html =~ ~s(href="/sessions")
    end

    test "shows an empty state when nothing has ever been launched", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/sessions")

      assert has_element?(view, "#sessions-empty")
      refute has_element?(view, "#sessions-list")
    end

    test "lists sessions newest first, each openable in the dock", %{conn: conn} do
      older = launch!()
      newer = launch!()

      {:ok, view, html} = live(conn, ~p"/sessions")

      assert has_element?(view, "#session-#{older.id}")
      assert has_element?(view, "#session-#{newer.id}")

      # No link to a session page: there isn't one any more (bd-a292yj). The
      # row opens the session in the dock, on this page.
      refute html =~ ~s(href="/sessions/#{newer.id}")
      assert has_element?(view, "#open-in-dock-#{newer.id}")
      assert has_element?(view, "#open-in-dock-button-#{newer.id}")

      assert [first, second] =
               Regex.scan(~r/id="session-([-0-9a-f]+)"/, html, capture: :all_but_first)

      assert first == [newer.id]
      assert second == [older.id]
    end

    test "shows the resolved display name, and the id stays reachable (bd-o2vtsz)", %{conn: conn} do
      named = launch!(name: "refinement session")
      unnamed = launch!()

      {:ok, view, html} = live(conn, ~p"/sessions")

      assert html =~ "refinement session"

      assert has_element?(
               view,
               "#session-#{named.id}-short-id",
               Arbiter.Sessions.DisplayName.short_id(named.id)
             )

      assert has_element?(
               view,
               "#session-#{unnamed.id}-short-id",
               Arbiter.Sessions.DisplayName.short_id(unnamed.id)
             )
    end

    test "an ended session is shown as ended, with the reason it ended", %{conn: conn} do
      session = launch!()
      {:ok, _ended} = Sessions.kill(session.id, runner: NoopRunner, reason: "killed by hand")

      {:ok, view, html} = live(conn, ~p"/sessions")

      assert has_element?(view, "#session-#{session.id}")
      assert html =~ "killed by hand"
    end

    test "a session ending on its own (no Kill click) updates the list live, via PubSub (bd-bsdeb2)",
         %{conn: conn} do
      session = launch!()
      {:ok, view, _html} = live(conn, ~p"/sessions")

      assert has_element?(view, "#session-#{session.id}", "running")

      # Simulate the Stream noticing a dead pane, or the periodic reaper
      # noticing a vanished scope — either way `mark_ended/2` is the one
      # place that runs, no Kill click involved.
      {:ok, _ended} = Sessions.mark_ended(session, "exited")

      assert render(view) =~ "exited"
      assert has_element?(view, "#session-#{session.id}", "ended")
    end
  end

  describe "launching" do
    # bd-a292yj: launching no longer navigates. There is nowhere to navigate
    # *to* — the session's window opens in the dock, which is already on this
    # page, so a redirect would only have thrown away what was on screen.
    test "the launch button provisions a session with the phase-5 defaults and opens it in the dock",
         %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/sessions")

      assert has_element?(view, "#launch-session")

      # Launching is slow and no longer redirects, so the button stays under
      # the cursor for the whole call. Without this a second click starts a
      # second real session (review finding 1).
      assert has_element?(view, ~s(#launch-session[phx-disable-with]))

      view |> form("#launch-session-form") |> render_submit()

      assert [session] = Sessions.list()
      assert_push_event(view, "session-dock:open", %{id: opened})
      assert opened == session.id

      # §10.1 / the phase-5 scope: mode B, cross-workspace, dispatch off. The
      # full pre-launch options UI is phase 11.
      assert session.auth_mode == :seeded_credentials
      assert session.workspace_id == nil
      assert session.can_dispatch == false
      assert session.status == :running
      assert session.name == nil
    end

    test "an operator-supplied name reaches the session row (bd-o2vtsz)", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/sessions")

      view
      |> form("#launch-session-form", %{"name" => "refinement session"})
      |> render_submit()

      assert [session] = Sessions.list()
      assert session.name == "refinement session"
    end

    test "a blank name launches with no name, same as leaving it empty", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/sessions")

      view |> form("#launch-session-form", %{"name" => "   "}) |> render_submit()

      assert [session] = Sessions.list()
      assert session.name == nil
    end

    test "a failed launch reports why and leaves the operator on the list", %{conn: conn} do
      put_env(:sessions_runner, Arbiter.Test.FailingSessionRunner)

      {:ok, view, _html} = live(conn, ~p"/sessions")

      html = view |> form("#launch-session-form") |> render_submit()

      assert html =~ "Could not launch"
      assert has_element?(view, "#launch-session")
    end
  end

  describe "workspace binding in the launch form (§9.5)" do
    test "defaults to cross-workspace and lists workspaces to opt into", %{conn: conn} do
      {:ok, workspace} =
        Ash.create(Arbiter.Tasks.Workspace, %{name: "acme-web", prefix: "aw"})

      {:ok, view, _html} = live(conn, ~p"/sessions")

      assert has_element?(view, "#launch-session-workspace-id")
      assert render(view) =~ workspace.name

      view |> form("#launch-session-form") |> render_submit()

      assert [session] = Sessions.list()
      assert session.workspace_id == nil
    end

    test "selecting a workspace binds the launched session to it", %{conn: conn} do
      {:ok, workspace} =
        Ash.create(Arbiter.Tasks.Workspace, %{name: "acme-web2", prefix: "aw2"})

      {:ok, view, _html} = live(conn, ~p"/sessions")

      view
      |> form("#launch-session-form", %{"workspace_id" => workspace.id})
      |> render_submit()

      assert [session] = Sessions.list()
      assert session.workspace_id == workspace.id
    end

    test "switching auth mode does not silently discard a workspace pick or can_dispatch",
         %{conn: conn} do
      {:ok, workspace} =
        Ash.create(Arbiter.Tasks.Workspace, %{name: "acme-web3", prefix: "aw3"})

      {:ok, view, _html} = live(conn, ~p"/sessions")

      view
      |> form("#launch-session-form", %{"workspace_id" => workspace.id, "can_dispatch" => "true"})
      |> render_change()

      assert has_element?(view, "#launch-session-can-dispatch[checked]")

      # auth_mode is the only field explicitly changed here — the workspace
      # pick and can_dispatch check must survive this round trip rather than
      # reverting to their server-rendered defaults (review finding, phase 11
      # round 1: a form that re-renders `value=""` / no `checked` regardless
      # of what the operator picked loses those choices the moment any other
      # field triggers a diff).
      view
      |> form("#launch-session-form", %{"auth_mode" => "oauth_token"})
      |> render_change()

      assert has_element?(view, "#launch-session-can-dispatch[checked]")

      assert has_element?(
               view,
               ~s(#launch-session-workspace-id option[value="#{workspace.id}"][selected])
             )

      view
      |> form("#launch-session-form", %{"auth_mode" => "seeded_credentials"})
      |> render_submit()

      assert [session] = Sessions.list()
      assert session.workspace_id == workspace.id
      assert session.can_dispatch == true
    end

    test "a workspace id that does not exist falls back to cross-workspace rather than binding",
         %{conn: conn} do
      # The `<select>` only ever offers real ids, but nothing stops a crafted
      # submit from sending one that doesn't — `launch_workspace_id/2` must
      # refuse it rather than binding the session to a workspace that isn't
      # there (review finding, phase 11 round 4).
      {:ok, view, _html} = live(conn, ~p"/sessions")

      # `form/3` refuses to build a submit with a `<select>` value outside
      # its own `<option>` list, so this goes straight at the event — the
      # same way a hand-crafted request would reach `handle_event/3`.
      render_submit(view, "launch", %{"workspace_id" => "not-a-real-workspace-id"})

      assert [session] = Sessions.list()
      assert session.workspace_id == nil
    end
  end

  describe "can_dispatch in the launch form (§10.1)" do
    test "defaults off", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/sessions")

      refute has_element?(view, "#launch-session-can-dispatch[checked]")

      view |> form("#launch-session-form") |> render_submit()

      assert [session] = Sessions.list()
      assert session.can_dispatch == false
    end

    test "checking the box turns it on explicitly", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/sessions")

      view
      |> form("#launch-session-form", %{"can_dispatch" => "true"})
      |> render_submit()

      assert [session] = Sessions.list()
      assert session.can_dispatch == true
    end

    test "a second launch from the same view does not inherit the prior can_dispatch choice",
         %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/sessions")

      # `render_change` first, so `can_dispatch: true` is actually latched
      # onto the server assign before the launch that must clear it —
      # `render_submit` alone never fires `phx-change`, so a test that skips
      # this step passes whether or not the reset fix exists (review
      # finding, phase 11 round 3).
      view
      |> form("#launch-session-form", %{"name" => "first", "can_dispatch" => "true"})
      |> render_change()

      assert has_element?(view, "#launch-session-can-dispatch[checked]")

      view
      |> form("#launch-session-form", %{"name" => "first", "can_dispatch" => "true"})
      |> render_submit()

      # The form re-renders after a successful launch; a fresh submit with
      # only a name must not silently carry the prior can_dispatch: true
      # forward (review finding, phase 11 round 2).
      refute has_element?(view, "#launch-session-can-dispatch[checked]")

      view
      |> form("#launch-session-form", %{"name" => "second"})
      |> render_submit()

      assert [%{name: "second", can_dispatch: false}, %{name: "first", can_dispatch: true}] =
               Sessions.list()
    end

    test "a second launch does not inherit the prior session name either", %{conn: conn} do
      # Unlike the dock's launch panel, this page's form is never removed
      # from the DOM after a launch — so if the name input isn't reset
      # server-side, the browser's uncontrolled value survives and a second
      # submit with no `name` param would silently reuse the first session's
      # name (review finding, phase 11 round 4).
      {:ok, view, _html} = live(conn, ~p"/sessions")

      view
      |> form("#launch-session-form", %{"name" => "first"})
      |> render_change()

      view
      |> form("#launch-session-form", %{"name" => "first"})
      |> render_submit()

      view
      |> form("#launch-session-form", %{})
      |> render_submit()

      assert [%{name: nil}, %{name: "first"}] = Sessions.list()
    end

    test "switching to mode A un-checks a previously-checked Remote Control box",
         %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/sessions")

      view
      |> form("#launch-session-form", %{"remote_control" => "true"})
      |> render_change()

      assert has_element?(view, "#launch-session-remote-control[checked]")

      view
      |> form("#launch-session-form", %{"auth_mode" => "oauth_token"})
      |> render_change()

      refute has_element?(view, "#launch-session-remote-control[checked]")
    end
  end

  describe "Remote Control gating in the launch form (§8.3)" do
    test "mode B (the default) leaves the Remote Control checkbox enabled and checked, no reason shown",
         %{conn: conn} do
      # §9.5's table: "on when mode B" — a fresh launch panel must arrive
      # checked, not merely enabled (review finding, phase 11 round 4: this
      # shipped off by default through round 3).
      {:ok, view, _html} = live(conn, ~p"/sessions")

      refute has_element?(view, "#launch-session-remote-control[disabled]")
      refute has_element?(view, "#launch-session-remote-control-reason")
      assert has_element?(view, "#launch-session-remote-control[checked]")

      view |> form("#launch-session-form") |> render_submit()

      assert [session] = Sessions.list()
      assert session.remote_control == true
    end

    test "selecting mode A disables the checkbox and shows the reason", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/sessions")

      html =
        view
        |> form("#launch-session-form", %{"auth_mode" => "oauth_token"})
        |> render_change()

      assert html =~ ~s(id="launch-session-remote-control-reason")

      assert has_element?(view, "#launch-session-remote-control[disabled]")
    end

    test "switching back to mode B re-enables the checkbox", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/sessions")

      view
      |> form("#launch-session-form", %{"auth_mode" => "oauth_token"})
      |> render_change()

      assert has_element?(view, "#launch-session-remote-control[disabled]")

      view
      |> form("#launch-session-form", %{"auth_mode" => "seeded_credentials"})
      |> render_change()

      refute has_element?(view, "#launch-session-remote-control[disabled]")
    end

    test "switching back to mode B re-checks the box, even after it was un-latched by mode A",
         %{conn: conn} do
      # The checkbox is disabled (and so sends nothing) under mode A, so
      # nothing in the mode-A params can tell "explicitly unchecked" apart
      # from "never touched here". Coming back to mode B must re-arrive
      # checked per §9.5, not carry the disabled box's blank state forward
      # (review finding, phase 11 round 4).
      {:ok, view, _html} = live(conn, ~p"/sessions")

      view
      |> form("#launch-session-form", %{"auth_mode" => "oauth_token"})
      |> render_change()

      refute has_element?(view, "#launch-session-remote-control[checked]")

      view
      |> form("#launch-session-form", %{"auth_mode" => "seeded_credentials"})
      |> render_change()

      assert has_element?(view, "#launch-session-remote-control[checked]")
    end

    test "launching under mode B with the box checked records remote_control: true",
         %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/sessions")

      view
      |> form("#launch-session-form", %{
        "auth_mode" => "seeded_credentials",
        "remote_control" => "true"
      })
      |> render_submit()

      assert [session] = Sessions.list()
      assert session.auth_mode == :seeded_credentials
      assert session.remote_control == true
    end

    test "a submission that spoofs remote_control under mode A is still refused server-side",
         %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/sessions")

      # The disabled attribute stops a normal click, but `render_submit/1`
      # posts whatever params it is given — proving `launch_defaults/1`'s own
      # clamp (not just the disabled checkbox) is what keeps this from ever
      # reaching a row. Mode A has no configured token in this test env, so
      # the launch itself fails (a pre-existing gap of this phase-5 form, not
      # this test's concern) — what matters is that `remote_control` was
      # never `true` on the row it left behind.
      view
      |> form("#launch-session-form", %{
        "auth_mode" => "oauth_token",
        "remote_control" => "true"
      })
      |> render_submit()

      assert [session] = Sessions.list()
      assert session.auth_mode == :oauth_token
      assert session.remote_control == false
    end
  end

  describe "killing" do
    test "kill asks for confirmation first and does nothing until it gets one", %{conn: conn} do
      session = launch!()

      {:ok, view, _html} = live(conn, ~p"/sessions")

      refute has_element?(view, "#kill-session-modal")

      view |> element("#kill-session-#{session.id}") |> render_click()
      assert has_element?(view, "#kill-session-modal")

      # Still running: opening the confirmation is not the action.
      assert {:ok, %{status: :running}} = Sessions.get(session.id)

      view |> element("#cancel-kill") |> render_click()
      refute has_element?(view, "#kill-session-modal")
      assert {:ok, %{status: :running}} = Sessions.get(session.id)
    end

    test "confirming the kill ends the session and says so in the list", %{conn: conn} do
      session = launch!()

      {:ok, view, _html} = live(conn, ~p"/sessions")

      view |> element("#kill-session-#{session.id}") |> render_click()
      html = view |> element("#confirm-kill") |> render_click()

      assert {:ok, %{status: :ended}} = Sessions.get(session.id)
      refute has_element?(view, "#kill-session-modal")
      assert html =~ "ended"
    end
  end
end
