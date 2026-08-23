defmodule ArbiterWeb.WorkspaceConfigScreenTest do
  @moduledoc """
  Chrome guarantees for the redesigned workspace config screens.

  `ArbiterWeb.WorkspaceLiveTest` pins the *behaviour* (every form, every
  validation) and `ArbiterWeb.WorkspaceDetailComponentsTest` pins *who owns
  which event*. What neither can see is the shape the operator actually reads:
  the eight-item section rail, and the rule that no setting is ever shown
  without a one-line statement of what changing it does. Those are pinned here
  so a future restyle cannot quietly drop them.
  """
  use ArbiterWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Arbiter.Board.Autopilot
  alias Arbiter.Tasks.Workspace

  @sections [
    {"repos", "Repos"},
    {"policy", "Policy"},
    {"agent_models", "Agent models"},
    {"routing", "Routing"},
    {"standing_orders", "Standing orders"},
    {"tracker", "Tracker"},
    {"secrets", "Secrets"},
    {"security", "Security"}
  ]

  defp new_workspace(attrs \\ %{}) do
    base = %{name: "ws-#{System.unique_integer([:positive])}", prefix: "wx"}
    {:ok, ws} = Ash.create(Workspace, Map.merge(base, attrs))
    ws
  end

  describe "the section rail" do
    test "offers all eight sections, in the handoff order", %{conn: conn} do
      ws = new_workspace()
      {:ok, view, html} = live(conn, ~p"/workspaces/#{ws.id}")

      for {slug, label} <- @sections do
        assert has_element?(view, ~s(#ws-rail button[phx-value-section="#{slug}"]), label),
               "the #{label} rail item is missing"
      end

      order =
        Regex.scan(~r/phx-value-section="([a-z_]+)"/, html)
        |> Enum.map(fn [_, slug] -> slug end)
        |> Enum.uniq()

      assert order == Enum.map(@sections, &elem(&1, 0))
    end

    test "opens on Repos and follows the operator to another section", %{conn: conn} do
      ws = new_workspace()
      {:ok, view, _html} = live(conn, ~p"/workspaces/#{ws.id}")

      assert has_element?(
               view,
               ~s(#ws-rail button[phx-value-section="repos"][aria-selected="true"])
             )

      html =
        view
        |> element(~s(#ws-rail button[phx-value-section="security"]))
        |> render_click()

      assert html =~ ~s(phx-value-section="security" aria-selected="true") or
               has_element?(
                 view,
                 ~s(#ws-rail button[phx-value-section="security"][aria-selected="true"])
               )

      refute has_element?(
               view,
               ~s(#ws-rail button[phx-value-section="repos"][aria-selected="true"])
             )
    end

    test "names the section and its workspace context in the body header", %{conn: conn} do
      ws = new_workspace()
      {:ok, view, _html} = live(conn, ~p"/workspaces/#{ws.id}")

      assert has_element?(view, ~s([data-section-context="repos"]), "0 paths")
      assert has_element?(view, ~s([data-section-context="policy"]), "workspace: #{ws.name}")
    end

    test "ends the page on a way back to the board", %{conn: conn} do
      ws = new_workspace()
      {:ok, _view, html} = live(conn, ~p"/workspaces/#{ws.id}")
      assert html =~ "Back to board"
    end
  end

  describe "consequence copy" do
    test "every setting row states what changing it does", %{conn: conn} do
      ws = new_workspace(%{config: %{"tracker" => %{"type" => "github"}}})
      {:ok, view, _html} = live(conn, ~p"/workspaces/#{ws.id}")

      html = render(view)

      rows = Regex.scan(~r/data-setting-row="([^"]*)"/, html) |> Enum.map(&Enum.at(&1, 1))
      consequences = Regex.scan(~r/data-consequence="([^"]*)"/, html) |> Enum.map(&Enum.at(&1, 1))

      assert rows != [], "the page renders no setting rows at all"

      assert length(rows) == length(consequences),
             "#{length(rows)} setting rows but #{length(consequences)} consequence lines"

      assert Enum.reject(consequences, &(String.trim(&1) != "")) == [],
             "some setting rows carry an empty consequence line"
    end

    test "the concurrency cap explains how it combines with the other caps", %{conn: conn} do
      ws = new_workspace()
      {:ok, _view, html} = live(conn, ~p"/workspaces/#{ws.id}")

      assert html =~ "Max concurrent workers"
      assert html =~ "lowest of this, the system cap and quota headroom"
    end

    test "auto-dispatch describes the scheduler, not manual dispatch", %{conn: conn} do
      ws = new_workspace()
      {:ok, view, html} = live(conn, ~p"/workspaces/#{ws.id}")

      assert html =~ "Auto-dispatch ready issues"
      assert has_element?(view, ~s([data-setting-row="Auto-dispatch ready issues"]))

      [consequence] =
        Regex.run(
          ~r/data-setting-row="Auto-dispatch ready issues".*?data-consequence="([^"]*)"/s,
          html,
          capture: :all_but_first
        )

      assert consequence =~ "Ready"
      refute consequence =~ "manual"
    end
  end

  describe "the repos section" do
    test "tabulates each repo with its worktree state", %{conn: conn} do
      ws =
        new_workspace(%{
          config: %{
            "repo_paths" => %{
              "arbiter" => "/tmp/no-such-worktree-#{:erlang.unique_integer([:positive])}"
            }
          }
        })

      {:ok, view, _html} = live(conn, ~p"/workspaces/#{ws.id}")

      assert has_element?(view, "#repo-paths thead", "worktree")
      assert has_element?(view, "#repo-paths", "arbiter")
      assert has_element?(view, ~s(#repo-paths [data-worktree-state]))
    end

    test "chips a clean worktree as clean and a dirty one as dirty", %{conn: conn} do
      clean = Path.join(System.tmp_dir!(), "arb-clean-#{:erlang.unique_integer([:positive])}")
      dirty = Path.join(System.tmp_dir!(), "arb-dirty-#{:erlang.unique_integer([:positive])}")

      for dir <- [clean, dirty] do
        File.mkdir_p!(dir)
        {_, 0} = System.cmd("git", ["init", "-q", dir])
        File.write!(Path.join(dir, "README.md"), "hi\n")
        {_, 0} = System.cmd("git", ["-C", dir, "add", "."])

        {_, 0} =
          System.cmd("git", [
            "-C",
            dir,
            "-c",
            "user.email=t@t",
            "-c",
            "user.name=t",
            "commit",
            "-qm",
            "init"
          ])
      end

      File.write!(Path.join(dirty, "README.md"), "changed\n")
      on_exit(fn -> Enum.each([clean, dirty], &File.rm_rf/1) end)

      ws =
        new_workspace(%{
          config: %{"repo_paths" => %{"cleanrepo" => clean, "dirtyrepo" => dirty}}
        })

      {:ok, view, _html} = live(conn, ~p"/workspaces/#{ws.id}")

      assert has_element?(view, ~s(#repo-paths [data-worktree-state="clean"]))
      assert has_element?(view, ~s(#repo-paths [data-worktree-state="dirty"]))
    end

    test "offers a register control for a new repo path", %{conn: conn} do
      ws = new_workspace()
      {:ok, view, _html} = live(conn, ~p"/workspaces/#{ws.id}")

      assert has_element?(view, ~s(input[name="repo_path[path]"][placeholder="~/dev/my-project"]))

      assert has_element?(
               view,
               ~s(form[phx-submit=add_repo_path] button[type=submit]),
               "Register"
             )
    end
  end

  describe "the auto-dispatch switch" do
    @switch ~s(button[role="switch"][aria-label="Auto-dispatch ready issues"])

    # The autopilot is one process for the whole VM and ships paused in test.
    # These tests move it, so put it back however they leave it.
    setup do
      on_exit(fn -> Autopilot.pause(Autopilot) end)
      :ok
    end

    test "reads off while the board scheduler is paused", %{conn: conn} do
      Autopilot.pause(Autopilot)
      ws = new_workspace()
      {:ok, view, _html} = live(conn, ~p"/workspaces/#{ws.id}")

      assert has_element?(view, @switch <> ~s([aria-checked="false"]))
    end

    test "reads on while the board scheduler is promoting", %{conn: conn} do
      Autopilot.resume(Autopilot)
      ws = new_workspace()
      {:ok, view, _html} = live(conn, ~p"/workspaces/#{ws.id}")

      assert has_element?(view, @switch <> ~s([aria-checked="true"])),
             "a running, unpaused autopilot must read as on"
    end

    # The regression this pins: an `autodispatch_on?` that always answered
    # `false` left the switch stuck on the resume branch, so clicking it could
    # start the scheduler but never stop it.
    test "pauses the scheduler on the way down and resumes it on the way up", %{conn: conn} do
      Autopilot.resume(Autopilot)
      ws = new_workspace()
      {:ok, view, _html} = live(conn, ~p"/workspaces/#{ws.id}")

      html = view |> element(@switch) |> render_click()

      assert Autopilot.paused?(Autopilot)
      assert html =~ "Auto-dispatch paused."
      assert has_element?(view, @switch <> ~s([aria-checked="false"]))

      html = view |> element(@switch) |> render_click()

      refute Autopilot.paused?(Autopilot)
      assert html =~ "Auto-dispatch resumed."
      assert has_element?(view, @switch <> ~s([aria-checked="true"]))
    end
  end

  # A checkbox with no `phx-change` has nothing to re-render it, so the tick
  # has to come from the input's own `:checked` state. Both of these boxes say
  # something an operator must be able to read back: whether a value is
  # encrypted at rest, and whether a destructive-op guard is on.
  describe "checkbox state" do
    test "paints the worker-env secret box from the box itself", %{conn: conn} do
      ws = new_workspace()
      {:ok, view, _html} = live(conn, ~p"/workspaces/#{ws.id}")

      html = view |> element("button[phx-click=open_worker_env_modal]") |> render_click()

      assert html =~ ~s(name="worker_env[secret]")
      assert html =~ "peer-checked:bg-[var(--accent-primary)]"
    end

    test "shows no tick on an unchecked safe-default guard", %{conn: conn} do
      ws = new_workspace()
      {:ok, _view, html} = live(conn, ~p"/workspaces/#{ws.id}")

      [_, span_class] =
        Regex.run(
          ~r/name="security\[safe_defaults\]\[[a-z_]+\]"[^>]*>\s*<span class="([^"]+)"/,
          html
        )

      assert span_class =~ "text-transparent"
      assert span_class =~ "peer-checked:text-[var(--accent-primary-ink)]"
    end
  end

  describe "the workspace index" do
    test "carries the console index header and a way back to the board", %{conn: conn} do
      new_workspace()
      {:ok, _view, html} = live(conn, ~p"/workspaces")

      assert html =~ "hero-cog-6-tooth"

      assert html =~
               "Tracker, merger, agent routing, standing orders and secrets — per workspace."

      assert html =~ "Back to board"
    end
  end
end
