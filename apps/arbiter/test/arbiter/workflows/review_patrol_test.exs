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

  describe "tick/1 — new-commit re-review (bd-f3fg22)" do
    # A prior finding we'd have posted on the first review, stored on the
    # engagement so the relevance gate + de-dupe have something to compare against.
    defp finding(file, line, message, severity \\ "error") do
      %{"file" => file, "line" => line, "message" => message, "severity" => severity}
    end

    # Bypass the real Claude reviewer: CodeReview.Checks reads this invoker and
    # parses its JSON into findings. The dedupe wrapper in ReviewPatrol then filters.
    defp put_invoker(findings) do
      json = Jason.encode!(%{"findings" => findings})
      Application.put_env(:arbiter, :code_review_invoker, fn _prompt, _state -> {:ok, json} end)
      on_exit(fn -> Application.delete_env(:arbiter, :code_review_invoker) end)
    end

    # Stub the whole re-review conversation for an OPEN PR at `head`:
    #   adapter.get   → GET /pulls/:n  (+ /reviews, + check-runs → 500 = CI settled)
    #   new-diff-only → GET /compare/base...head  (served with `diff`)
    #   posting       → POST /pulls/:n/comments  and  POST /pulls/:n/reviews
    # Forge writes are forwarded to the test process so we can assert on them.
    defp rereview_stub(number, head, diff) do
      test_pid = self()

      stub(fn conn ->
        path = conn.request_path

        cond do
          conn.method == "GET" and String.starts_with?(path, "/repos/owner/repo/compare/") ->
            send(test_pid, {:compare, path})

            conn
            |> Plug.Conn.put_resp_header("content-type", "text/plain")
            |> Plug.Conn.resp(200, diff)

          conn.method == "GET" and path == "/repos/owner/repo/pulls/#{number}" ->
            conn
            |> Plug.Conn.put_status(200)
            |> Req.Test.json(%{
              "number" => number,
              "state" => "open",
              "head" => %{"sha" => head},
              "html_url" => "x"
            })

          conn.method == "GET" and path == "/repos/owner/repo/pulls/#{number}/reviews" ->
            conn |> Plug.Conn.put_status(200) |> Req.Test.json([])

          conn.method == "POST" and path == "/repos/owner/repo/pulls/#{number}/comments" ->
            {:ok, body, conn} = Plug.Conn.read_body(conn)
            send(test_pid, {:inline_comment, Jason.decode!(body)})
            conn |> Plug.Conn.put_status(201) |> Req.Test.json(%{"id" => 1})

          conn.method == "POST" and path == "/repos/owner/repo/pulls/#{number}/reviews" ->
            {:ok, body, conn} = Plug.Conn.read_body(conn)
            send(test_pid, {:submit_review, Jason.decode!(body)})
            conn |> Plug.Conn.put_status(200) |> Req.Test.json(%{"id" => 99})

          true ->
            conn
            |> Plug.Conn.put_status(500)
            |> Req.Test.json(%{"message" => "unhandled #{path}"})
        end
      end)
    end

    test "a push touching a previously-flagged file triggers exactly one re-review", %{ws: ws} do
      eng =
        engagement(ws, 400, %{
          review_automation: :auto,
          last_reviewed_sha: "oldsha",
          posted_findings: [finding("lib/a.ex", 5, "prior issue")]
        })

      # The new commit surfaces a DIFFERENT finding in the flagged file.
      put_invoker([
        %{"severity" => "error", "file" => "lib/a.ex", "line" => 10, "message" => "new bug"}
      ])

      diff = "diff --git a/lib/a.ex b/lib/a.ex\n--- a/lib/a.ex\n+++ b/lib/a.ex\n@@ -1 +1 @@\n+x\n"
      rereview_stub(400, "newsha", diff)

      {_pid, name} = start_patrol(ws)
      assert :ok = ReviewPatrol.tick(name)

      # New-diff-only: the compare endpoint (not the whole-PR diff) was hit.
      assert_receive {:compare, path}
      assert path =~ "oldsha...newsha"

      # Exactly one inline comment + one review submitted.
      assert_receive {:inline_comment, comment}
      assert comment["path"] == "lib/a.ex"
      assert comment["line"] == 10
      assert_receive {:submit_review, _review}

      reloaded = reload(eng)
      # last_reviewed_sha advanced after posting; the new finding was appended.
      assert reloaded.last_reviewed_sha == "newsha"
      assert length(reloaded.posted_findings) == 2
      assert ReviewPatrol.state(name).last_rereviewed == [eng.id]
    end

    test "a push touching only unrelated files does NOT trigger a re-review", %{ws: ws} do
      eng =
        engagement(ws, 401, %{
          review_automation: :auto,
          last_reviewed_sha: "oldsha",
          posted_findings: [finding("lib/a.ex", 5, "prior issue")]
        })

      put_invoker([
        %{"severity" => "error", "file" => "lib/a.ex", "line" => 10, "message" => "new bug"}
      ])

      # The new commit touches lib/other.ex — a file we never flagged.
      diff =
        "diff --git a/lib/other.ex b/lib/other.ex\n--- a/lib/other.ex\n+++ b/lib/other.ex\n@@ -1 +1 @@\n+y\n"

      rereview_stub(401, "newsha", diff)

      {_pid, name} = start_patrol(ws)
      assert :ok = ReviewPatrol.tick(name)

      # Relevance gate: diff fetched, but nothing posted and the SHA is untouched.
      assert_receive {:compare, _path}
      refute_receive {:inline_comment, _}
      refute_receive {:submit_review, _}

      assert reload(eng).last_reviewed_sha == "oldsha"
      assert ReviewPatrol.state(name).last_rereviewed == []
    end

    test "debounce: a re-review inside the window is suppressed", %{ws: ws} do
      eng =
        engagement(ws, 402, %{
          review_automation: :auto,
          last_reviewed_sha: "oldsha",
          # Reviewed just now → inside the default 5-minute debounce window.
          last_reviewed_at: DateTime.truncate(DateTime.utc_now(), :second),
          posted_findings: [finding("lib/a.ex", 5, "prior issue")]
        })

      put_invoker([
        %{"severity" => "error", "file" => "lib/a.ex", "line" => 10, "message" => "new bug"}
      ])

      diff = "diff --git a/lib/a.ex b/lib/a.ex\n--- a/lib/a.ex\n+++ b/lib/a.ex\n@@ -1 +1 @@\n+x\n"
      rereview_stub(402, "newsha", diff)

      {_pid, name} = start_patrol(ws)
      assert :ok = ReviewPatrol.tick(name)

      # Debounce short-circuits before any diff fetch or posting.
      refute_receive {:submit_review, _}
      assert reload(eng).last_reviewed_sha == "oldsha"
      assert ReviewPatrol.state(name).last_rereviewed == []
    end

    test "an unchanged finding (same file/line/message) is not re-posted", %{ws: ws} do
      eng =
        engagement(ws, 403, %{
          review_automation: :auto,
          last_reviewed_sha: "oldsha",
          posted_findings: [finding("lib/a.ex", 10, "same bug")]
        })

      # The re-review surfaces the IDENTICAL finding we already posted.
      put_invoker([
        %{"severity" => "error", "file" => "lib/a.ex", "line" => 10, "message" => "same bug"}
      ])

      diff = "diff --git a/lib/a.ex b/lib/a.ex\n--- a/lib/a.ex\n+++ b/lib/a.ex\n@@ -1 +1 @@\n+x\n"
      rereview_stub(403, "newsha", diff)

      {_pid, name} = start_patrol(ws)
      assert :ok = ReviewPatrol.tick(name)

      # The duplicate is filtered out before posting: no inline comment.
      refute_receive {:inline_comment, _}
      # A verdict is still submitted (a clean re-review with nothing new).
      assert_receive {:submit_review, review}
      assert review["event"] == "APPROVE"

      reloaded = reload(eng)
      # SHA advances after the (empty) re-review; no duplicate appended.
      assert reloaded.last_reviewed_sha == "newsha"
      assert length(reloaded.posted_findings) == 1
    end

    test "flag mode surfaces a flag instead of re-reviewing", %{ws: ws} do
      eng =
        engagement(ws, 404, %{
          review_automation: :flag,
          last_reviewed_sha: "oldsha",
          posted_findings: [finding("lib/a.ex", 5, "prior issue")]
        })

      diff = "diff --git a/lib/a.ex b/lib/a.ex\n--- a/lib/a.ex\n+++ b/lib/a.ex\n@@ -1 +1 @@\n+x\n"
      rereview_stub(404, "newsha", diff)

      {_pid, name} = start_patrol(ws)
      assert :ok = ReviewPatrol.tick(name)

      # No review posted — but the cursor advances so the same commits aren't
      # re-flagged, and the engagement is recorded as flagged this tick.
      refute_receive {:submit_review, _}
      assert reload(eng).last_reviewed_sha == "newsha"
      assert ReviewPatrol.state(name).last_flagged == [eng.id]

      flags =
        Arbiter.Messages.Message
        |> Ash.Query.filter(directive_ref == ^eng.id and kind == :flag)
        |> Ash.read!()

      assert length(flags) == 1
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
