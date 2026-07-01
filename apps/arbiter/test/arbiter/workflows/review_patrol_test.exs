defmodule Arbiter.Workflows.ReviewPatrolTest do
  use Arbiter.DataCase, async: false

  alias Arbiter.Tasks.{Issue, Workspace}
  alias Arbiter.Workflows.ReviewPatrol
  require Ash.Query

  # ReviewPatrol routes forge calls through the MR adapter (Arbiter.Mergers.Github),
  # whose Req plug is Arbiter.Mergers.Github.HTTP.
  @stub_name Arbiter.Mergers.Github.HTTP

  setup do
    {:ok, ws} =
      Ash.create(Workspace, %{
        name: "reviewpatrol-#{System.unique_integer([:positive])}",
        prefix: "rp",
        config: %{
          "merge" => %{
            "strategy" => "github",
            "config" => %{
              "owner" => "owner",
              "repo" => "repo",
              "credentials_ref" => "env:GITHUB_TOKEN"
            }
          }
        }
      })

    prior = System.get_env("GITHUB_TOKEN")
    System.put_env("GITHUB_TOKEN", "test-token-reviewpatrol")

    on_exit(fn ->
      if prior, do: System.put_env("GITHUB_TOKEN", prior), else: System.delete_env("GITHUB_TOKEN")
    end)

    {:ok, ws: ws}
  end

  defp stub(fun), do: Req.Test.stub(@stub_name, fun)

  defp start_patrol(ws, opts \\ []) do
    name = String.to_atom("ReviewPatrol_#{System.unique_integer([:positive])}")

    pid =
      start_supervised!(
        {ReviewPatrol,
         Keyword.merge(
           [repo: "owner/repo", workspace_id: ws.id, interval_ms: 60_000, name: name],
           opts
         )}
      )

    Req.Test.allow(@stub_name, self(), pid)
    {pid, name}
  end

  # A review engagement: review_only task with a source_pr, left open.
  #
  # `review_only` and the engagement fields (last_reviewed_sha, …) are NOT
  # create-accepted — they're stamped via the `:update` action, mirroring how
  # dispatch.ex marks a review-only task (bd-6xaaam / bd-cw3w9p). So create with
  # the create-accepted fields, then update the rest.
  defp engagement(ws, source_pr, attrs \\ %{}) do
    {create_attrs, update_attrs} = Map.split(attrs, [:tracker_type, :tracker_ref])

    {:ok, task} =
      Ash.create(
        Issue,
        Map.merge(
          %{
            title: "Review PR ##{source_pr}",
            tracker_type: :none,
            source_pr: to_string(source_pr),
            workspace_id: ws.id
          },
          create_attrs
        )
      )

    {:ok, task} = Ash.update(task, Map.merge(%{review_only: true}, update_attrs), action: :update)

    task
  end

  # Stub adapter.get(source_pr) → a PR with the given state (+ optional head sha).
  # ReviewPatrol's get/1 hits GET /pulls/:n and GET /pulls/:n/reviews.
  defp pr_stub(number, pr_json) do
    stub(fn conn ->
      cond do
        conn.request_path == "/repos/owner/repo/pulls/#{number}" ->
          conn |> Plug.Conn.put_status(200) |> Req.Test.json(pr_json)

        conn.request_path == "/repos/owner/repo/pulls/#{number}/reviews" ->
          conn |> Plug.Conn.put_status(200) |> Req.Test.json([])

        true ->
          conn |> Plug.Conn.put_status(500) |> Req.Test.json(%{})
      end
    end)
  end

  defp reload(task), do: Ash.get!(Issue, task.id)

  describe "start_link/1" do
    test "starts with given config", %{ws: ws} do
      {_pid, name} = start_patrol(ws)
      snap = ReviewPatrol.state(name)
      assert snap.repo == "owner/repo"
      assert snap.workspace_id == ws.id
      assert snap.ticks == 0
    end
  end

  describe "tick/1 — merged / closed PR terminates the engagement" do
    test "merged PR → engagement task closed within one tick", %{ws: ws} do
      eng = engagement(ws, 100)
      pr_stub(100, %{"number" => 100, "merged" => true, "html_url" => "x"})

      {_pid, name} = start_patrol(ws)
      assert :ok = ReviewPatrol.tick(name)

      assert reload(eng).status == :closed
      assert ReviewPatrol.state(name).last_terminated == [eng.id]
    end

    test "closed (unmerged) PR → engagement task closed within one tick", %{ws: ws} do
      eng = engagement(ws, 101)
      pr_stub(101, %{"number" => 101, "state" => "closed", "html_url" => "x"})

      {_pid, name} = start_patrol(ws)
      assert :ok = ReviewPatrol.tick(name)

      assert reload(eng).status == :closed
    end

    test "idempotent: re-ticking an already-closed engagement is a no-op", %{ws: ws} do
      eng = engagement(ws, 102)
      pr_stub(102, %{"number" => 102, "merged" => true, "html_url" => "x"})

      {_pid, name} = start_patrol(ws)
      assert :ok = ReviewPatrol.tick(name)
      assert reload(eng).status == :closed

      # Second tick: the engagement is already :closed, so the query excludes it
      # and nothing is terminated again.
      assert :ok = ReviewPatrol.tick(name)
      assert ReviewPatrol.state(name).last_terminated == []
      assert reload(eng).status == :closed
    end
  end

  describe "tick/1 — open PR records head SHA" do
    test "open PR with unset last_reviewed_sha → SHA recorded, task stays open", %{ws: ws} do
      eng = engagement(ws, 103)

      pr_stub(103, %{
        "number" => 103,
        "state" => "open",
        "head" => %{"sha" => "deadbeef"},
        "html_url" => "x"
      })

      {_pid, name} = start_patrol(ws)
      assert :ok = ReviewPatrol.tick(name)

      reloaded = reload(eng)
      assert reloaded.status != :closed
      assert reloaded.last_reviewed_sha == "deadbeef"
      assert ReviewPatrol.state(name).last_terminated == []
    end

    test "open PR with last_reviewed_sha already set → no-op (SHA unchanged)", %{ws: ws} do
      eng = engagement(ws, 104, %{last_reviewed_sha: "original"})

      pr_stub(104, %{
        "number" => 104,
        "state" => "open",
        "head" => %{"sha" => "newsha"},
        "html_url" => "x"
      })

      {_pid, name} = start_patrol(ws)
      assert :ok = ReviewPatrol.tick(name)

      # Re-review of a new commit lands in task D; this skeleton must NOT touch
      # an already-recorded SHA.
      assert reload(eng).last_reviewed_sha == "original"
      assert reload(eng).status != :closed
    end
  end

  describe "tick/1 — query isolation from PRPatrol author-side follow-ups" do
    test "does NOT pick up a non-review_only follow-up with the same source_pr", %{ws: ws} do
      # A PRPatrol author-side follow-up: review_only defaults to false, source_pr set.
      {:ok, follow_up} =
        Ash.create(Issue, %{
          title: "PR #200 needs follow-up",
          tracker_type: :none,
          source_pr: "200",
          workspace_id: ws.id
        })

      # If ReviewPatrol touched it, this merged stub would close it.
      pr_stub(200, %{"number" => 200, "merged" => true, "html_url" => "x"})

      {_pid, name} = start_patrol(ws)
      assert :ok = ReviewPatrol.tick(name)

      # The author-side follow-up is untouched — ReviewPatrol filters review_only.
      assert reload(follow_up).status != :closed
      assert ReviewPatrol.state(name).last_terminated == []
    end
  end

  describe "tick/1 — closing a review_only engagement fires ZERO tracker writes" do
    # A github TRACKER (distinct from the github MERGER) so SyncTracker would
    # normally PATCH the upstream issue on close. The review_only guard
    # (bd-6xaaam) must suppress every tracker call. Merger HTTP is
    # `Arbiter.Mergers.Github.HTTP`; tracker HTTP is `Arbiter.Trackers.GitHub.HTTP`.
    @tracker_stub Arbiter.Trackers.GitHub.HTTP

    test "merged PR closes the engagement without any tracker GET/PATCH", %{ws: _ws} do
      env = "REVIEW_PATROL_TRACKER_TOKEN"
      System.put_env(env, "test-tracker-token")
      on_exit(fn -> System.delete_env(env) end)

      {:ok, tracked_ws} =
        Ash.create(Workspace, %{
          name: "rp-tracked-#{System.unique_integer([:positive])}",
          prefix: "rt#{System.unique_integer([:positive])}",
          config: %{
            "merge" => %{
              "strategy" => "github",
              "config" => %{
                "owner" => "owner",
                "repo" => "repo",
                "credentials_ref" => "env:GITHUB_TOKEN"
              }
            },
            "tracker" => %{
              "type" => "github",
              "config" => %{
                "owner" => "owner",
                "repo" => "repo",
                "credentials_ref" => "env:#{env}"
              }
            }
          }
        })

      # A review engagement that DOES carry a live tracker ref — so the only
      # thing suppressing a tracker write is the review_only guard.
      eng = engagement(tracked_ws, 300, %{tracker_type: :github, tracker_ref: "999"})

      pr_stub(300, %{"number" => 300, "merged" => true, "html_url" => "x"})

      # Forward any tracker HTTP call to the test process so we can assert none happens.
      test_pid = self()

      Req.Test.stub(@tracker_stub, fn conn ->
        send(test_pid, {:tracker, conn.method, conn.request_path})

        conn
        |> Plug.Conn.put_status(200)
        |> Req.Test.json(%{"number" => 999, "state" => "closed"})
      end)

      {pid, name} = start_patrol(tracked_ws)
      Req.Test.allow(@tracker_stub, self(), pid)

      assert :ok = ReviewPatrol.tick(name)

      # Engagement terminated…
      assert reload(eng).status == :closed
      # …with ZERO tracker traffic.
      refute_receive {:tracker, _, _}
    end
  end

  describe "periodic ticking" do
    test "the :tick message reschedules itself", %{ws: ws} do
      # No engagements → every tick no-ops, but the counter still advances.
      {_pid, name} = start_patrol(ws, interval_ms: 50)
      Process.sleep(250)

      assert ReviewPatrol.state(name).ticks >= 2,
             "expected at least 2 auto-ticks; got #{ReviewPatrol.state(name).ticks}"
    end
  end

  describe "tick/1 — error handling" do
    test "adapter get failure → bumps tick counter, does not crash", %{ws: ws} do
      _eng = engagement(ws, 105)

      stub(fn conn ->
        conn |> Plug.Conn.put_status(500) |> Req.Test.json(%{"error" => "boom"})
      end)

      {_pid, name} = start_patrol(ws)
      assert :ok = ReviewPatrol.tick(name)
      assert ReviewPatrol.state(name).ticks == 1
      assert ReviewPatrol.state(name).last_terminated == []
    end
  end
end
