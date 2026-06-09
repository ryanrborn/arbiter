defmodule Arbiter.Workflows.PRPatrolTest do
  use Arbiter.DataCase, async: false

  alias Arbiter.Beads.{Issue, Workspace}
  alias Arbiter.Polecat
  alias Arbiter.Workflows.PRPatrol
  require Ash.Query

  @stub_name Arbiter.GitHub.HTTP

  setup do
    {:ok, ws} =
      Ash.create(Workspace, %{
        name: "prpatrol-#{System.unique_integer([:positive])}",
        prefix: "pp"
      })

    # `:github_http_stub` is set globally in config/test.exs; don't touch it.
    # GITHUB_TOKEN is what GitHub.fetch_token!/1 checks; PRPatrol calls
    # GitHub without `opts[:token]` so we need the env var set somewhere.
    prior = System.get_env("GITHUB_TOKEN")
    System.put_env("GITHUB_TOKEN", "test-token-prpatrol")

    on_exit(fn ->
      if prior, do: System.put_env("GITHUB_TOKEN", prior), else: System.delete_env("GITHUB_TOKEN")
    end)

    {:ok, ws: ws}
  end

  defp stub(fun), do: Req.Test.stub(@stub_name, fun)

  defp start_patrol(ws, opts \\ []) do
    name = String.to_atom("PRPatrol_#{System.unique_integer([:positive])}")

    {:ok, pid} =
      PRPatrol.start_link(
        Keyword.merge(
          [
            repo: "owner/repo",
            workspace_id: ws.id,
            interval_ms: 60_000,
            name: name
          ],
          opts
        )
      )

    # Let the GenServer process see this test process's Req.Test stub.
    Req.Test.allow(@stub_name, self(), pid)

    {pid, name}
  end

  describe "start_link/1" do
    test "starts with given config", %{ws: ws} do
      {_pid, name} = start_patrol(ws)
      snap = PRPatrol.state(name)
      assert snap.repo == "owner/repo"
      assert snap.workspace_id == ws.id
      assert snap.ticks == 0
    end
  end

  describe "tick/1 — no actionable PRs" do
    test "empty PR list → no beads created", %{ws: ws} do
      stub(fn conn ->
        conn |> Plug.Conn.put_status(200) |> Req.Test.json([])
      end)

      {_pid, name} = start_patrol(ws)
      assert :ok = PRPatrol.tick(name)
      assert PRPatrol.state(name).ticks == 1

      assert beads_for_repo() == []
    end

    test "PR with all-APPROVED reviews → no bead", %{ws: ws} do
      stub(fn conn ->
        cond do
          conn.request_path == "/repos/owner/repo/pulls" ->
            conn
            |> Plug.Conn.put_status(200)
            |> Req.Test.json([%{"number" => 41, "title" => "ok", "html_url" => "x"}])

          conn.request_path == "/repos/owner/repo/pulls/41/reviews" ->
            conn
            |> Plug.Conn.put_status(200)
            |> Req.Test.json([%{"state" => "APPROVED"}])

          true ->
            conn |> Plug.Conn.put_status(500) |> Req.Test.json(%{})
        end
      end)

      {_pid, name} = start_patrol(ws)
      assert :ok = PRPatrol.tick(name)
      assert beads_for_repo() == []
    end
  end

  describe "tick/1 — actionable PRs" do
    test "CHANGES_REQUESTED → 1 bead created, polecat spawned", %{ws: ws} do
      stub(fn conn ->
        cond do
          conn.request_path == "/repos/owner/repo/pulls" ->
            conn
            |> Plug.Conn.put_status(200)
            |> Req.Test.json([
              %{"number" => 42, "title" => "needs work", "html_url" => "https://gh/pr/42"}
            ])

          conn.request_path == "/repos/owner/repo/pulls/42/reviews" ->
            conn
            |> Plug.Conn.put_status(200)
            |> Req.Test.json([%{"state" => "CHANGES_REQUESTED", "user" => %{"login" => "alice"}}])

          true ->
            conn |> Plug.Conn.put_status(500) |> Req.Test.json(%{})
        end
      end)

      {_pid, name} = start_patrol(ws)
      :ok = PRPatrol.tick(name)

      [bead] = beads_for_repo()
      assert bead.tracker_type == :github
      assert bead.tracker_ref == "42"
      assert bead.title =~ "PR #42"
      assert bead.workspace_id == ws.id

      # Polecat is registered for this bead
      assert is_pid(Polecat.whereis(bead.id))
    end

    test "dedup: second tick with the same actionable PR does NOT create another bead", %{ws: ws} do
      stub(fn conn ->
        cond do
          conn.request_path == "/repos/owner/repo/pulls" ->
            conn
            |> Plug.Conn.put_status(200)
            |> Req.Test.json([%{"number" => 43, "title" => "twice", "html_url" => "x"}])

          conn.request_path == "/repos/owner/repo/pulls/43/reviews" ->
            conn
            |> Plug.Conn.put_status(200)
            |> Req.Test.json([%{"state" => "CHANGES_REQUESTED"}])

          true ->
            conn |> Plug.Conn.put_status(500) |> Req.Test.json(%{})
        end
      end)

      {_pid, name} = start_patrol(ws)
      :ok = PRPatrol.tick(name)
      :ok = PRPatrol.tick(name)

      assert length(beads_for_repo()) == 1
    end

    test "closed follow-up bead does not block re-dispatch on a new CHANGES_REQUESTED",
         %{ws: ws} do
      # Bead exists but is closed → dedup must not skip the dispatch.
      {:ok, old} =
        Ash.create(Issue, %{
          title: "old PR follow-up",
          tracker_type: :github,
          tracker_ref: "44",
          workspace_id: ws.id
        })

      {:ok, _closed} = Ash.update(old, %{}, action: :close)

      stub(fn conn ->
        cond do
          conn.request_path == "/repos/owner/repo/pulls" ->
            conn
            |> Plug.Conn.put_status(200)
            |> Req.Test.json([%{"number" => 44, "title" => "back again", "html_url" => "x"}])

          conn.request_path == "/repos/owner/repo/pulls/44/reviews" ->
            conn
            |> Plug.Conn.put_status(200)
            |> Req.Test.json([%{"state" => "CHANGES_REQUESTED"}])

          true ->
            conn |> Plug.Conn.put_status(500) |> Req.Test.json(%{})
        end
      end)

      {_pid, name} = start_patrol(ws)
      :ok = PRPatrol.tick(name)

      open_beads = beads_for_repo() |> Enum.filter(&(&1.status != :closed))
      assert length(open_beads) == 1
    end
  end

  describe "periodic ticking" do
    test "the :tick message reschedules itself", %{ws: ws} do
      stub(fn conn ->
        conn |> Plug.Conn.put_status(200) |> Req.Test.json([])
      end)

      {_pid, name} = start_patrol(ws, interval_ms: 50)

      # Wait long enough for at least 2 fires (first at ~50ms, second at ~100ms)
      Process.sleep(250)

      assert PRPatrol.state(name).ticks >= 2,
             "expected at least 2 auto-ticks; got #{PRPatrol.state(name).ticks}"
    end
  end

  describe "tick/1 — error handling" do
    test "GitHub list API failure → bumps tick counter, does not crash", %{ws: ws} do
      stub(fn conn ->
        conn |> Plug.Conn.put_status(500) |> Req.Test.json(%{"error" => "boom"})
      end)

      {_pid, name} = start_patrol(ws)
      assert :ok = PRPatrol.tick(name)
      assert PRPatrol.state(name).ticks == 1
      assert beads_for_repo() == []
    end
  end

  # ---- helpers ----

  defp beads_for_repo do
    Issue
    |> Ash.Query.filter(tracker_type == :github)
    |> Ash.read!()
  end
end
