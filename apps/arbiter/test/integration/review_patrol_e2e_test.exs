defmodule Arbiter.Integration.ReviewPatrolE2ETest do
  @moduledoc """
  End-to-end tests for the ReviewPatrol lifecycle (bd-bdb1ix).

  These tests drive multiple ticks in sequence to prove the full
  reviewer-side lifecycle, in contrast to the unit tests in
  `Arbiter.Workflows.ReviewPatrolTest` which isolate individual tick
  behaviours.

  Scenarios covered:
    1. Colleague-ticket no-mutation — full lifecycle (SHA record → re-review →
       author-reply → merge-terminate) against a Jira-tracked engagement makes
       ZERO tracker writes (review_only guard, bd-6xaaam).
    2. Multi-reviewer isolation — ReviewPatrol acts only on threads we opened;
       another reviewer's CHANGES_REQUESTED thread and its author replies are
       completely ignored.
    3. Merge-terminate idempotency — the engagement closes exactly once on
       merge; subsequent ticks are no-ops.
    4. Auto vs flag paths end-to-end — the full lifecycle exercised under both
       `:auto` and `:flag` automation modes.
  """

  use Arbiter.DataCase, async: false

  alias Arbiter.Tasks.{Issue, Workspace}
  alias Arbiter.Workflows.ReviewPatrol
  require Ash.Query

  # GitHub merger HTTP plug used by the PR adapter.
  @merger_stub Arbiter.Mergers.Github.HTTP
  # Jira tracker HTTP plug — any call here is a bug for review_only tasks.
  @jira_stub Arbiter.Trackers.Jira.HTTP

  # ── setup ──────────────────────────────────────────────────────────────────

  setup do
    {:ok, ws} =
      Ash.create(Workspace, %{
        name: "rp-e2e-#{System.unique_integer([:positive])}",
        prefix: "e2e",
        config: %{
          "merge" => %{
            "strategy" => "github",
            "config" => %{
              "owner" => "owner",
              "repo" => "repo",
              "credentials_ref" => "env:GITHUB_TOKEN"
            }
          },
          "review_patrol" => %{"our_login" => "botreviewer"}
        }
      })

    prior_gh = System.get_env("GITHUB_TOKEN")
    System.put_env("GITHUB_TOKEN", "test-token-e2e")

    on_exit(fn ->
      if prior_gh,
        do: System.put_env("GITHUB_TOKEN", prior_gh),
        else: System.delete_env("GITHUB_TOKEN")
    end)

    {:ok, ws: ws}
  end

  # ── helpers ────────────────────────────────────────────────────────────────

  defp stub_merger(fun), do: Req.Test.stub(@merger_stub, fun)

  defp start_patrol(ws, opts \\ []) do
    name = String.to_atom("RPE2E_#{System.unique_integer([:positive])}")

    pid =
      start_supervised!(
        {ReviewPatrol,
         Keyword.merge(
           [repo: "owner/repo", workspace_id: ws.id, interval_ms: 60_000, name: name],
           opts
         )}
      )

    Req.Test.allow(@merger_stub, self(), pid)
    {pid, name}
  end

  # Create a review engagement.  `tracker_type` and `tracker_ref` are split to
  # the create action; everything else lands in the subsequent :update (mirrors
  # how dispatch.ex marks a task as review-only).
  defp engagement(ws, source_pr, attrs) do
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

  defp reload(task), do: Ash.get!(Issue, task.id)

  defp finding(file, line, message, severity \\ "error"),
    do: %{"file" => file, "line" => line, "message" => message, "severity" => severity}

  defp put_invoker(findings) do
    json = Jason.encode!(%{"findings" => findings})
    Application.put_env(:arbiter, :code_review_invoker, fn _prompt, _state -> {:ok, json} end)
    on_exit(fn -> Application.delete_env(:arbiter, :code_review_invoker) end)
  end

  defp put_reply_composer(body) do
    Application.put_env(:arbiter, :review_reply_composer, fn _ctx, _state -> {:ok, body} end)
    on_exit(fn -> Application.delete_env(:arbiter, :review_reply_composer) end)
  end

  # Minimal GraphQL thread node.
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

  # ── Test 1: Colleague-ticket no-mutation across the full lifecycle ─────────

  describe "full lifecycle — zero Jira tracker writes (bd-6xaaam)" do
    setup do
      env = "JIRA_TOKEN_E2E"
      System.put_env(env, "test-jira-token")
      on_exit(fn -> System.delete_env(env) end)

      {:ok, jira_ws} =
        Ash.create(Workspace, %{
          name: "rp-jira-e2e-#{System.unique_integer([:positive])}",
          prefix: "jwa",
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
              "type" => "jira",
              "config" => %{
                "url" => "https://jira.example.com",
                "credentials_ref" => "env:#{env}"
              }
            },
            "review_patrol" => %{"our_login" => "botreviewer"}
          }
        })

      {:ok, jira_ws: jira_ws}
    end

    test "initial review → re-review → author-reply → merge: ZERO Jira HTTP calls",
         %{jira_ws: jira_ws} do
      # Any Jira HTTP call is a bug; forward each to the test process to surface
      # it as a failed refute_receive assertion.
      test_pid = self()

      Req.Test.stub(@jira_stub, fn conn ->
        send(test_pid, {:jira_http, conn.method, conn.request_path})
        conn |> Plug.Conn.put_status(200) |> Req.Test.json(%{})
      end)

      # Engagement: Jira-tracked (col-999) but review_only — never owned by us.
      eng =
        engagement(jira_ws, 600, %{
          tracker_type: :jira,
          tracker_ref: "COL-999",
          posted_findings: []
        })

      put_invoker([finding("lib/auth.ex", 42, "SQL injection risk")])
      put_reply_composer("Good point, fixed in latest commit.")

      # ── Tick 1: open PR, no prior SHA → SHA recorded ──────────────────────
      # Req.Test.allow requires the stub to exist at call time, so we must install
      # the merger stub BEFORE start_patrol (which calls allow internally).
      stub_merger(fn conn ->
        cond do
          conn.method == "GET" and conn.request_path == "/repos/owner/repo/pulls/600" ->
            Req.Test.json(conn, %{
              "number" => 600,
              "state" => "open",
              "head" => %{"sha" => "sha1"},
              "html_url" => "https://github.com/owner/repo/pull/600",
              "user" => %{"login" => "colleague"}
            })

          conn.method == "GET" and conn.request_path == "/repos/owner/repo/pulls/600/reviews" ->
            Req.Test.json(conn, [])

          true ->
            conn |> Plug.Conn.put_status(500) |> Req.Test.json(%{})
        end
      end)

      {pid, name} = start_patrol(jira_ws)
      Req.Test.allow(@jira_stub, self(), pid)

      assert :ok = ReviewPatrol.tick(name)
      assert reload(eng).last_reviewed_sha == "sha1"
      assert ReviewPatrol.state(name).last_terminated == []

      # ── Tick 2: head advanced → re-review (auto mode) ────────────────────
      {:ok, eng} =
        Ash.update(
          reload(eng),
          %{review_automation: :auto, posted_findings: [finding("lib/auth.ex", 5, "prior")]},
          action: :update
        )

      diff =
        "diff --git a/lib/auth.ex b/lib/auth.ex\n--- a/lib/auth.ex\n+++ b/lib/auth.ex\n@@ -40,3 +40,4 @@\n+y\n"

      stub_merger(fn conn ->
        cond do
          conn.method == "GET" and conn.request_path == "/repos/owner/repo/pulls/600" ->
            Req.Test.json(conn, %{
              "number" => 600,
              "state" => "open",
              "head" => %{"sha" => "sha2"},
              "html_url" => "https://github.com/owner/repo/pull/600",
              "user" => %{"login" => "colleague"}
            })

          conn.method == "GET" and conn.request_path == "/repos/owner/repo/pulls/600/reviews" ->
            Req.Test.json(conn, [])

          conn.method == "GET" and
              String.starts_with?(conn.request_path, "/repos/owner/repo/compare/") ->
            conn
            |> Plug.Conn.put_resp_header("content-type", "text/plain")
            |> Plug.Conn.resp(200, diff)

          conn.method == "POST" and conn.request_path == "/repos/owner/repo/pulls/600/comments" ->
            conn |> Plug.Conn.put_status(201) |> Req.Test.json(%{"id" => 10})

          conn.method == "POST" and conn.request_path == "/repos/owner/repo/pulls/600/reviews" ->
            conn |> Plug.Conn.put_status(200) |> Req.Test.json(%{"id" => 99})

          true ->
            conn |> Plug.Conn.put_status(500) |> Req.Test.json(%{})
        end
      end)

      assert :ok = ReviewPatrol.tick(name)
      assert reload(eng).last_reviewed_sha == "sha2"
      assert ReviewPatrol.state(name).last_rereviewed == [eng.id]

      # ── Tick 3: head unchanged, author replied → reply dispatched ─────────
      nodes = [
        thread_node("RT1", "lib/auth.ex", [
          {200, "botreviewer", "SQL injection risk on line 42"},
          {201, "colleague", "hmm, does this apply here?"}
        ])
      ]

      stub_merger(fn conn ->
        cond do
          conn.method == "GET" and conn.request_path == "/repos/owner/repo/pulls/600" ->
            Req.Test.json(conn, %{
              "number" => 600,
              "state" => "open",
              "head" => %{"sha" => "sha2"},
              "html_url" => "https://github.com/owner/repo/pull/600",
              "user" => %{"login" => "colleague"}
            })

          conn.method == "GET" and conn.request_path == "/repos/owner/repo/pulls/600/reviews" ->
            Req.Test.json(conn, [])

          conn.method == "POST" and conn.request_path == "/graphql" ->
            Req.Test.json(conn, %{
              "data" => %{
                "repository" => %{
                  "pullRequest" => %{"reviewThreads" => %{"nodes" => nodes}}
                }
              }
            })

          conn.method == "POST" and
              Regex.match?(~r{/pulls/600/comments/\d+/replies$}, conn.request_path) ->
            conn |> Plug.Conn.put_status(201) |> Req.Test.json(%{"id" => 9001})

          true ->
            conn |> Plug.Conn.put_status(500) |> Req.Test.json(%{})
        end
      end)

      assert :ok = ReviewPatrol.tick(name)
      assert reload(eng).last_seen_comment_id == "201"
      assert ReviewPatrol.state(name).last_replied == [eng.id]

      # ── Tick 4: PR merged → engagement closed ────────────────────────────
      stub_merger(fn conn ->
        cond do
          conn.method == "GET" and conn.request_path == "/repos/owner/repo/pulls/600" ->
            Req.Test.json(conn, %{
              "number" => 600,
              "merged" => true,
              "html_url" => "https://github.com/owner/repo/pull/600"
            })

          conn.method == "GET" and conn.request_path == "/repos/owner/repo/pulls/600/reviews" ->
            Req.Test.json(conn, [])

          true ->
            conn |> Plug.Conn.put_status(500) |> Req.Test.json(%{})
        end
      end)

      assert :ok = ReviewPatrol.tick(name)
      assert reload(eng).status == :closed
      assert ReviewPatrol.state(name).last_terminated == [eng.id]

      # ── Final assertion: ZERO Jira tracker HTTP calls in the entire lifecycle
      refute_receive {:jira_http, _, _}
    end
  end

  # ── Test 2: Multi-reviewer isolation ─────────────────────────────────────

  describe "multi-reviewer isolation" do
    test "another reviewer's CHANGES_REQUESTED thread is fully ignored", %{ws: ws} do
      # Head unchanged → tick goes to author-reply branch. The PR has two threads:
      #   * ours (botreviewer): author replied at comment 1002
      #   * another reviewer's (human-reviewer): author also replied at comment 2002
      # ReviewPatrol must reply only to our thread and ignore the other one.
      eng =
        engagement(ws, 700, %{
          review_automation: :auto,
          last_reviewed_sha: "stable",
          last_seen_comment_id: "1000"
        })

      put_reply_composer("Addressed — thanks for the follow-up.")

      test_pid = self()

      nodes = [
        # Our thread: we opened it, colleague replied at 1002.
        thread_node("RT_ours", "lib/ours.ex", [
          {1001, "botreviewer", "please rename this"},
          {1002, "colleague", "renamed it, ok?"}
        ]),
        # Another reviewer's thread: human-reviewer opened it, colleague replied.
        # We never participated here — filter_our_threads must exclude it.
        thread_node("RT_other", "lib/other.ex", [
          {2001, "human-reviewer", "nit: extract this"},
          {2002, "colleague", "extracted, does this look better?"}
        ])
      ]

      stub_merger(fn conn ->
        cond do
          conn.method == "GET" and conn.request_path == "/repos/owner/repo/pulls/700" ->
            Req.Test.json(conn, %{
              "number" => 700,
              "state" => "open",
              "head" => %{"sha" => "stable"},
              "html_url" => "https://github.com/owner/repo/pull/700",
              "user" => %{"login" => "colleague"}
            })

          conn.method == "GET" and conn.request_path == "/repos/owner/repo/pulls/700/reviews" ->
            Req.Test.json(conn, [])

          conn.method == "POST" and conn.request_path == "/graphql" ->
            Req.Test.json(conn, %{
              "data" => %{
                "repository" => %{
                  "pullRequest" => %{"reviewThreads" => %{"nodes" => nodes}}
                }
              }
            })

          conn.method == "POST" and
              Regex.match?(~r{/pulls/700/comments/1002/replies$}, conn.request_path) ->
            {:ok, body, conn} = Plug.Conn.read_body(conn)
            send(test_pid, {:our_reply, Jason.decode!(body)})
            conn |> Plug.Conn.put_status(201) |> Req.Test.json(%{"id" => 9001})

          conn.method == "POST" and
              Regex.match?(~r{/pulls/700/comments/2002/replies$}, conn.request_path) ->
            {:ok, body, conn} = Plug.Conn.read_body(conn)
            send(test_pid, {:other_reply, Jason.decode!(body)})
            conn |> Plug.Conn.put_status(201) |> Req.Test.json(%{"id" => 9002})

          true ->
            conn |> Plug.Conn.put_status(500) |> Req.Test.json(%{})
        end
      end)

      {_pid, name} = start_patrol(ws)
      assert :ok = ReviewPatrol.tick(name)

      # We replied to our thread (comment 1002).
      assert_receive {:our_reply, reply}
      assert reply["body"] == "Addressed — thanks for the follow-up."

      # We did NOT reply to the other reviewer's thread (comment 2002).
      refute_receive {:other_reply, _}

      # Cursor advanced to 1002 (the highest comment in the batch we handled).
      assert reload(eng).last_seen_comment_id == "1002"
      assert ReviewPatrol.state(name).last_replied == [eng.id]
    end

    test "a CHANGES_REQUESTED from another reviewer does not prevent re-review", %{ws: ws} do
      # Another reviewer submitted CHANGES_REQUESTED; we still post our re-review
      # because ReviewPatrol only acts on the diff we care about (the relevant-file
      # guard) regardless of what other reviewers have submitted.
      eng =
        engagement(ws, 701, %{
          review_automation: :auto,
          last_reviewed_sha: "oldsha",
          posted_findings: [finding("lib/sec.ex", 10, "prior bug")]
        })

      put_invoker([finding("lib/sec.ex", 20, "new issue")])

      test_pid = self()

      diff =
        "diff --git a/lib/sec.ex b/lib/sec.ex\n--- a/lib/sec.ex\n+++ b/lib/sec.ex\n@@ -18,3 +18,4 @@\n+z\n"

      stub_merger(fn conn ->
        cond do
          conn.method == "GET" and conn.request_path == "/repos/owner/repo/pulls/701" ->
            Req.Test.json(conn, %{
              "number" => 701,
              "state" => "open",
              "head" => %{"sha" => "newsha"},
              "html_url" => "https://github.com/owner/repo/pull/701",
              "user" => %{"login" => "colleague"}
            })

          conn.method == "GET" and conn.request_path == "/repos/owner/repo/pulls/701/reviews" ->
            # Another reviewer submitted CHANGES_REQUESTED — ReviewPatrol must
            # not be confused by this and must still post our verdict.
            Req.Test.json(conn, [
              %{"user" => %{"login" => "human-reviewer"}, "state" => "CHANGES_REQUESTED"}
            ])

          conn.method == "GET" and
              String.starts_with?(conn.request_path, "/repos/owner/repo/compare/") ->
            conn
            |> Plug.Conn.put_resp_header("content-type", "text/plain")
            |> Plug.Conn.resp(200, diff)

          conn.method == "POST" and conn.request_path == "/repos/owner/repo/pulls/701/comments" ->
            {:ok, body, conn} = Plug.Conn.read_body(conn)
            send(test_pid, {:inline_comment, Jason.decode!(body)})
            conn |> Plug.Conn.put_status(201) |> Req.Test.json(%{"id" => 10})

          conn.method == "POST" and conn.request_path == "/repos/owner/repo/pulls/701/reviews" ->
            {:ok, body, conn} = Plug.Conn.read_body(conn)
            send(test_pid, {:submit_review, Jason.decode!(body)})
            conn |> Plug.Conn.put_status(200) |> Req.Test.json(%{"id" => 99})

          true ->
            conn |> Plug.Conn.put_status(500) |> Req.Test.json(%{})
        end
      end)

      {_pid, name} = start_patrol(ws)
      assert :ok = ReviewPatrol.tick(name)

      # Our re-review was posted despite the other reviewer's CHANGES_REQUESTED.
      assert_receive {:inline_comment, comment}
      assert comment["path"] == "lib/sec.ex"
      assert_receive {:submit_review, _}

      assert reload(eng).last_reviewed_sha == "newsha"
      assert ReviewPatrol.state(name).last_rereviewed == [eng.id]
    end
  end

  # ── Test 3: Merge-terminate idempotency ──────────────────────────────────

  describe "merge-terminate idempotency — full lifecycle" do
    test "engagement closes exactly once; every subsequent tick is a no-op", %{ws: ws} do
      eng =
        engagement(ws, 800, %{
          review_automation: :auto,
          last_reviewed_sha: "sha1"
        })

      # Stub the PR as merged for ALL ticks.
      stub_merger(fn conn ->
        cond do
          conn.method == "GET" and conn.request_path == "/repos/owner/repo/pulls/800" ->
            Req.Test.json(conn, %{
              "number" => 800,
              "merged" => true,
              "html_url" => "https://github.com/owner/repo/pull/800"
            })

          conn.method == "GET" and conn.request_path == "/repos/owner/repo/pulls/800/reviews" ->
            Req.Test.json(conn, [])

          true ->
            conn |> Plug.Conn.put_status(500) |> Req.Test.json(%{})
        end
      end)

      {_pid, name} = start_patrol(ws)

      # Tick 1: PR merged → engagement closed.
      assert :ok = ReviewPatrol.tick(name)
      assert reload(eng).status == :closed
      assert ReviewPatrol.state(name).last_terminated == [eng.id]

      # Tick 2: engagement is already :closed — the open-engagements query
      # (status != :closed) excludes it, so this is a pure no-op.
      assert :ok = ReviewPatrol.tick(name)
      assert ReviewPatrol.state(name).last_terminated == []
      assert reload(eng).status == :closed

      # Tick 3: same — still a no-op.
      assert :ok = ReviewPatrol.tick(name)
      assert ReviewPatrol.state(name).last_terminated == []
      assert reload(eng).status == :closed
    end

    test "two engagements on the same PR close independently without cross-contamination",
         %{ws: ws} do
      # Both engagements watch PR #801. Close them independently and verify each
      # closes exactly once.
      eng1 = engagement(ws, 801, %{last_reviewed_sha: "sha1"})
      eng2 = engagement(ws, 801, %{last_reviewed_sha: "sha2"})

      stub_merger(fn conn ->
        cond do
          conn.method == "GET" and conn.request_path == "/repos/owner/repo/pulls/801" ->
            Req.Test.json(conn, %{
              "number" => 801,
              "merged" => true,
              "html_url" => "https://github.com/owner/repo/pull/801"
            })

          conn.method == "GET" and conn.request_path == "/repos/owner/repo/pulls/801/reviews" ->
            Req.Test.json(conn, [])

          true ->
            conn |> Plug.Conn.put_status(500) |> Req.Test.json(%{})
        end
      end)

      {_pid, name} = start_patrol(ws)

      # Single tick terminates BOTH engagements.
      assert :ok = ReviewPatrol.tick(name)
      assert reload(eng1).status == :closed
      assert reload(eng2).status == :closed
      terminated = ReviewPatrol.state(name).last_terminated
      assert eng1.id in terminated
      assert eng2.id in terminated

      # Re-tick: both already closed → no-op.
      assert :ok = ReviewPatrol.tick(name)
      assert ReviewPatrol.state(name).last_terminated == []
    end
  end

  # ── Test 4: Auto vs flag paths end-to-end ────────────────────────────────

  describe "auto path — full lifecycle (SHA record → re-review → merge-terminate)" do
    test "three-tick auto lifecycle: SHA → re-review → merge-closed", %{ws: ws} do
      eng =
        engagement(ws, 900, %{
          review_automation: :auto,
          posted_findings: []
        })

      put_invoker([finding("lib/api.ex", 3, "missing auth check")])

      diff =
        "diff --git a/lib/api.ex b/lib/api.ex\n--- a/lib/api.ex\n+++ b/lib/api.ex\n@@ -1,3 +1,4 @@\n+x\n"

      test_pid = self()

      # Tick 1 stub: open PR, no prior SHA.
      stub_merger(fn conn ->
        cond do
          conn.method == "GET" and conn.request_path == "/repos/owner/repo/pulls/900" ->
            Req.Test.json(conn, %{
              "number" => 900,
              "state" => "open",
              "head" => %{"sha" => "abc"},
              "html_url" => "x",
              "user" => %{"login" => "dev"}
            })

          conn.method == "GET" and conn.request_path == "/repos/owner/repo/pulls/900/reviews" ->
            Req.Test.json(conn, [])

          true ->
            conn |> Plug.Conn.put_status(500) |> Req.Test.json(%{})
        end
      end)

      {_pid, name} = start_patrol(ws)
      assert :ok = ReviewPatrol.tick(name)
      assert reload(eng).last_reviewed_sha == "abc"

      # Tick 2 stub: head advanced → re-review fires.
      {:ok, eng2} =
        Ash.update(
          reload(eng),
          %{posted_findings: [finding("lib/api.ex", 1, "seed")]},
          action: :update
        )

      stub_merger(fn conn ->
        cond do
          conn.method == "GET" and conn.request_path == "/repos/owner/repo/pulls/900" ->
            Req.Test.json(conn, %{
              "number" => 900,
              "state" => "open",
              "head" => %{"sha" => "def"},
              "html_url" => "x",
              "user" => %{"login" => "dev"}
            })

          conn.method == "GET" and conn.request_path == "/repos/owner/repo/pulls/900/reviews" ->
            Req.Test.json(conn, [])

          conn.method == "GET" and
              String.starts_with?(conn.request_path, "/repos/owner/repo/compare/") ->
            conn
            |> Plug.Conn.put_resp_header("content-type", "text/plain")
            |> Plug.Conn.resp(200, diff)

          conn.method == "POST" and conn.request_path == "/repos/owner/repo/pulls/900/comments" ->
            send(test_pid, {:inline_comment, :posted})
            conn |> Plug.Conn.put_status(201) |> Req.Test.json(%{"id" => 1})

          conn.method == "POST" and conn.request_path == "/repos/owner/repo/pulls/900/reviews" ->
            send(test_pid, {:submit_review, :posted})
            conn |> Plug.Conn.put_status(200) |> Req.Test.json(%{"id" => 99})

          true ->
            conn |> Plug.Conn.put_status(500) |> Req.Test.json(%{})
        end
      end)

      assert :ok = ReviewPatrol.tick(name)
      assert_receive {:inline_comment, :posted}
      assert_receive {:submit_review, :posted}
      assert reload(eng2).last_reviewed_sha == "def"
      assert ReviewPatrol.state(name).last_rereviewed == [eng2.id]

      # Tick 3 stub: PR merged → terminate.
      stub_merger(fn conn ->
        cond do
          conn.method == "GET" and conn.request_path == "/repos/owner/repo/pulls/900" ->
            Req.Test.json(conn, %{
              "number" => 900,
              "merged" => true,
              "html_url" => "x"
            })

          conn.method == "GET" and conn.request_path == "/repos/owner/repo/pulls/900/reviews" ->
            Req.Test.json(conn, [])

          true ->
            conn |> Plug.Conn.put_status(500) |> Req.Test.json(%{})
        end
      end)

      assert :ok = ReviewPatrol.tick(name)
      assert reload(eng2).status == :closed
      assert ReviewPatrol.state(name).last_terminated == [eng2.id]
    end
  end

  describe "flag path — full lifecycle (SHA record → flag raised → merge-terminate)" do
    test "three-tick flag lifecycle: SHA → flag raised → merge-closed", %{ws: ws} do
      eng =
        engagement(ws, 901, %{
          review_automation: :flag,
          posted_findings: []
        })

      diff =
        "diff --git a/lib/b.ex b/lib/b.ex\n--- a/lib/b.ex\n+++ b/lib/b.ex\n@@ -1,3 +1,4 @@\n+x\n"

      # Tick 1 stub: open PR, no prior SHA.
      stub_merger(fn conn ->
        cond do
          conn.method == "GET" and conn.request_path == "/repos/owner/repo/pulls/901" ->
            Req.Test.json(conn, %{
              "number" => 901,
              "state" => "open",
              "head" => %{"sha" => "abc"},
              "html_url" => "x",
              "user" => %{"login" => "dev"}
            })

          conn.method == "GET" and conn.request_path == "/repos/owner/repo/pulls/901/reviews" ->
            Req.Test.json(conn, [])

          true ->
            conn |> Plug.Conn.put_status(500) |> Req.Test.json(%{})
        end
      end)

      {_pid, name} = start_patrol(ws)
      assert :ok = ReviewPatrol.tick(name)
      assert reload(eng).last_reviewed_sha == "abc"

      # Tick 2: head advanced, relevant file → flag raised (no inline review posted).
      {:ok, eng2} =
        Ash.update(
          reload(eng),
          %{posted_findings: [finding("lib/b.ex", 1, "seed")]},
          action: :update
        )

      stub_merger(fn conn ->
        cond do
          conn.method == "GET" and conn.request_path == "/repos/owner/repo/pulls/901" ->
            Req.Test.json(conn, %{
              "number" => 901,
              "state" => "open",
              "head" => %{"sha" => "def"},
              "html_url" => "x",
              "user" => %{"login" => "dev"}
            })

          conn.method == "GET" and conn.request_path == "/repos/owner/repo/pulls/901/reviews" ->
            Req.Test.json(conn, [])

          conn.method == "GET" and
              String.starts_with?(conn.request_path, "/repos/owner/repo/compare/") ->
            conn
            |> Plug.Conn.put_resp_header("content-type", "text/plain")
            |> Plug.Conn.resp(200, diff)

          true ->
            conn |> Plug.Conn.put_status(500) |> Req.Test.json(%{})
        end
      end)

      assert :ok = ReviewPatrol.tick(name)
      # Flag raised, not a re-review.
      assert ReviewPatrol.state(name).last_flagged == [eng2.id]
      assert ReviewPatrol.state(name).last_rereviewed == []
      # Cursor advanced so the same commits are not re-flagged.
      assert reload(eng2).last_reviewed_sha == "def"

      flags =
        Arbiter.Messages.Message
        |> Ash.Query.filter(directive_ref == ^eng2.id and kind == :flag)
        |> Ash.read!()

      assert length(flags) == 1

      # Tick 3: PR merged → terminate.
      stub_merger(fn conn ->
        cond do
          conn.method == "GET" and conn.request_path == "/repos/owner/repo/pulls/901" ->
            Req.Test.json(conn, %{
              "number" => 901,
              "merged" => true,
              "html_url" => "x"
            })

          conn.method == "GET" and conn.request_path == "/repos/owner/repo/pulls/901/reviews" ->
            Req.Test.json(conn, [])

          true ->
            conn |> Plug.Conn.put_status(500) |> Req.Test.json(%{})
        end
      end)

      assert :ok = ReviewPatrol.tick(name)
      assert reload(eng2).status == :closed
      assert ReviewPatrol.state(name).last_terminated == [eng2.id]
    end

    test "flag path: author reply in flag mode escalates to coordinator exactly once",
         %{ws: ws} do
      eng =
        engagement(ws, 902, %{
          review_automation: :flag,
          last_reviewed_sha: "stable",
          last_seen_comment_id: "500"
        })

      nodes = [
        thread_node("RT1", "lib/c.ex", [
          {500, "botreviewer", "our comment"},
          {501, "dev", "I disagree with this finding"}
        ])
      ]

      # Tick 1: author reply → escalation raised.
      stub_merger(fn conn ->
        cond do
          conn.method == "GET" and conn.request_path == "/repos/owner/repo/pulls/902" ->
            Req.Test.json(conn, %{
              "number" => 902,
              "state" => "open",
              "head" => %{"sha" => "stable"},
              "html_url" => "https://github.com/owner/repo/pull/902",
              "user" => %{"login" => "dev"}
            })

          conn.method == "GET" and conn.request_path == "/repos/owner/repo/pulls/902/reviews" ->
            Req.Test.json(conn, [])

          conn.method == "POST" and conn.request_path == "/graphql" ->
            Req.Test.json(conn, %{
              "data" => %{
                "repository" => %{
                  "pullRequest" => %{"reviewThreads" => %{"nodes" => nodes}}
                }
              }
            })

          true ->
            conn |> Plug.Conn.put_status(500) |> Req.Test.json(%{})
        end
      end)

      {_pid, name} = start_patrol(ws)
      assert :ok = ReviewPatrol.tick(name)

      # Escalation raised to coordinator; cursor advanced.
      escalations =
        Arbiter.Messages.Message
        |> Ash.Query.filter(directive_ref == ^eng.id and kind == :escalation)
        |> Ash.read!()

      assert length(escalations) == 1
      [esc] = escalations
      assert esc.to_ref == "admiral"
      assert esc.body =~ "dev"
      assert reload(eng).last_seen_comment_id == "501"
      assert ReviewPatrol.state(name).last_escalated == [eng.id]

      # Tick 2: same reply — cursor (501) is no longer newer than last_seen; no re-escalation.
      assert :ok = ReviewPatrol.tick(name)

      escalations_after =
        Arbiter.Messages.Message
        |> Ash.Query.filter(directive_ref == ^eng.id and kind == :escalation)
        |> Ash.read!()

      assert length(escalations_after) == 1
      assert ReviewPatrol.state(name).last_escalated == []
    end
  end
end
