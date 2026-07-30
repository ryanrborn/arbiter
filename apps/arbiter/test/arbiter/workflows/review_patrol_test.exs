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
          },
          # The fleet's own reviewer login — phase-2 author-reply handling uses
          # this to keep only the review threads we participated in.
          "review_patrol" => %{"our_login" => "botreviewer"}
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
        Supervisor.child_spec(
          {ReviewPatrol,
           Keyword.merge(
             [repo: "owner/repo", workspace_id: ws.id, interval_ms: 60_000, name: name],
             opts
           )},
          id: name
        )
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
      # An open engagement keeps the lazy-stop guard (bd-7tr11p) satisfied so
      # the scheduled ticks proceed instead of self-terminating. The PR stays
      # open across ticks, so nothing terminates the engagement either.
      engagement(ws, 250)

      pr_stub(250, %{
        "number" => 250,
        "state" => "open",
        "head" => %{"sha" => "abc"},
        "html_url" => "x"
      })

      {_pid, name} = start_patrol(ws, interval_ms: 50)
      Process.sleep(250)

      assert ReviewPatrol.state(name).ticks >= 2,
             "expected at least 2 auto-ticks; got #{ReviewPatrol.state(name).ticks}"
    end
  end

  describe "tick/1 — idle backoff (bd-4brb2j)" do
    test "idle_ticks grows with no open engagements and resets once one appears", %{ws: ws} do
      # A stub must exist (even a no-op one) before start_patrol/1 calls
      # Req.Test.allow/3 — the allowance is keyed off an existing stub owner.
      stub(fn conn -> conn |> Plug.Conn.put_status(500) |> Req.Test.json(%{}) end)
      {_pid, name} = start_patrol(ws)

      :ok = ReviewPatrol.tick(name)
      assert ReviewPatrol.state(name).idle_ticks == 1

      :ok = ReviewPatrol.tick(name)
      :ok = ReviewPatrol.tick(name)
      assert ReviewPatrol.state(name).idle_ticks == 3

      eng = engagement(ws, 200)
      pr_stub(200, %{"number" => 200, "merged" => true, "html_url" => "x"})

      :ok = ReviewPatrol.tick(name)
      assert ReviewPatrol.state(name).idle_ticks == 0
      assert reload(eng).status == :closed
    end
  end

  describe "tick/1 — new-commit re-review (bd-f3fg22)" do
    # A prior finding we'd have posted on the first review, stored on the
    # engagement so the relevance gate + de-dupe have something to compare against.
    defp finding(file, line, message, severity \\ "error") do
      %{"file" => file, "line" => line, "message" => message, "severity" => severity}
    end

    # A single-hunk diff whose new-file side spans lines 1-20 (context lines
    # 1-19 + one added line at 20) — wide enough that any test finding at a
    # small line number lands inside the diff, so CodeReview's diff-scope
    # guard (bd-2n3qm6) doesn't demote it to the out-of-diff summary.
    defp wide_diff(file) do
      context = Enum.map_join(1..19, "\n", &" line#{&1}")

      "diff --git a/#{file} b/#{file}\n--- a/#{file}\n+++ b/#{file}\n" <>
        "@@ -1,19 +1,20 @@\n#{context}\n+added\n"
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

    # Like `rereview_stub/3`, but the PR carries a `reviews` list (used both by
    # `adapter.get/1`'s own approved/changes_requested calc and by
    # `self_approved?/1`'s identity-scoped lookup) and serves `GET /user` so
    # `self_approved?/1` can resolve the authenticated login (bd-4po0nv).
    defp rereview_stub_with_reviews(number, head, diff, reviews, our_login) do
      test_pid = self()

      stub(fn conn ->
        path = conn.request_path

        cond do
          conn.method == "GET" and path == "/user" ->
            conn |> Plug.Conn.put_status(200) |> Req.Test.json(%{"login" => our_login})

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
            conn |> Plug.Conn.put_status(200) |> Req.Test.json(reviews)

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

      diff = wide_diff("lib/a.ex")
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

      # bd-9rdwe4 (#1017 gap G5): a re-review never spawns through
      # Arbiter.Worker, so CodeReview.Checks persists the composed prompt
      # itself, keyed by the engagement id.
      assert {:ok, prompt} = Arbiter.Worker.PromptLog.read(eng.id)
      assert prompt =~ "BEGIN DIFF"
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

    test "sticky approval: operator identity currently approved + formatting-only push → declines, no re-review",
         %{ws: ws} do
      eng =
        engagement(ws, 420, %{
          review_automation: :auto,
          last_reviewed_sha: "oldsha",
          posted_findings: [finding("lib/a.ex", 5, "prior issue")]
        })

      # Whitespace-only change to the previously-flagged file: relevant?
      # (touches lib/a.ex) but not invalidating (formatting-only).
      diff =
        "diff --git a/lib/a.ex b/lib/a.ex\n--- a/lib/a.ex\n+++ b/lib/a.ex\n@@ -1 +1 @@\n" <>
          "-  def foo do\n+def foo do\n"

      reviews = [%{"user" => %{"login" => "botreviewer"}, "state" => "APPROVED"}]
      rereview_stub_with_reviews(420, "newsha", diff, reviews, "botreviewer")

      {_pid, name} = start_patrol(ws)
      assert :ok = ReviewPatrol.tick(name)

      assert_receive {:compare, _path}
      refute_receive {:inline_comment, _}
      refute_receive {:submit_review, _}

      reloaded = reload(eng)
      # Cursor advances (the push was considered and declined) but no review
      # was posted, and the decision is visible on the engagement.
      assert reloaded.last_reviewed_sha == "newsha"
      assert reloaded.review_count == 0
      assert reloaded.notes =~ "approval stands"
      assert ReviewPatrol.state(name).last_rereviewed == []
      assert ReviewPatrol.state(name).last_declined == [eng.id]
    end

    test "sticky approval: operator identity currently approved + substantive code push → still re-reviews",
         %{ws: ws} do
      eng =
        engagement(ws, 421, %{
          review_automation: :auto,
          last_reviewed_sha: "oldsha",
          posted_findings: [finding("lib/a.ex", 5, "prior issue")]
        })

      put_invoker([
        %{"severity" => "error", "file" => "lib/a.ex", "line" => 10, "message" => "new bug"}
      ])

      diff = wide_diff("lib/a.ex")
      reviews = [%{"user" => %{"login" => "botreviewer"}, "state" => "APPROVED"}]
      rereview_stub_with_reviews(421, "newsha", diff, reviews, "botreviewer")

      {_pid, name} = start_patrol(ws)
      assert :ok = ReviewPatrol.tick(name)

      assert_receive {:inline_comment, _}
      assert_receive {:submit_review, _}
      assert reload(eng).last_reviewed_sha == "newsha"
      assert ReviewPatrol.state(name).last_rereviewed == [eng.id]
      assert ReviewPatrol.state(name).last_declined == []
    end

    test "sticky approval: no current operator approval → substantive push re-reviews as before",
         %{ws: ws} do
      eng =
        engagement(ws, 422, %{
          review_automation: :auto,
          last_reviewed_sha: "oldsha",
          posted_findings: [finding("lib/a.ex", 5, "prior issue")]
        })

      put_invoker([
        %{"severity" => "error", "file" => "lib/a.ex", "line" => 10, "message" => "new bug"}
      ])

      diff = wide_diff("lib/a.ex")
      rereview_stub_with_reviews(422, "newsha", diff, [], "botreviewer")

      {_pid, name} = start_patrol(ws)
      assert :ok = ReviewPatrol.tick(name)

      assert_receive {:submit_review, _}
      assert ReviewPatrol.state(name).last_rereviewed == [eng.id]
    end

    test "sticky approval: operator approved + test-only push → declines, no re-review",
         %{ws: ws} do
      eng =
        engagement(ws, 423, %{
          review_automation: :auto,
          last_reviewed_sha: "oldsha",
          posted_findings: [finding("test/a_test.exs", 5, "prior issue")]
        })

      diff =
        "diff --git a/test/a_test.exs b/test/a_test.exs\n--- a/test/a_test.exs\n" <>
          "+++ b/test/a_test.exs\n@@ -1 +1,2 @@\n context\n+assert 1 == 1\n"

      reviews = [%{"user" => %{"login" => "botreviewer"}, "state" => "APPROVED"}]
      rereview_stub_with_reviews(423, "newsha", diff, reviews, "botreviewer")

      {_pid, name} = start_patrol(ws)
      assert :ok = ReviewPatrol.tick(name)

      refute_receive {:submit_review, _}
      assert reload(eng).last_reviewed_sha == "newsha"
      assert ReviewPatrol.state(name).last_declined == [eng.id]
    end

    test "sticky approval: operator approved + doc-only push → declines, no re-review",
         %{ws: ws} do
      eng =
        engagement(ws, 424, %{
          review_automation: :auto,
          last_reviewed_sha: "oldsha",
          posted_findings: [finding("docs/guide.md", 5, "prior issue")]
        })

      diff =
        "diff --git a/docs/guide.md b/docs/guide.md\n--- a/docs/guide.md\n" <>
          "+++ b/docs/guide.md\n@@ -1 +1,2 @@\n context\n+a whole new paragraph\n"

      reviews = [%{"user" => %{"login" => "botreviewer"}, "state" => "APPROVED"}]
      rereview_stub_with_reviews(424, "newsha", diff, reviews, "botreviewer")

      {_pid, name} = start_patrol(ws)
      assert :ok = ReviewPatrol.tick(name)

      refute_receive {:submit_review, _}
      assert reload(eng).last_reviewed_sha == "newsha"
      assert ReviewPatrol.state(name).last_declined == [eng.id]
    end

    test "sticky approval: self_approved?/1 unresolvable (no /user route) falls open — a formatting-only push still re-reviews",
         %{ws: ws} do
      _eng =
        engagement(ws, 425, %{
          review_automation: :auto,
          last_reviewed_sha: "oldsha",
          posted_findings: [finding("lib/a.ex", 5, "prior issue")]
        })

      diff =
        "diff --git a/lib/a.ex b/lib/a.ex\n--- a/lib/a.ex\n+++ b/lib/a.ex\n@@ -1 +1 @@\n" <>
          "-  def foo do\n+def foo do\n"

      # `rereview_stub/3` has no `/user` route and no APPROVED review, so
      # `self_approved?/1` degrades to false — sticky approval never applies,
      # and even a formatting-only push falls through to a normal re-review.
      put_invoker([
        %{"severity" => "error", "file" => "lib/a.ex", "line" => 10, "message" => "new bug"}
      ])

      rereview_stub(425, "newsha", diff)

      {_pid, name} = start_patrol(ws)
      assert :ok = ReviewPatrol.tick(name)

      assert_receive {:submit_review, _}
      assert ReviewPatrol.state(name).last_declined == []
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

      diff = wide_diff("lib/a.ex")
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

      diff = wide_diff("lib/a.ex")
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

      diff = wide_diff("lib/a.ex")
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

    test "off mode surfaces a flag instead of re-reviewing, same as flag (bd-7opdaf)", %{ws: ws} do
      eng =
        engagement(ws, 409, %{
          review_automation: :off,
          last_reviewed_sha: "oldsha",
          posted_findings: [finding("lib/a.ex", 5, "prior issue")]
        })

      diff = wide_diff("lib/a.ex")
      rereview_stub(409, "newsha", diff)

      {_pid, name} = start_patrol(ws)
      assert :ok = ReviewPatrol.tick(name)

      # No review posted — same hard-restriction behavior as :flag.
      refute_receive {:submit_review, _}
      assert reload(eng).last_reviewed_sha == "newsha"
      assert ReviewPatrol.state(name).last_flagged == [eng.id]

      flags =
        Arbiter.Messages.Message
        |> Ash.Query.filter(directive_ref == ^eng.id and kind == :flag)
        |> Ash.read!()

      assert length(flags) == 1
    end

    test "a live repo_override downgrade to :off overrides a grandfathered :auto engagement (bd-7opdaf)",
         %{ws: ws} do
      {:ok, ws} =
        Ash.update(ws, %{
          config:
            Map.put(ws.config, "review_automation", %{
              "default" => "auto",
              "repo_overrides" => %{"repo" => "off"}
            })
        })

      eng =
        engagement(ws, 410, %{
          review_automation: :auto,
          last_reviewed_sha: "oldsha",
          posted_findings: [finding("lib/a.ex", 5, "prior issue")]
        })

      diff = wide_diff("lib/a.ex")
      rereview_stub(410, "newsha", diff)

      {_pid, name} = start_patrol(ws)
      assert :ok = ReviewPatrol.tick(name)

      # A live :off downgrade is MORE restrictive than the grandfathered :auto —
      # it takes effect immediately, same as the existing report_only downgrade.
      refute_receive {:inline_comment, _}
      refute_receive {:submit_review, _}
      assert ReviewPatrol.state(name).last_flagged == [eng.id]
    end

    test "a live repo_override downgrade to report_only overrides a grandfathered :auto engagement (bd-3cpcw2)",
         %{ws: ws} do
      # The engagement was opened while the repo was `auto` (grandfathered), but
      # the workspace config now downgrades this repo to `report_only`.
      {:ok, ws} =
        Ash.update(ws, %{
          config:
            Map.put(ws.config, "review_automation", %{
              "default" => "auto",
              "repo_overrides" => %{"repo" => "report_only"}
            })
        })

      eng =
        engagement(ws, 406, %{
          review_automation: :auto,
          last_reviewed_sha: "oldsha",
          posted_findings: [finding("lib/a.ex", 5, "prior issue")]
        })

      put_invoker([
        %{"severity" => "error", "file" => "lib/a.ex", "line" => 10, "message" => "new bug"}
      ])

      diff = wide_diff("lib/a.ex")
      rereview_stub(406, "newsha", diff)

      {_pid, name} = start_patrol(ws)
      assert :ok = ReviewPatrol.tick(name)

      # The diff was read (relevance gate passed) …
      assert_receive {:compare, _path}
      # … but NOTHING was posted to the PR — the live repo_override wins over
      # the engagement's grandfathered :auto mode.
      refute_receive {:inline_comment, _}
      refute_receive {:submit_review, _}

      escalations =
        Arbiter.Messages.Message
        |> Ash.Query.filter(directive_ref == ^eng.id and to_ref == "coordinator")
        |> Ash.read!()

      assert Enum.any?(escalations, &(&1.subject =~ "Report-only re-review"))
      assert ReviewPatrol.state(name).last_reported == [eng.id]
      assert ReviewPatrol.state(name).last_rereviewed == []
    end

    test "a live repo_override of :auto does NOT widen a stored report_only engagement back to auto-posting (bd-3cpcw2)",
         %{ws: ws} do
      # The repo's live override is permissive (`auto`), but this engagement
      # was dispatched with an explicit hard `report_only` gate — e.g. a
      # sensitive PR the coordinator deliberately opted out of auto-posting.
      # The live override must never win in the *permissive* direction.
      {:ok, ws} =
        Ash.update(ws, %{
          config:
            Map.put(ws.config, "review_automation", %{
              "default" => "auto",
              "repo_overrides" => %{"repo" => "auto"}
            })
        })

      eng =
        engagement(ws, 407, %{
          review_automation: :report_only,
          last_reviewed_sha: "oldsha",
          posted_findings: [finding("lib/a.ex", 5, "prior issue")]
        })

      put_invoker([
        %{"severity" => "error", "file" => "lib/a.ex", "line" => 10, "message" => "new bug"}
      ])

      diff = wide_diff("lib/a.ex")
      rereview_stub(407, "newsha", diff)

      {_pid, name} = start_patrol(ws)
      assert :ok = ReviewPatrol.tick(name)

      assert_receive {:compare, _path}
      # Still nothing posted — the stored (more restrictive) mode wins.
      refute_receive {:inline_comment, _}
      refute_receive {:submit_review, _}

      escalations =
        Arbiter.Messages.Message
        |> Ash.Query.filter(directive_ref == ^eng.id and to_ref == "coordinator")
        |> Ash.read!()

      assert Enum.any?(escalations, &(&1.subject =~ "Report-only re-review"))
      assert ReviewPatrol.state(name).last_reported == [eng.id]
      assert ReviewPatrol.state(name).last_rereviewed == []
    end

    test "report_only mode re-reviews but posts NOTHING, reporting to the coordinator",
         %{ws: ws} do
      eng =
        engagement(ws, 405, %{
          review_automation: :report_only,
          last_reviewed_sha: "oldsha",
          posted_findings: [finding("lib/a.ex", 5, "prior issue")]
        })

      # The new commit surfaces a fresh finding in the previously-flagged file.
      put_invoker([
        %{"severity" => "error", "file" => "lib/a.ex", "line" => 10, "message" => "new bug"}
      ])

      diff = wide_diff("lib/a.ex")
      rereview_stub(405, "newsha", diff)

      {_pid, name} = start_patrol(ws)
      assert :ok = ReviewPatrol.tick(name)

      # The diff was read (relevance gate passed) …
      assert_receive {:compare, _path}
      # … but NOTHING was posted to the PR.
      refute_receive {:inline_comment, _}
      refute_receive {:submit_review, _}

      # The proposed comments were reported to the coordinator mailbox.
      escalations =
        Arbiter.Messages.Message
        |> Ash.Query.filter(directive_ref == ^eng.id and to_ref == "coordinator")
        |> Ash.read!()

      assert Enum.any?(escalations, fn m ->
               m.subject =~ "Report-only re-review" and m.body =~ "**ERROR**: new bug"
             end)

      reloaded = reload(eng)
      # SHA advanced + the reported finding tracked (so it isn't re-reported).
      assert reloaded.last_reviewed_sha == "newsha"
      assert length(reloaded.posted_findings) == 2
      assert ReviewPatrol.state(name).last_reported == [eng.id]
      assert ReviewPatrol.state(name).last_rereviewed == []
    end
  end

  describe "tick/1 — per-PR review cap (bd-ahvk03)" do
    test "review_count increments on each posted re-review", %{ws: ws} do
      eng =
        engagement(ws, 410, %{
          review_automation: :auto,
          last_reviewed_sha: "oldsha",
          posted_findings: [finding("lib/a.ex", 5, "prior issue")]
        })

      put_invoker([
        %{"severity" => "error", "file" => "lib/a.ex", "line" => 10, "message" => "new bug"}
      ])

      diff = wide_diff("lib/a.ex")
      rereview_stub(410, "newsha", diff)

      {_pid, name} = start_patrol(ws)
      assert :ok = ReviewPatrol.tick(name)

      assert_receive {:submit_review, _review}
      assert reload(eng).review_count == 1
    end

    test "at the cap, ReviewPatrol escalates once instead of re-reviewing", %{ws: ws} do
      eng =
        engagement(ws, 411, %{
          review_automation: :auto,
          last_reviewed_sha: "oldsha",
          posted_findings: [finding("lib/a.ex", 5, "prior issue")],
          review_count: 3
        })

      put_invoker([
        %{"severity" => "error", "file" => "lib/a.ex", "line" => 10, "message" => "new bug"}
      ])

      diff = wide_diff("lib/a.ex")
      rereview_stub(411, "newsha", diff)

      {_pid, name} = start_patrol(ws)
      assert :ok = ReviewPatrol.tick(name)

      # Capped: no diff fetch, no post, no advance — but exactly one escalation.
      refute_receive {:compare, _path}
      refute_receive {:inline_comment, _}
      refute_receive {:submit_review, _}

      reloaded = reload(eng)
      assert reloaded.last_reviewed_sha == "oldsha"
      assert reloaded.review_count == 3
      assert reloaded.review_cap_escalated == true
      assert ReviewPatrol.state(name).last_rereviewed == []
      assert ReviewPatrol.state(name).last_escalated == [eng.id]

      escalations =
        Arbiter.Messages.Message
        |> Ash.Query.filter(
          directive_ref == ^eng.id and to_ref == "coordinator" and kind == :escalation
        )
        |> Ash.read!()

      assert length(escalations) == 1
      assert hd(escalations).subject =~ "review cap"
    end

    test "past the cap and already escalated, subsequent ticks do nothing (no re-escalation)",
         %{ws: ws} do
      eng =
        engagement(ws, 412, %{
          review_automation: :auto,
          last_reviewed_sha: "oldsha",
          posted_findings: [finding("lib/a.ex", 5, "prior issue")],
          review_count: 5,
          review_cap_escalated: true
        })

      diff = wide_diff("lib/a.ex")
      rereview_stub(412, "newsha", diff)

      {_pid, name} = start_patrol(ws)
      assert :ok = ReviewPatrol.tick(name)
      assert :ok = ReviewPatrol.tick(name)

      refute_receive {:compare, _path}
      refute_receive {:submit_review, _}

      escalations =
        Arbiter.Messages.Message
        |> Ash.Query.filter(
          directive_ref == ^eng.id and to_ref == "coordinator" and kind == :escalation
        )
        |> Ash.read!()

      assert escalations == []
      assert ReviewPatrol.state(name).last_escalated == []
    end

    test "concurrent cap evaluations for the same engagement escalate exactly once (bd-4po0nv)",
         %{ws: ws} do
      eng =
        engagement(ws, 413, %{
          review_automation: :auto,
          last_reviewed_sha: "oldsha",
          posted_findings: [finding("lib/a.ex", 5, "prior issue")],
          review_count: 3
        })

      pr_stub(413, %{
        "number" => 413,
        "state" => "open",
        "head" => %{"sha" => "newsha"},
        "html_url" => "x"
      })

      # 7 independent patrol processes all evaluating the SAME engagement row
      # concurrently — reproducing the observed real-world burst (7 identical
      # escalations for one cap trip within ~3s) without relying on timing.
      patrols = for _ <- 1..7, do: start_patrol(ws)

      patrols
      |> Enum.map(fn {_pid, name} -> Task.async(fn -> ReviewPatrol.tick(name) end) end)
      |> Task.await_many()

      escalations =
        Arbiter.Messages.Message
        |> Ash.Query.filter(
          directive_ref == ^eng.id and to_ref == "coordinator" and kind == :escalation
        )
        |> Ash.read!()

      assert length(escalations) == 1
      assert reload(eng).review_cap_escalated == true
    end
  end

  describe "tick/1 — author-reply handling (bd-8fg64x)" do
    # A GraphQL review-thread node: id/path plus a list of {comment_id, author, body}.
    defp thread_node(id, path, comments) do
      %{
        "id" => id,
        "isResolved" => false,
        "path" => path,
        "line" => 1,
        "comments" => %{
          "nodes" =>
            Enum.map(comments, fn {cid, author, body} ->
              %{"databaseId" => cid, "body" => body, "author" => %{"login" => author}}
            end)
        }
      }
    end

    # Stub the author-reply conversation for an OPEN PR whose head has NOT moved
    # (so the tick takes the reply branch, not the re-review branch):
    #   adapter.get   → GET /pulls/:n (carries "user".login = pr_author) + /reviews
    #   thread reader → POST /graphql (returns `thread_nodes`)
    #   auto reply    → POST /pulls/:n/comments/:cid/replies (forwarded to test)
    # Any unexpected PR write (inline comment / verdict) hits the catch-all and
    # would surface as a failed assertion.
    defp reply_stub(number, head, pr_author, thread_nodes) do
      test_pid = self()

      stub(fn conn ->
        path = conn.request_path

        cond do
          conn.method == "POST" and path == "/graphql" ->
            conn
            |> Plug.Conn.put_status(200)
            |> Req.Test.json(%{
              "data" => %{
                "repository" => %{
                  "pullRequest" => %{"reviewThreads" => %{"nodes" => thread_nodes}}
                }
              }
            })

          conn.method == "GET" and path == "/repos/owner/repo/pulls/#{number}" ->
            conn
            |> Plug.Conn.put_status(200)
            |> Req.Test.json(%{
              "number" => number,
              "state" => "open",
              "head" => %{"sha" => head},
              "html_url" => "https://github.com/owner/repo/pull/#{number}",
              "user" => %{"login" => pr_author}
            })

          conn.method == "GET" and path == "/repos/owner/repo/pulls/#{number}/reviews" ->
            conn |> Plug.Conn.put_status(200) |> Req.Test.json([])

          conn.method == "POST" and
              Regex.match?(~r{^/repos/owner/repo/pulls/#{number}/comments/\d+/replies$}, path) ->
            {:ok, body, conn} = Plug.Conn.read_body(conn)
            send(test_pid, {:reply_posted, path, Jason.decode!(body)})
            conn |> Plug.Conn.put_status(201) |> Req.Test.json(%{"id" => 9001})

          conn.method == "POST" and path == "/repos/owner/repo/pulls/#{number}/comments" ->
            {:ok, body, conn} = Plug.Conn.read_body(conn)
            send(test_pid, {:inline_comment, Jason.decode!(body)})
            conn |> Plug.Conn.put_status(201) |> Req.Test.json(%{"id" => 1})

          conn.method == "POST" and path == "/repos/owner/repo/pulls/#{number}/reviews" ->
            {:ok, body, conn} = Plug.Conn.read_body(conn)
            send(test_pid, {:submit_review, Jason.decode!(body)})
            conn |> Plug.Conn.put_status(200) |> Req.Test.json(%{"id" => 99})

          true ->
            # check-runs (pipeline → nil = settled) and anything else.
            conn
            |> Plug.Conn.put_status(500)
            |> Req.Test.json(%{"message" => "unhandled #{path}"})
        end
      end)
    end

    # Bypass the real Claude CLI in the ReviewReply workflow.
    defp stub_reply_composer(body) do
      Application.put_env(:arbiter, :review_reply_composer, fn _ctx, _state -> {:ok, body} end)
      on_exit(fn -> Application.delete_env(:arbiter, :review_reply_composer) end)
    end

    test "auto: an author reply on our thread dispatches the reply workflow", %{ws: ws} do
      # Head unchanged (== last_reviewed_sha) → reply branch, not re-review.
      eng =
        engagement(ws, 500, %{
          review_automation: :auto,
          last_reviewed_sha: "samesha",
          last_seen_comment_id: "600"
        })

      stub_reply_composer("Thanks — that addresses my note.")

      # Our thread: we opened comment 600 (old); the PR author replied at 601 (new).
      nodes = [
        thread_node("RT1", "lib/a.ex", [
          {600, "botreviewer", "please rename this"},
          {601, "prauthor", "renamed it, does this work?"}
        ])
      ]

      reply_stub(500, "samesha", "prauthor", nodes)

      {_pid, name} = start_patrol(ws)
      assert :ok = ReviewPatrol.tick(name)

      # A threaded reply was posted to the author's comment; no verdict/inline.
      assert_receive {:reply_posted, path, body}
      assert path == "/repos/owner/repo/pulls/500/comments/601/replies"
      assert body["body"] == "Thanks — that addresses my note."
      refute_receive {:submit_review, _}

      # Cursor advanced past the handled reply; bookkeeping recorded the reply.
      assert reload(eng).last_seen_comment_id == "601"
      assert ReviewPatrol.state(name).last_replied == [eng.id]
    end

    test "flag: an author reply raises ONE coordinator escalation and posts nothing", %{ws: ws} do
      eng =
        engagement(ws, 501, %{
          review_automation: :flag,
          last_reviewed_sha: "samesha",
          last_seen_comment_id: "700"
        })

      nodes = [
        thread_node("RT1", "lib/b.ex", [
          {700, "botreviewer", "consider extracting this"},
          {701, "prauthor", "why? seems fine to me"}
        ])
      ]

      reply_stub(501, "samesha", "prauthor", nodes)

      {_pid, name} = start_patrol(ws)
      assert :ok = ReviewPatrol.tick(name)

      # NOTHING posted to the PR.
      refute_receive {:reply_posted, _, _}
      refute_receive {:inline_comment, _}
      refute_receive {:submit_review, _}

      # Exactly one addressed escalation to the coordinator.
      escalations =
        Arbiter.Messages.Message
        |> Ash.Query.filter(directive_ref == ^eng.id and kind == :escalation)
        |> Ash.read!()

      assert length(escalations) == 1
      [esc] = escalations
      assert esc.to_ref == "coordinator"
      assert esc.body =~ "prauthor"
      assert esc.body =~ "why? seems fine to me"

      # Cursor advanced so the same reply is not re-escalated.
      assert reload(eng).last_seen_comment_id == "701"
      assert ReviewPatrol.state(name).last_escalated == [eng.id]
    end

    test "flag: re-ticking does NOT re-escalate the same reply (cursor idempotency)", %{ws: ws} do
      eng =
        engagement(ws, 502, %{
          review_automation: :flag,
          last_reviewed_sha: "samesha",
          last_seen_comment_id: "800"
        })

      nodes = [
        thread_node("RT1", "lib/c.ex", [
          {800, "botreviewer", "nit"},
          {801, "prauthor", "fixed"}
        ])
      ]

      reply_stub(502, "samesha", "prauthor", nodes)

      {_pid, name} = start_patrol(ws)

      assert :ok = ReviewPatrol.tick(name)
      assert reload(eng).last_seen_comment_id == "801"

      # Second tick: the reply (801) is no longer newer than the cursor (801).
      assert :ok = ReviewPatrol.tick(name)
      assert reload(eng).last_seen_comment_id == "801"
      assert ReviewPatrol.state(name).last_escalated == []

      escalations =
        Arbiter.Messages.Message
        |> Ash.Query.filter(directive_ref == ^eng.id and kind == :escalation)
        |> Ash.read!()

      assert length(escalations) == 1
    end

    test "another reviewer's comment on our thread is ignored", %{ws: ws} do
      eng =
        engagement(ws, 503, %{
          review_automation: :auto,
          last_reviewed_sha: "samesha",
          last_seen_comment_id: "900"
        })

      stub_reply_composer("should not be sent")

      # New comments 901 (other reviewer) — but NO author reply. 900 is ours (old).
      nodes = [
        thread_node("RT1", "lib/d.ex", [
          {900, "botreviewer", "our opening note"},
          {901, "copilot", "another reviewer chiming in"}
        ])
      ]

      reply_stub(503, "samesha", "prauthor", nodes)

      {_pid, name} = start_patrol(ws)
      assert :ok = ReviewPatrol.tick(name)

      # No reply dispatched — the only new comment is from another reviewer.
      refute_receive {:reply_posted, _, _}
      # Cursor untouched: nothing of ours was handled.
      assert reload(eng).last_seen_comment_id == "900"
      assert ReviewPatrol.state(name).last_replied == []
    end

    test "a reply on a thread we do NOT own is ignored", %{ws: ws} do
      eng =
        engagement(ws, 504, %{
          review_automation: :auto,
          last_reviewed_sha: "samesha",
          last_seen_comment_id: "1000"
        })

      stub_reply_composer("should not be sent")

      # A thread opened and carried entirely by another reviewer — we never
      # participated, so the author's reply there is not our concern.
      nodes = [
        thread_node("RT_other", "lib/e.ex", [
          {1001, "copilot", "other reviewer's thread"},
          {1002, "prauthor", "author replying to the other reviewer"}
        ])
      ]

      reply_stub(504, "samesha", "prauthor", nodes)

      {_pid, name} = start_patrol(ws)
      assert :ok = ReviewPatrol.tick(name)

      refute_receive {:reply_posted, _, _}
      assert reload(eng).last_seen_comment_id == "1000"
      assert ReviewPatrol.state(name).last_replied == []
    end

    test "no author-reply handling when our_login is unconfigured", %{ws: _ws} do
      {:ok, ws_no_login} =
        Ash.create(Workspace, %{
          name: "rp-nologin-#{System.unique_integer([:positive])}",
          prefix: "rn#{System.unique_integer([:positive])}",
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

      eng =
        engagement(ws_no_login, 505, %{
          review_automation: :auto,
          last_reviewed_sha: "samesha",
          last_seen_comment_id: "1100"
        })

      stub_reply_composer("should not be sent")

      nodes = [
        thread_node("RT1", "lib/f.ex", [
          {1100, "botreviewer", "note"},
          {1101, "prauthor", "reply"}
        ])
      ]

      reply_stub(505, "samesha", "prauthor", nodes)

      {_pid, name} = start_patrol(ws_no_login)
      assert :ok = ReviewPatrol.tick(name)

      # Without our_login we cannot identify our threads → conservatively skip.
      refute_receive {:reply_posted, _, _}
      assert reload(eng).last_seen_comment_id == "1100"
    end

    test "a code-change push defers to the re-review path (no in-thread reply)", %{ws: ws} do
      # Head ADVANCED (oldsha → newsha): the tick takes the re-review branch and
      # never reaches author-reply handling, even though an author reply exists.
      eng =
        engagement(ws, 506, %{
          review_automation: :auto,
          last_reviewed_sha: "oldsha",
          last_seen_comment_id: "1200",
          posted_findings: [finding("lib/g.ex", 5, "prior issue")]
        })

      stub_reply_composer("should not be sent as a reply")

      # The re-review's new diff touches a previously-flagged file → re-review fires.
      put_invoker([
        %{"severity" => "error", "file" => "lib/g.ex", "line" => 9, "message" => "new bug"}
      ])

      diff = wide_diff("lib/g.ex")

      test_pid = self()

      stub(fn conn ->
        path = conn.request_path

        cond do
          conn.method == "GET" and String.starts_with?(path, "/repos/owner/repo/compare/") ->
            conn
            |> Plug.Conn.put_resp_header("content-type", "text/plain")
            |> Plug.Conn.resp(200, diff)

          conn.method == "GET" and path == "/repos/owner/repo/pulls/506" ->
            conn
            |> Plug.Conn.put_status(200)
            |> Req.Test.json(%{
              "number" => 506,
              "state" => "open",
              "head" => %{"sha" => "newsha"},
              "html_url" => "x",
              "user" => %{"login" => "prauthor"}
            })

          conn.method == "GET" and path == "/repos/owner/repo/pulls/506/reviews" ->
            conn |> Plug.Conn.put_status(200) |> Req.Test.json([])

          conn.method == "POST" and
              Regex.match?(~r{/comments/\d+/replies$}, path) ->
            send(test_pid, {:reply_posted, path})
            conn |> Plug.Conn.put_status(201) |> Req.Test.json(%{"id" => 1})

          conn.method == "POST" and path == "/repos/owner/repo/pulls/506/comments" ->
            send(test_pid, {:inline_comment, :posted})
            conn |> Plug.Conn.put_status(201) |> Req.Test.json(%{"id" => 1})

          conn.method == "POST" and path == "/repos/owner/repo/pulls/506/reviews" ->
            send(test_pid, {:submit_review, :posted})
            conn |> Plug.Conn.put_status(200) |> Req.Test.json(%{"id" => 99})

          true ->
            conn
            |> Plug.Conn.put_status(500)
            |> Req.Test.json(%{"message" => "unhandled #{path}"})
        end
      end)

      {_pid, name} = start_patrol(ws)
      assert :ok = ReviewPatrol.tick(name)

      # Re-review path ran (inline comment + verdict); NO in-thread reply, and the
      # comment cursor is untouched (the reply is deferred to a later tick).
      assert_receive {:submit_review, _}
      refute_receive {:reply_posted, _}
      assert reload(eng).last_seen_comment_id == "1200"
      assert reload(eng).last_reviewed_sha == "newsha"
      assert ReviewPatrol.state(name).last_rereviewed == [eng.id]
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

  describe "tick/1 — pacing GitHub calls across engagements (bd-1yva53)" do
    # A tick with many open engagements must not fire a burst of unthrottled
    # `get()` calls — that's what trips GitHub's secondary (abuse) rate limit.
    # Assert the pacing hook fires once per engagement after the first.
    test "pace hook fires between engagements, not before the first", %{ws: ws} do
      test_pid = self()

      Application.put_env(:arbiter, :review_patrol_pace_sleep_fun, fn ms ->
        send(test_pid, {:paced, ms})
      end)

      on_exit(fn -> Application.delete_env(:arbiter, :review_patrol_pace_sleep_fun) end)

      engs = for n <- [700, 701, 702], do: engagement(ws, n)

      stub(fn conn ->
        cond do
          Enum.any?(engs, &(conn.request_path == "/repos/owner/repo/pulls/#{&1.source_pr}")) ->
            conn
            |> Plug.Conn.put_status(200)
            |> Req.Test.json(%{"merged" => true, "html_url" => "x"})

          Enum.any?(
            engs,
            &(conn.request_path == "/repos/owner/repo/pulls/#{&1.source_pr}/reviews")
          ) ->
            conn |> Plug.Conn.put_status(200) |> Req.Test.json([])

          true ->
            conn |> Plug.Conn.put_status(500) |> Req.Test.json(%{})
        end
      end)

      {_pid, name} = start_patrol(ws)
      assert :ok = ReviewPatrol.tick(name)

      # 3 engagements → 2 pace delays (none before the first).
      assert_receive {:paced, _}
      assert_receive {:paced, _}
      refute_receive {:paced, _}

      assert length(ReviewPatrol.state(name).last_terminated) == 3
    end

    test "a single-engagement tick never pays a pace delay", %{ws: ws} do
      test_pid = self()

      Application.put_env(:arbiter, :review_patrol_pace_sleep_fun, fn ms ->
        send(test_pid, {:paced, ms})
      end)

      on_exit(fn -> Application.delete_env(:arbiter, :review_patrol_pace_sleep_fun) end)

      eng = engagement(ws, 703)
      pr_stub(703, %{"number" => 703, "merged" => true, "html_url" => "x"})

      {_pid, name} = start_patrol(ws)
      assert :ok = ReviewPatrol.tick(name)

      refute_receive {:paced, _}
      assert reload(eng).status == :closed
    end
  end

  describe "tick/1 — rate-limit circuit breaker (bd-1m8k7d)" do
    setup do
      # Never actually sleep for the pace delay, nor for GitHub's own
      # in-request secondary-limit retry (bd-1yva53) — a Retry-After header
      # trips both, and this suite is only exercising ReviewPatrol's
      # workspace-level circuit breaker.
      Application.put_env(:arbiter, :review_patrol_pace_sleep_fun, fn _ms -> :ok end)
      Application.put_env(:arbiter, :github_retry_sleep_fun, fn _ms -> :ok end)

      on_exit(fn ->
        Application.delete_env(:arbiter, :review_patrol_pace_sleep_fun)
        Application.delete_env(:arbiter, :github_retry_sleep_fun)
      end)

      :ok
    end

    defp count_calls(fun) do
      counter = :counters.new(1, [])

      stub(fn conn ->
        :counters.add(counter, 1, 1)
        fun.(conn)
      end)

      counter
    end

    defp rate_limited_403(conn, opts \\ []) do
      conn =
        Enum.reduce(Keyword.get(opts, :headers, []), conn, fn {k, v}, conn ->
          Plug.Conn.put_resp_header(conn, k, v)
        end)

      message = Keyword.get(opts, :message, "API rate limit exceeded for user ID 12345.")

      conn |> Plug.Conn.put_status(403) |> Req.Test.json(%{"message" => message})
    end

    test "sustained 403s trip the circuit after N consecutive hits — total calls stay bounded, not linear in open-engagement count",
         %{ws: ws} do
      engs = for n <- 900..919, do: engagement(ws, n)
      counter = count_calls(&rate_limited_403/1)

      {_pid, name} = start_patrol(ws)
      assert :ok = ReviewPatrol.tick(name)

      # Default trip threshold is 3 — regardless of 20 open engagements, only
      # 3 `get/1` calls should have fired before the circuit broke.
      assert :counters.get(counter, 1) == 3
      assert length(engs) == 20

      assert ReviewPatrol.state(name).last_terminated == []
      assert %DateTime{} = ReviewPatrol.state(name).rate_limit_paused_until
    end

    test "while paused, subsequent ticks make ZERO forge calls", %{ws: ws} do
      for n <- 920..929, do: engagement(ws, n)
      counter = count_calls(&rate_limited_403/1)

      {_pid, name} = start_patrol(ws)
      assert :ok = ReviewPatrol.tick(name)
      assert :counters.get(counter, 1) == 3

      assert :ok = ReviewPatrol.tick(name)
      assert :ok = ReviewPatrol.tick(name)
      # No further calls while the circuit is open.
      assert :counters.get(counter, 1) == 3
    end

    test "exactly one coordinator escalation is raised per trip, not one per tick while paused",
         %{ws: ws} do
      for n <- 930..939, do: engagement(ws, n)
      _counter = count_calls(&rate_limited_403/1)

      {_pid, name} = start_patrol(ws)
      assert :ok = ReviewPatrol.tick(name)
      assert :ok = ReviewPatrol.tick(name)
      assert :ok = ReviewPatrol.tick(name)

      escalations =
        Arbiter.Messages.Message.coordinator_ref()
        |> Arbiter.Messages.Message.inbox(workspace_id: ws.id)
        |> Enum.filter(&(&1.subject == "ReviewPatrol paused — forge rate limit"))

      assert length(escalations) == 1
    end

    test "polling resumes once the pause window elapses", %{ws: ws} do
      clock_offset = :counters.new(1, [])

      Application.put_env(:arbiter, :review_patrol_clock_fun, fn ->
        DateTime.add(DateTime.utc_now(), :counters.get(clock_offset, 1), :second)
      end)

      on_exit(fn -> Application.delete_env(:arbiter, :review_patrol_clock_fun) end)

      # 3 engagements — enough to hit the default trip threshold in one tick.
      engs = for n <- [940, 941, 942], do: engagement(ws, n)
      rate_limited = count_calls(&rate_limited_403/1)

      {_pid, name} = start_patrol(ws)
      assert :ok = ReviewPatrol.tick(name)
      assert :counters.get(rate_limited, 1) == 3
      assert %DateTime{} = ReviewPatrol.state(name).rate_limit_paused_until

      # Still within the pause window: no new calls at all.
      assert :ok = ReviewPatrol.tick(name)
      assert :counters.get(rate_limited, 1) == 3

      # Fast-forward the virtual clock well past the (no-Retry-After) default
      # backoff window, then let the forge succeed.
      :counters.put(clock_offset, 1, 3600)

      stub(fn conn ->
        cond do
          Enum.any?(engs, &(conn.request_path == "/repos/owner/repo/pulls/#{&1.source_pr}")) ->
            conn
            |> Plug.Conn.put_status(200)
            |> Req.Test.json(%{"merged" => true, "html_url" => "x"})

          Enum.any?(
            engs,
            &(conn.request_path == "/repos/owner/repo/pulls/#{&1.source_pr}/reviews")
          ) ->
            conn |> Plug.Conn.put_status(200) |> Req.Test.json([])

          true ->
            conn |> Plug.Conn.put_status(500) |> Req.Test.json(%{})
        end
      end)

      assert :ok = ReviewPatrol.tick(name)
      assert Enum.all?(engs, &(reload(&1).status == :closed))
      assert ReviewPatrol.state(name).rate_limit_paused_until == nil
    end

    test "a 429 also trips the circuit", %{ws: ws} do
      for n <- 950..959, do: engagement(ws, n)

      counter =
        count_calls(fn conn ->
          conn |> Plug.Conn.put_status(429) |> Req.Test.json(%{"message" => "Too Many Requests"})
        end)

      {_pid, name} = start_patrol(ws)
      assert :ok = ReviewPatrol.tick(name)

      assert :counters.get(counter, 1) == 3
      assert %DateTime{} = ReviewPatrol.state(name).rate_limit_paused_until
    end

    test "honors a Retry-After header instead of guessing a backoff", %{ws: ws} do
      for n <- 960..969, do: engagement(ws, n)

      count_calls(fn conn -> rate_limited_403(conn, headers: [{"retry-after", "5"}]) end)

      {_pid, name} = start_patrol(ws)
      before = DateTime.utc_now()
      assert :ok = ReviewPatrol.tick(name)

      paused_until = ReviewPatrol.state(name).rate_limit_paused_until
      # Honoring Retry-After: 5 means the pause is ~5s out, not the (much
      # longer) default exponential backoff.
      assert DateTime.diff(paused_until, before, :millisecond) in 4_000..7_000
    end

    test "a non-rate-limit error (e.g. a plain 500) never trips the circuit", %{ws: ws} do
      for n <- 970..979, do: engagement(ws, n)

      counter =
        count_calls(fn conn -> conn |> Plug.Conn.put_status(500) |> Req.Test.json(%{}) end)

      {_pid, name} = start_patrol(ws)
      assert :ok = ReviewPatrol.tick(name)

      # Every engagement was attempted — a 500 isn't a rate limit, so the
      # circuit breaker never engages.
      assert :counters.get(counter, 1) == 10
      assert ReviewPatrol.state(name).rate_limit_paused_until == nil
    end
  end

  # ---- lazy-start lifecycle (bd-7tr11p) ----

  # Start a ReviewPatrol directly (not under start_supervised), so a
  # self-initiated :normal stop is observable via a monitor without the ExUnit
  # supervisor's restart interfering.
  defp start_unsupervised(ws, repo) do
    name = String.to_atom("ReviewPatrol_lazy_#{System.unique_integer([:positive])}")

    {:ok, pid} =
      ReviewPatrol.start_link(
        repo: repo,
        workspace_id: ws.id,
        interval_ms: 60_000,
        name: name
      )

    Req.Test.allow(@stub_name, self(), pid)
    on_exit(fn -> if Process.alive?(pid), do: GenServer.stop(pid, :normal, 5_000) end)
    {pid, name}
  end

  describe "has_open_engagement?/2 — lazy-start DB gate (bd-7tr11p)" do
    test "true for a repo with an open engagement (bare source_pr)", %{ws: ws} do
      engagement(ws, 300)
      assert ReviewPatrol.has_open_engagement?(ws.id, "owner/repo")
    end

    test "false with no engagement", %{ws: ws} do
      refute ReviewPatrol.has_open_engagement?(ws.id, "owner/repo")
    end

    test "false once the only engagement is closed", %{ws: ws} do
      eng = engagement(ws, 300)
      {:ok, _} = Ash.update(eng, %{}, action: :close)
      refute ReviewPatrol.has_open_engagement?(ws.id, "owner/repo")
    end

    test "a qualified source_pr scopes the engagement to its own repo", %{ws: ws} do
      engagement(ws, "octo/alpha#1")
      assert ReviewPatrol.has_open_engagement?(ws.id, "octo/alpha")
      refute ReviewPatrol.has_open_engagement?(ws.id, "octo/beta")
    end
  end

  describe "scheduled tick self-termination (bd-7tr11p)" do
    test "a scheduled tick makes zero forge calls and stops with no engagement watched",
         %{ws: ws} do
      test_pid = self()

      stub(fn conn ->
        send(test_pid, {:github_called, conn.request_path})
        conn |> Plug.Conn.put_status(200) |> Req.Test.json(%{})
      end)

      {pid, _name} = start_unsupervised(ws, "owner/repo")
      ref = Process.monitor(pid)

      send(pid, :tick)

      assert_receive {:DOWN, ^ref, :process, ^pid, :normal}, 2_000
      refute_receive {:github_called, _}, 100
    end

    test "a scheduled tick proceeds (and the patrol survives) with an open engagement",
         %{ws: ws} do
      engagement(ws, 300)

      pr_stub(300, %{
        "number" => 300,
        "state" => "open",
        "head" => %{"sha" => "abc"},
        "html_url" => "x"
      })

      {pid, name} = start_unsupervised(ws, "owner/repo")

      send(pid, :tick)
      _ = ReviewPatrol.state(name)

      assert Process.alive?(pid)
      assert ReviewPatrol.state(name).ticks >= 1
    end
  end

  describe ":recheck (prompt stop on last-item close, bd-7tr11p)" do
    test ":recheck stops the patrol when its last engagement has closed", %{ws: ws} do
      eng = engagement(ws, 300)
      {pid, _name} = start_unsupervised(ws, "owner/repo")
      ref = Process.monitor(pid)

      {:ok, _} = Ash.update(eng, %{}, action: :close)
      send(pid, :recheck)

      assert_receive {:DOWN, ^ref, :process, ^pid, :normal}, 2_000
    end

    test ":recheck keeps the patrol alive while an engagement remains", %{ws: ws} do
      engagement(ws, 300)
      {pid, name} = start_unsupervised(ws, "owner/repo")

      send(pid, :recheck)
      _ = ReviewPatrol.state(name)
      assert Process.alive?(pid)
    end
  end

  describe "repo-scoped engagement set (bd-7tr11p)" do
    test "an engagement whose PR is in a different repo does not keep this patrol alive",
         %{ws: ws} do
      # This patrol watches owner/other; the only engagement's PR is in octo/alpha
      # (qualified source_pr). It must not count as watched work for owner/other.
      engagement(ws, "octo/alpha#1")

      {pid, _name} = start_unsupervised(ws, "owner/other")
      ref = Process.monitor(pid)

      send(pid, :tick)

      assert_receive {:DOWN, ^ref, :process, ^pid, :normal}, 2_000
    end
  end

  describe "child_spec restart policy (bd-7tr11p)" do
    test "is :transient so a :normal self-stop is not restarted" do
      assert ReviewPatrol.child_spec([]).restart == :transient
    end
  end
end
