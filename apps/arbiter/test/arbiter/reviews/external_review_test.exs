defmodule Arbiter.Reviews.ExternalReviewTest do
  # async: false — the GitHub merger uses the process-global Req.Test stub
  # registry and the per-process active-config dictionary.
  use Arbiter.DataCase, async: false

  alias Arbiter.Reviews.{ExternalReview, Record}
  alias Arbiter.Tasks.{Issue, Workspace}
  require Ash.Query

  @env_var "EXTERNAL_REVIEW_GH_TOKEN"

  defp uniq_prefix, do: "er" <> Integer.to_string(:erlang.unique_integer([:positive]))

  defp github_ws(name) do
    {:ok, ws} =
      Ash.create(Workspace, %{
        name: name,
        prefix: uniq_prefix(),
        config: %{
          "merge" => %{
            "strategy" => "github",
            "config" => %{
              "owner" => "octo",
              "repo" => "widget",
              "credentials_ref" => "env:#{@env_var}"
            }
          }
        }
      })

    ws
  end

  describe "prepare/1 — validation & resolution" do
    test "missing pr returns :pr_required" do
      github_ws("er-prep-1")
      assert {:error, :pr_required} = ExternalReview.prepare(pr: "")
      assert {:error, :pr_required} = ExternalReview.prepare(%{})
    end

    test "resolves the github MR adapter and an embedded ref from a PR URL" do
      ws = github_ws("er-prep-2")

      assert {:ok, prepared} =
               ExternalReview.prepare(
                 pr: "https://github.com/leo/verus_sigv4/pull/5",
                 workspace: ws.name
               )

      assert prepared.adapter == Arbiter.Mergers.Github
      assert prepared.strategy == :github
      assert prepared.mr_ref == "leo/verus_sigv4#5"
      assert prepared.link == "https://github.com/leo/verus_sigv4/pull/5"
    end

    test "resolves repo_path from workspace config and embeds owner/repo for a bare number" do
      repo = tmp_git_repo("git@github.com:leo/verus_auth_server.git")

      {:ok, ws} =
        Ash.create(Workspace, %{
          name: "er-prep-3",
          prefix: uniq_prefix(),
          config: %{
            "repo_paths" => %{"verus_auth_server" => repo},
            "merge" => %{
              "strategy" => "github",
              "config" => %{"owner" => "octo", "repo" => "widget"}
            }
          }
        })

      assert {:ok, prepared} =
               ExternalReview.prepare(pr: "394", repo: "verus_auth_server", workspace: ws.name)

      assert prepared.mr_ref == "leo/verus_auth_server#394"
    end

    test "the :direct merge strategy has no external-PR support" do
      {:ok, ws} =
        Ash.create(Workspace, %{
          name: "er-direct",
          prefix: uniq_prefix(),
          config: %{"merge" => %{"strategy" => "direct"}}
        })

      assert {:error, {:unsupported_strategy, :direct}} =
               ExternalReview.prepare(pr: "1", workspace: ws.name)
    end

    test "an unknown workspace name is reported" do
      assert {:error, {:workspace, msg}} =
               ExternalReview.prepare(pr: "1", workspace: "does-not-exist")

      assert msg =~ "not found"
    end

    test "nil workspace resolves the lone installation workspace" do
      ws = github_ws("er-sole")

      assert {:ok, prepared} = ExternalReview.prepare(pr: "octo/widget#3")
      assert prepared.workspace.id == ws.id
      assert prepared.mr_ref == "octo/widget#3"
    end
  end

  describe "review/1 — end-to-end against the GitHub adapter" do
    setup do
      System.put_env(@env_var, "test-token")
      on_exit(fn -> System.delete_env(@env_var) end)
      :ok
    end

    test "reads the diff, posts a finding, submits a verdict, returns it" do
      github_ws("er-e2e")
      events = :ets.new(:er_events, [:public, :duplicate_bag])

      Req.Test.stub(Arbiter.Mergers.Github.HTTP, fn conn ->
        path = conn.request_path

        cond do
          conn.method == "GET" and path == "/repos/octo/widget/pulls/42" and
              "application/vnd.github.v3.diff" in Plug.Conn.get_req_header(conn, "accept") ->
            conn
            |> Plug.Conn.put_resp_header("content-type", "text/plain")
            |> Plug.Conn.resp(
              200,
              "diff --git a/x.ex b/x.ex\n--- a/x.ex\n+++ b/x.ex\n@@ -0,0 +1 @@\n+boom\n"
            )

          conn.method == "GET" and path == "/repos/octo/widget/pulls/42" ->
            conn
            |> Plug.Conn.put_resp_header("content-type", "application/json")
            |> Plug.Conn.resp(200, Jason.encode!(%{"number" => 42, "head" => %{"sha" => "abc"}}))

          conn.method == "POST" and path == "/repos/octo/widget/pulls/42/comments" ->
            :ets.insert(events, {:comment, true})

            conn
            |> Plug.Conn.put_resp_header("content-type", "application/json")
            |> Plug.Conn.resp(201, Jason.encode!(%{"id" => 1}))

          conn.method == "POST" and path == "/repos/octo/widget/pulls/42/reviews" ->
            {:ok, body, conn} = Plug.Conn.read_body(conn)
            :ets.insert(events, {:review, Jason.decode!(body)})

            conn
            |> Plug.Conn.put_resp_header("content-type", "application/json")
            |> Plug.Conn.resp(200, Jason.encode!(%{"id" => 99}))

          true ->
            conn
            |> Plug.Conn.put_resp_header("content-type", "application/json")
            |> Plug.Conn.resp(404, Jason.encode!(%{"message" => "unhandled #{path}"}))
        end
      end)

      runner = fn _diff, _state ->
        {:ok, [%{severity: :error, file: "x.ex", line: 1, message: "boom"}]}
      end

      assert {:ok, result} =
               ExternalReview.review(pr: "octo/widget#42", check_runner: runner)

      assert result.verdict == :request_changes
      assert result.findings == 1
      assert result.mr_ref == "octo/widget#42"
      assert [{:comment, true}] = :ets.lookup(events, :comment)
      assert [{:review, review}] = :ets.lookup(events, :review)
      assert review["event"] == "REQUEST_CHANGES"
    end

    test "no findings → an approve verdict is submitted" do
      github_ws("er-e2e-approve")

      Req.Test.stub(Arbiter.Mergers.Github.HTTP, fn conn ->
        cond do
          "application/vnd.github.v3.diff" in Plug.Conn.get_req_header(conn, "accept") ->
            conn
            |> Plug.Conn.put_resp_header("content-type", "text/plain")
            |> Plug.Conn.resp(200, "diff --git a/x.ex b/x.ex\n+ok\n")

          conn.method == "POST" and conn.request_path =~ ~r{/reviews$} ->
            {:ok, body, conn} = Plug.Conn.read_body(conn)
            send(self(), {:review_event, Jason.decode!(body)["event"]})

            conn
            |> Plug.Conn.put_resp_header("content-type", "application/json")
            |> Plug.Conn.resp(200, Jason.encode!(%{"id" => 1}))

          true ->
            conn
            |> Plug.Conn.put_resp_header("content-type", "application/json")
            |> Plug.Conn.resp(200, Jason.encode!(%{}))
        end
      end)

      runner = fn _diff, _state -> {:ok, []} end

      assert {:ok, %{verdict: :approve}} =
               ExternalReview.review(pr: "octo/widget#1", check_runner: runner)
    end
  end

  describe "review/1 — scope: repo (bd-5xsp25)" do
    setup do
      System.put_env(@env_var, "test-token")
      on_exit(fn -> System.delete_env(@env_var) end)
      :ok
    end

    # A shared-signature change: token.ex's `sign/1` diff, plus session.ex — an
    # untouched file elsewhere in the repo — calling it. A diff-only review
    # only ever sees token.ex's own diff text; a repo-scoped review can trace
    # session.ex as a consumer via a read-only repo checkout.
    defp consumer_fixture_repo do
      dir = Path.join(System.tmp_dir!(), "er-consumer-#{:erlang.unique_integer([:positive])}")
      File.mkdir_p!(Path.join(dir, "lib/verus"))

      File.write!(Path.join(dir, "lib/verus/token.ex"), """
      defmodule Verus.Token do
        def sign(payload) do
          :ok
        end
      end
      """)

      File.write!(Path.join(dir, "lib/verus/session.ex"), """
      defmodule Verus.Session do
        def start(payload) do
          Verus.Token.sign(payload)
        end
      end
      """)

      {_, 0} = System.cmd("git", ["init", "-q", dir])
      {_, 0} = System.cmd("git", ["-C", dir, "config", "user.email", "test@example.com"])
      {_, 0} = System.cmd("git", ["-C", dir, "config", "user.name", "Test"])
      {_, 0} = System.cmd("git", ["-C", dir, "add", "-A"])
      {_, 0} = System.cmd("git", ["-C", dir, "commit", "-q", "-m", "init"])

      on_exit(fn -> File.rm_rf!(dir) end)
      dir
    end

    defp consumer_ws(name, repo_path) do
      {:ok, ws} =
        Ash.create(Workspace, %{
          name: name,
          prefix: uniq_prefix(),
          config: %{
            "repo_paths" => %{"widget" => repo_path},
            "merge" => %{
              "strategy" => "github",
              "config" => %{
                "owner" => "octo",
                "repo" => "widget",
                "credentials_ref" => "env:#{@env_var}"
              }
            }
          }
        })

      ws
    end

    defp stub_signature_diff do
      Req.Test.stub(Arbiter.Mergers.Github.HTTP, fn conn ->
        cond do
          "application/vnd.github.v3.diff" in Plug.Conn.get_req_header(conn, "accept") ->
            conn
            |> Plug.Conn.put_resp_header("content-type", "text/plain")
            |> Plug.Conn.resp(200, """
            diff --git a/lib/verus/token.ex b/lib/verus/token.ex
            --- a/lib/verus/token.ex
            +++ b/lib/verus/token.ex
            @@ -1,3 +1,3 @@
            -  def sign(payload, algorithm) do
            +  def sign(payload) do
            """)

          conn.method == "GET" and conn.request_path =~ ~r{/repos/octo/widget/pulls/\d+$} ->
            conn
            |> Plug.Conn.put_resp_header("content-type", "application/json")
            |> Plug.Conn.resp(200, Jason.encode!(%{"number" => 7, "head" => %{"sha" => "abc"}}))

          conn.method == "POST" and conn.request_path =~ ~r{/reviews$} ->
            conn
            |> Plug.Conn.put_resp_header("content-type", "application/json")
            |> Plug.Conn.resp(200, Jason.encode!(%{"id" => 1}))

          true ->
            conn
            |> Plug.Conn.put_resp_header("content-type", "application/json")
            |> Plug.Conn.resp(200, Jason.encode!(%{}))
        end
      end)
    end

    # A stub reviewer that can only see what diff-only review sees (the diff
    # text) plus, when present, the repo-scope consumer trace — flags a
    # finding for each consumer ref, none otherwise. This is how a real
    # reviewer prompt would behave once `Checks.build_prompt/2` folds
    # `consumer_refs` in: nothing to say about a caller it never saw.
    defp consumer_aware_runner do
      fn _diff, state ->
        findings =
          (state[:consumer_refs] || [])
          |> Enum.map(fn ref ->
            %{
              severity: :warning,
              file: ref.file,
              line: ref.line,
              message:
                "call site of changed function `#{ref.identifier}` — verify it still matches"
            }
          end)

        {:ok, findings}
      end
    end

    test "repo scope surfaces a downstream consumer finding a diff-only review misses" do
      repo = consumer_fixture_repo()
      consumer_ws("er-scope-repo", repo)

      stub_signature_diff()

      assert {:ok, result} =
               ExternalReview.review(
                 pr: "octo/widget#7",
                 repo: "widget",
                 scope: "repo",
                 check_runner: consumer_aware_runner()
               )

      assert result.findings == 1
    end

    test "the default (diff) scope does not surface the same finding" do
      repo = consumer_fixture_repo()
      consumer_ws("er-scope-diff", repo)

      stub_signature_diff()

      assert {:ok, result} =
               ExternalReview.review(
                 pr: "octo/widget#8",
                 repo: "widget",
                 check_runner: consumer_aware_runner()
               )

      assert result.findings == 0
    end
  end

  describe "review/1 — worktree-backed checkout (bd-6onexk)" do
    setup do
      System.put_env(@env_var, "test-token")
      on_exit(fn -> System.delete_env(@env_var) end)
      :ok
    end

    # A real local "origin" + a clone of it (used as the workspace's
    # `repo_paths` entry, standing in for a worker's shared checkout). The
    # PR's head commit (`b.txt`) is committed to `origin` only — the clone
    # does NOT have it yet — mirroring a PR the shared checkout hasn't
    # fetched. Returns `{clone_path, head_sha}`.
    defp checkout_fixture_repo do
      root = Path.join(System.tmp_dir!(), "er-checkout-#{:erlang.unique_integer([:positive])}")
      origin = Path.join(root, "origin")
      clone = Path.join(root, "clone")
      File.mkdir_p!(origin)

      {_, 0} = System.cmd("git", ["init", "-q", "-b", "main", origin])
      {_, 0} = System.cmd("git", ["-C", origin, "config", "user.email", "test@example.com"])
      {_, 0} = System.cmd("git", ["-C", origin, "config", "user.name", "Test"])
      File.write!(Path.join(origin, "a.txt"), "a")
      {_, 0} = System.cmd("git", ["-C", origin, "add", "-A"])
      {_, 0} = System.cmd("git", ["-C", origin, "commit", "-q", "-m", "init"])

      {_, 0} = System.cmd("git", ["clone", "-q", origin, clone])
      {_, 0} = System.cmd("git", ["-C", clone, "remote", "set-url", "origin", origin])

      File.write!(Path.join(origin, "b.txt"), "pr head content")
      {_, 0} = System.cmd("git", ["-C", origin, "add", "-A"])
      {_, 0} = System.cmd("git", ["-C", origin, "commit", "-q", "-m", "pr head"])
      {head_sha, 0} = System.cmd("git", ["-C", origin, "rev-parse", "HEAD"])

      on_exit(fn -> File.rm_rf(root) end)

      {clone, String.trim(head_sha)}
    end

    defp checkout_ws(name, repo_path) do
      {:ok, ws} =
        Ash.create(Workspace, %{
          name: name,
          prefix: uniq_prefix(),
          config: %{
            "repo_paths" => %{"widget" => repo_path},
            "merge" => %{
              "strategy" => "github",
              "config" => %{
                "owner" => "octo",
                "repo" => "widget",
                "credentials_ref" => "env:#{@env_var}"
              }
            }
          }
        })

      ws
    end

    defp stub_pr(head_sha) do
      Req.Test.stub(Arbiter.Mergers.Github.HTTP, fn conn ->
        cond do
          "application/vnd.github.v3.diff" in Plug.Conn.get_req_header(conn, "accept") ->
            conn
            |> Plug.Conn.put_resp_header("content-type", "text/plain")
            |> Plug.Conn.resp(200, "diff --git a/a.txt b/a.txt\n+x\n")

          conn.method == "GET" and conn.request_path =~ ~r{/repos/octo/widget/pulls/\d+$} ->
            conn
            |> Plug.Conn.put_resp_header("content-type", "application/json")
            |> Plug.Conn.resp(
              200,
              Jason.encode!(%{
                "number" => 9,
                "head" => %{"sha" => head_sha},
                "base" => %{"ref" => "main"}
              })
            )

          conn.method == "POST" and conn.request_path =~ ~r{/reviews$} ->
            conn
            |> Plug.Conn.put_resp_header("content-type", "application/json")
            |> Plug.Conn.resp(200, Jason.encode!(%{"id" => 1}))

          true ->
            conn
            |> Plug.Conn.put_resp_header("content-type", "application/json")
            |> Plug.Conn.resp(200, Jason.encode!(%{}))
        end
      end)
    end

    defp state_capturing_runner(test_pid) do
      fn _diff, state ->
        # Snapshot whether the checkout is actually populated *now*, while the
        # runner is executing — `ExternalReview` tears the worktree down right
        # after the workflow completes, which is before `review/1` returns to
        # the caller, so checking `File.exists?` after the fact would always
        # observe the post-teardown (already-removed) state.
        cwd = state[:review_cwd]
        b_txt_present? = is_binary(cwd) and File.exists?(Path.join(cwd, "b.txt"))
        send(test_pid, {:captured_state, state, b_txt_present?})
        {:ok, []}
      end
    end

    test "provisions a PR-head worktree, points repo_path/review_cwd at it, tears it down after" do
      {repo, head_sha} = checkout_fixture_repo()
      checkout_ws("er-checkout-ok", repo)
      stub_pr(head_sha)

      assert {:ok, _result} =
               ExternalReview.review(
                 pr: "octo/widget#9",
                 repo: "widget",
                 check_runner: state_capturing_runner(self())
               )

      assert_received {:captured_state, state, b_txt_present?}

      cwd = state[:review_cwd]
      assert is_binary(cwd)
      assert cwd != repo
      assert state[:repo_path] == cwd

      # The worktree really was checked out at the PR head — a file that
      # exists on `origin` at that commit but never made it into the shared
      # clone `repo` — while the reviewer was running against it.
      assert b_txt_present?

      # bd-5yp6yn: :read_diff is routed through the checkout, not the REST
      # diff endpoint — the diff came from `git diff main..HEAD` locally.
      assert state[:worktree_path] == cwd
      assert state[:base] == "main"
      assert state[:diff] =~ "b.txt"

      # Best-effort teardown ran after the workflow completed (by the time
      # `review/1` returned to us here).
      refute File.dir?(cwd)
    end

    test "a REST-diff-hostile stub (would 406 on a >20k-line PR) still completes via the local checkout diff (bd-5yp6yn)" do
      {repo, head_sha} = checkout_fixture_repo()
      checkout_ws("er-checkout-406", repo)

      Req.Test.stub(Arbiter.Mergers.Github.HTTP, fn conn ->
        cond do
          "application/vnd.github.v3.diff" in Plug.Conn.get_req_header(conn, "accept") ->
            conn
            |> Plug.Conn.put_resp_header("content-type", "application/json")
            |> Plug.Conn.resp(
              406,
              Jason.encode!(%{
                "message" => "Sorry, the diff exceeded the maximum number of lines (20000)"
              })
            )

          conn.method == "GET" and conn.request_path =~ ~r{/repos/octo/widget/pulls/\d+$} ->
            conn
            |> Plug.Conn.put_resp_header("content-type", "application/json")
            |> Plug.Conn.resp(
              200,
              Jason.encode!(%{
                "number" => 11,
                "head" => %{"sha" => head_sha},
                "base" => %{"ref" => "main"}
              })
            )

          conn.method == "POST" and conn.request_path =~ ~r{/reviews$} ->
            conn
            |> Plug.Conn.put_resp_header("content-type", "application/json")
            |> Plug.Conn.resp(200, Jason.encode!(%{"id" => 1}))

          true ->
            conn
            |> Plug.Conn.put_resp_header("content-type", "application/json")
            |> Plug.Conn.resp(200, Jason.encode!(%{}))
        end
      end)

      assert {:ok, result} =
               ExternalReview.review(
                 pr: "octo/widget#11",
                 repo: "widget",
                 check_runner: state_capturing_runner(self())
               )

      refute result[:error]
      assert_received {:captured_state, state, _b_txt_present?}
      assert state[:diff] =~ "b.txt"
    end

    test "falls back to the diff-only path (no review_cwd) when checkout can't be provisioned" do
      # repo_path resolves to a directory that isn't a git repo at all, so
      # `Checkout.provision/2` fails and the review must still complete using
      # the Tier-1 diff-only path.
      not_a_repo =
        Path.join(System.tmp_dir!(), "er-not-a-repo-#{:erlang.unique_integer([:positive])}")

      File.mkdir_p!(not_a_repo)
      on_exit(fn -> File.rm_rf(not_a_repo) end)

      checkout_ws("er-checkout-fallback", not_a_repo)
      stub_pr("deadbeefdeadbeefdeadbeefdeadbeefdeadbeef")

      assert {:ok, _result} =
               ExternalReview.review(
                 pr: "octo/widget#10",
                 repo: "widget",
                 check_runner: state_capturing_runner(self())
               )

      assert_received {:captured_state, state, _b_txt_present?}
      assert state[:review_cwd] == nil
      assert state[:repo_path] == not_a_repo
    end
  end

  describe "review/1 — follow-up engagement (Option A)" do
    setup do
      System.put_env(@env_var, "test-token")
      on_exit(fn -> System.delete_env(@env_var) end)
      :ok
    end

    test "follow_up: true creates one review_only engagement with a baseline" do
      ws = github_ws("er-follow")
      stub_full_review(head_sha: "sha-head-1", author: "coworker", max_comment_id: 500)

      assert {:ok, result} =
               ExternalReview.review(
                 pr: "octo/widget#42",
                 workspace: ws.name,
                 follow_up: true,
                 check_runner: one_finding()
               )

      assert result.engagement_created == true
      assert is_binary(result.engagement)

      engagement = Ash.get!(Issue, result.engagement)
      assert engagement.review_only == true
      assert engagement.source_pr == "octo/widget#42"
      assert engagement.workspace_id == ws.id
      # Baseline: PR head at review time + current comment high-watermark.
      assert engagement.last_reviewed_sha == "sha-head-1"
      assert engagement.last_seen_comment_id == "500"
      # Resolved automation mode (no policy → conservative :flag).
      assert engagement.review_automation == :flag
      # Tracker-inert + non-reviewable (no worktree/branch).
      assert engagement.tracker_type == :none
      assert engagement.issue_type == :task
      # First-pass findings seed the relevance baseline, string-keyed to match
      # what ReviewPatrol persists/reads — so a later commit touching x.ex
      # triggers a re-review.
      assert [finding] = engagement.posted_findings
      assert finding["file"] == "x.ex"
      assert finding["line"] == 1
      assert finding["message"] == "boom"
      assert finding["severity"] == "error"
    end

    test "an approve / zero-finding review seeds no posted_findings" do
      ws = github_ws("er-approve")
      stub_full_review(head_sha: "sha-head-1", author: "coworker", max_comment_id: 500)

      assert {:ok, result} =
               ExternalReview.review(
                 pr: "octo/widget#42",
                 workspace: ws.name,
                 follow_up: true,
                 check_runner: fn _diff, _state -> {:ok, []} end
               )

      engagement = Ash.get!(Issue, result.engagement)
      # Empty is correct here — nothing flagged, so ReviewPatrol stays quiet.
      assert engagement.posted_findings == []
    end

    test "without follow_up the flow is unchanged (no engagement)" do
      ws = github_ws("er-noeng")
      stub_full_review(head_sha: "sha-x", author: "coworker", max_comment_id: 1)

      assert {:ok, result} =
               ExternalReview.review(
                 pr: "octo/widget#42",
                 workspace: ws.name,
                 check_runner: one_finding()
               )

      assert result.engagement == nil
      assert result.engagement_created == false
      assert engagements_for(ws.id, "octo/widget#42") == []
    end

    test "a second follow_up dispatch for the same PR does not duplicate" do
      ws = github_ws("er-dedup")
      stub_full_review(head_sha: "sha-1", author: "coworker", max_comment_id: 10)

      assert {:ok, first} =
               ExternalReview.review(
                 pr: "octo/widget#42",
                 workspace: ws.name,
                 follow_up: true,
                 check_runner: one_finding()
               )

      assert first.engagement_created == true

      assert {:ok, second} =
               ExternalReview.review(
                 pr: "octo/widget#42",
                 workspace: ws.name,
                 follow_up: true,
                 check_runner: one_finding()
               )

      assert second.engagement_created == false
      assert second.engagement == first.engagement
      assert length(engagements_for(ws.id, "octo/widget#42")) == 1
    end

    test "explicit automation override + tracker_context are carried onto the engagement" do
      ws = github_ws("er-auto")
      stub_full_review(head_sha: "sha-1", author: "coworker", max_comment_id: 3)

      assert {:ok, result} =
               ExternalReview.review(
                 pr: "octo/widget#42",
                 workspace: ws.name,
                 follow_up: true,
                 automation: "auto",
                 tracker_context_ref: "VR-18004",
                 check_runner: one_finding()
               )

      engagement = Ash.get!(Issue, result.engagement)
      assert engagement.review_automation == :auto
      assert engagement.tracker_context_ref == "VR-18004"
    end
  end

  describe "review/1 — tracker ticket body + PR metadata in the reviewer prompt (bd-adpwl0)" do
    @jira_env "EXTERNAL_REVIEW_JIRA_TEST_TOKEN"

    setup do
      System.put_env(@env_var, "test-token")
      on_exit(fn -> System.delete_env(@env_var) end)
      :ok
    end

    test "the PR's title + body reach state.pr and the reviewer prompt" do
      ws = github_ws("er-pr-meta")
      stub_full_review(head_sha: "sha-1", author: "coworker", max_comment_id: 1)

      test_pid = self()

      runner = fn _diff, state ->
        send(test_pid, {:state, state})
        {:ok, []}
      end

      assert {:ok, _result} =
               ExternalReview.review(
                 pr: "octo/widget#42",
                 workspace: ws.name,
                 check_runner: runner
               )

      assert_received {:state, state}
      assert state.pr.title == "Fix widget overflow"
      assert state.pr.body == "Closes #42 by clamping the widget height."
    end

    test "tracker_context_ref/type are fetched and threaded onto the workflow state" do
      System.put_env(@jira_env, "test-jira-token")
      on_exit(fn -> System.delete_env(@jira_env) end)

      ws =
        Ash.create!(Workspace, %{
          name: "er-jira-ctx",
          prefix: uniq_prefix(),
          config: %{
            "merge" => %{
              "strategy" => "github",
              "config" => %{
                "owner" => "octo",
                "repo" => "widget",
                "credentials_ref" => "env:#{@env_var}"
              }
            },
            "tracker" => %{
              "type" => "jira",
              "config" => %{
                "host" => "leotechnologies.atlassian.net",
                "project_key" => "VR",
                "credentials_ref" => "env:#{@jira_env}",
                "email" => "tester@example.com"
              }
            }
          }
        })

      stub_full_review(head_sha: "sha-1", author: "coworker", max_comment_id: 1)

      Req.Test.stub(Arbiter.Trackers.Jira.HTTP, fn conn ->
        json(conn, %{
          "key" => "VR-18174",
          "fields" => %{
            "summary" => "Prompt too long on large PRs",
            "description" => "The reviewer chokes on bundled app.js diffs."
          }
        })
      end)

      test_pid = self()

      runner = fn _diff, state ->
        send(test_pid, {:state, state})
        {:ok, []}
      end

      assert {:ok, _result} =
               ExternalReview.review(
                 pr: "octo/widget#42",
                 workspace: ws.name,
                 tracker_context_ref: "VR-18174",
                 check_runner: runner
               )

      assert_received {:state, state}
      assert state.tracker_context.ref == "VR-18174"
      assert state.tracker_context.type == :jira
      assert state.tracker_context.title == "Prompt too long on large PRs"
      assert state.tracker_context.description == "The reviewer chokes on bundled app.js diffs."
    end
  end

  describe "review/1 — audit record persistence (bd-31fh9e)" do
    setup do
      System.put_env(@env_var, "test-token")
      on_exit(fn -> System.delete_env(@env_var) end)
      :ok
    end

    test "review/1 persists a :completed record with the verdict and finding count" do
      ws = github_ws("er-rec-1")
      stub_full_review(head_sha: "sha-rec1", author: "dev", max_comment_id: 1)

      assert {:ok, _result} =
               ExternalReview.review(
                 pr: "octo/widget#42",
                 workspace: ws.name,
                 follow_up: false,
                 check_runner: one_finding()
               )

      # Exactly one record for this pr_ref in this workspace.
      records = records_for(ws.id, "octo/widget#42")
      assert length(records) == 1
      [rec] = records

      assert rec.status == :completed
      assert rec.verdict == :request_changes
      assert rec.finding_count == 1
      assert rec.workspace_id == ws.id
      assert rec.strategy == "github"
      assert is_binary(rec.link)
      assert %DateTime{} = rec.started_at
      assert %DateTime{} = rec.completed_at
      assert DateTime.compare(rec.started_at, rec.completed_at) in [:lt, :eq]
      # findings_summary should capture the finding.
      assert String.contains?(rec.findings_summary || "", "x.ex")
    end

    test "review/1 with no findings persists a :completed :approve record" do
      ws = github_ws("er-rec-2")
      stub_full_review(head_sha: "sha-rec2", author: "dev", max_comment_id: 1)

      assert {:ok, _result} =
               ExternalReview.review(
                 pr: "octo/widget#42",
                 workspace: ws.name,
                 follow_up: false,
                 check_runner: fn _diff, _state -> {:ok, []} end
               )

      [rec] = records_for(ws.id, "octo/widget#42")
      assert rec.status == :completed
      assert rec.verdict == :approve
      assert rec.finding_count == 0
      assert is_nil(rec.findings_summary)
    end

    test "dispatched_by is stored when supplied in opts" do
      ws = github_ws("er-rec-3")
      stub_full_review(head_sha: "sha-rec3", author: "dev", max_comment_id: 1)

      assert {:ok, _} =
               ExternalReview.review(
                 pr: "octo/widget#42",
                 workspace: ws.name,
                 follow_up: false,
                 dispatched_by: "mcp",
                 check_runner: fn _diff, _state -> {:ok, []} end
               )

      [rec] = records_for(ws.id, "octo/widget#42")
      assert rec.dispatched_by == "mcp"
    end

    test "engagement_id is stored when a follow-up engagement is created" do
      ws = github_ws("er-rec-4")
      stub_full_review(head_sha: "sha-rec4", author: "dev", max_comment_id: 1)

      assert {:ok, result} =
               ExternalReview.review(
                 pr: "octo/widget#42",
                 workspace: ws.name,
                 follow_up: true,
                 check_runner: one_finding()
               )

      assert result.engagement_created == true
      [rec] = records_for(ws.id, "octo/widget#42")
      assert rec.engagement_id == result.engagement
    end
  end

  # bd-2o4b8f: a `file_findings` post failure (e.g. GitHub's secondary rate
  # limit outlasting the adapter's own retries) must not discard a review that
  # already read the diff and computed findings + a verdict — those are
  # recoverable via `greenlight/1`, not gone.
  describe "review/1 — file_findings post failure retains findings (bd-2o4b8f)" do
    setup do
      System.put_env(@env_var, "test-token")

      Application.put_env(:arbiter, :github_retry_sleep_fun, fn _ms -> :ok end)

      on_exit(fn ->
        System.delete_env(@env_var)
        Application.delete_env(:arbiter, :github_retry_sleep_fun)
      end)

      :ok
    end

    defp stub_forge_forbidden_on_comment_post(head_sha) do
      Req.Test.stub(Arbiter.Mergers.Github.HTTP, fn conn ->
        path = conn.request_path
        diff? = "application/vnd.github.v3.diff" in Plug.Conn.get_req_header(conn, "accept")

        cond do
          conn.method == "GET" and path == "/repos/octo/widget/pulls/42" and diff? ->
            conn
            |> Plug.Conn.put_resp_header("content-type", "text/plain")
            |> Plug.Conn.resp(
              200,
              "diff --git a/x.ex b/x.ex\n--- a/x.ex\n+++ b/x.ex\n@@ -0,0 +1 @@\n+boom\n"
            )

          conn.method == "GET" and path == "/repos/octo/widget/pulls/42" ->
            conn
            |> Plug.Conn.put_resp_header("content-type", "application/json")
            |> Plug.Conn.resp(
              200,
              Jason.encode!(%{
                "number" => 42,
                "state" => "open",
                "head" => %{"sha" => head_sha},
                "html_url" => "https://github.com/octo/widget/pull/42"
              })
            )

          conn.method == "GET" and path == "/repos/octo/widget/pulls/42/reviews" ->
            conn
            |> Plug.Conn.put_resp_header("content-type", "application/json")
            |> Plug.Conn.resp(200, "[]")

          # The forge's secondary rate limit (bd-1yva53): a 403 that outlasts
          # the adapter's own bounded retries.
          conn.method == "POST" and path == "/repos/octo/widget/pulls/42/comments" ->
            conn
            |> Plug.Conn.put_resp_header("content-type", "application/json")
            |> Plug.Conn.resp(
              403,
              Jason.encode!(%{
                "message" =>
                  "You have exceeded a secondary rate limit and have been temporarily blocked."
              })
            )

          true ->
            conn
            |> Plug.Conn.put_resp_header("content-type", "application/json")
            |> Plug.Conn.resp(404, Jason.encode!(%{"message" => "unhandled #{path}"}))
        end
      end)
    end

    test "persists a :completed_unposted record with the findings + verdict retained" do
      ws = github_ws("er-postfail-1")
      stub_forge_forbidden_on_comment_post("sha-postfail-1")

      assert {:error, _reason} =
               ExternalReview.review(
                 pr: "octo/widget#42",
                 workspace: ws.name,
                 follow_up: false,
                 check_runner: one_finding()
               )

      [rec] = records_for(ws.id, "octo/widget#42")

      assert rec.status == :completed_unposted
      assert rec.verdict == :request_changes
      assert rec.finding_count == 1
      assert rec.greenlight_status == :pending
      assert [%{"file" => "x.ex", "line" => 1}] = rec.proposed_comments
      assert String.contains?(rec.findings_summary || "", "x.ex")
      # bd-7rspia: even a :completed_unposted (partial) failure is diagnosable
      # from the record alone — no ssh/journalctl needed.
      assert rec.failure_stage == "file_findings"
      assert is_binary(rec.failure_reason)
      assert String.contains?(rec.failure_reason, "rate limit")
    end

    # bd-7rspia ac#4: accrued usage from :run_checks must survive the
    # :file_findings salvage path so cost reporting doesn't understate spend.
    test "retains accrued model/cost/token usage on the salvaged :completed_unposted record" do
      ws = github_ws("er-postfail-4")
      stub_forge_forbidden_on_comment_post("sha-postfail-4")

      usage_runner = fn _diff, _state ->
        {:ok, [%{severity: :error, file: "x.ex", line: 1, message: "boom"}],
         %{model: "claude-opus-4-8", cost_usd: 1.2345, tokens_in: 4000, tokens_out: 300}}
      end

      assert {:error, _reason} =
               ExternalReview.review(
                 pr: "octo/widget#42",
                 workspace: ws.name,
                 follow_up: false,
                 check_runner: usage_runner
               )

      [rec] = records_for(ws.id, "octo/widget#42")

      assert rec.status == :completed_unposted
      assert rec.model == "claude-opus-4-8"
      assert rec.cost_usd == 1.2345
      assert rec.tokens_in == 4000
      assert rec.tokens_out == 300
      assert rec.failure_stage == "file_findings"
    end

    # Contrast with the cheap failure mode: a `read_diff` failure has no
    # findings to retain, and must remain a plain :failed record.
    test "a read_diff failure (nothing computed yet) stays a plain :failed record" do
      ws = github_ws("er-postfail-2")

      Req.Test.stub(Arbiter.Mergers.Github.HTTP, fn conn ->
        conn
        |> Plug.Conn.put_resp_header("content-type", "application/json")
        |> Plug.Conn.resp(500, Jason.encode!(%{"message" => "boom"}))
      end)

      assert {:error, _reason} =
               ExternalReview.review(pr: "octo/widget#42", workspace: ws.name, follow_up: false)

      [rec] = records_for(ws.id, "octo/widget#42")

      assert rec.status == :failed
      assert is_nil(rec.verdict)
      assert is_nil(rec.finding_count)
      assert is_nil(rec.greenlight_status)
      assert rec.proposed_comments == []
      # bd-7rspia: read_diff vs file_findings failures must be distinguishable
      # from the record alone, with no ssh/journalctl step.
      assert rec.failure_stage == "read_diff"
      assert is_binary(rec.failure_reason)
      assert String.contains?(rec.failure_reason, "boom")
    end

    test "the salvaged record is re-postable via greenlight/1 once the forge recovers" do
      ws = github_ws("er-postfail-3")
      stub_forge_forbidden_on_comment_post("sha-postfail-3")

      assert {:error, _reason} =
               ExternalReview.review(
                 pr: "octo/widget#42",
                 workspace: ws.name,
                 follow_up: false,
                 check_runner: one_finding()
               )

      [rec] = records_for(ws.id, "octo/widget#42")
      assert rec.status == :completed_unposted

      # The forge recovers — comments and reviews now succeed.
      stub_full_review(head_sha: "sha-postfail-3", author: "dev", max_comment_id: 1)

      assert {:ok, gl} = ExternalReview.greenlight(record_id: rec.id, select: "all")
      assert gl.posted == 1
      assert gl.verdict_posted == true

      reloaded = Ash.get!(Record, rec.id)
      assert reloaded.greenlight_status == :posted
    end
  end

  describe "review/1 — external_review event broadcast (bd-6f9u6z)" do
    setup do
      System.put_env(@env_var, "test-token")
      on_exit(fn -> System.delete_env(@env_var) end)
      :ok
    end

    test "broadcasts running then completed on the workspace event stream" do
      ws = github_ws("er-events-1")
      stub_full_review(head_sha: "sha-ev1", author: "dev", max_comment_id: 1)

      :ok = Phoenix.PubSub.subscribe(Arbiter.PubSub, Arbiter.Events.pubsub_topic(ws.id))

      assert {:ok, _result} =
               ExternalReview.review(
                 pr: "octo/widget#42",
                 workspace: ws.name,
                 follow_up: false,
                 check_runner: one_finding()
               )

      assert_receive {:event, %{topic: "external_review", status: "running"} = running}
      assert running.pr_ref == "octo/widget#42"
      assert running.mode == :auto
      assert is_binary(running.review_record_id)

      assert_receive {:event, %{topic: "external_review", status: "completed"} = completed}
      assert completed.pr_ref == "octo/widget#42"
      assert completed.verdict == :request_changes
      assert completed.finding_count == 1
      assert completed.mode == :auto
      assert completed.review_record_id == running.review_record_id
    end

    test "broadcasts failed when the workflow errors" do
      ws = github_ws("er-events-2")

      Req.Test.stub(Arbiter.Mergers.Github.HTTP, fn conn ->
        conn
        |> Plug.Conn.put_resp_header("content-type", "application/json")
        |> Plug.Conn.resp(500, Jason.encode!(%{"message" => "boom"}))
      end)

      :ok = Phoenix.PubSub.subscribe(Arbiter.PubSub, Arbiter.Events.pubsub_topic(ws.id))

      assert {:error, _} =
               ExternalReview.review(pr: "octo/widget#42", workspace: ws.name, follow_up: false)

      assert_receive {:event, %{topic: "external_review", status: "running"}}
      assert_receive {:event, %{topic: "external_review", status: "failed"} = failed}
      assert failed.pr_ref == "octo/widget#42"
      assert is_nil(failed.verdict)
    end
  end

  describe "review/1 — report_only (propose) mode (bd-36qzgx)" do
    setup do
      System.put_env(@env_var, "test-token")
      on_exit(fn -> System.delete_env(@env_var) end)
      :ok
    end

    test "reviews fully but makes ZERO writes to the PR, capturing proposed comments" do
      ws = github_ws("er-ro-zero")
      events = :ets.new(:ro_events, [:public, :duplicate_bag])
      stub_report_only(events, head_sha: "sha-ro", author: "coworker")

      runner = fn _diff, _state ->
        {:ok,
         [
           %{severity: :error, file: "x.ex", line: 1, message: "boom"},
           %{severity: :warning, file: "y.ex", line: 2, message: "nit"}
         ]}
      end

      assert {:ok, result} =
               ExternalReview.review(
                 pr: "octo/widget#42",
                 workspace: ws.name,
                 automation: "report_only",
                 follow_up: false,
                 check_runner: runner
               )

      assert result.report_only == true
      assert result.mode == :report_only
      assert result.verdict == :request_changes
      # Proposed comments captured, with rendered body text.
      assert [c0, c1] = result.proposed_comments
      assert c0.file == "x.ex" and c0.body == "**ERROR**: boom"
      assert c1.file == "y.ex" and c1.body == "**WARNING**: nit"

      # The hard invariant: nothing posted / submitted to the PR.
      assert :ets.lookup(events, :comment) == []
      assert :ets.lookup(events, :review) == []
    end

    test "persists a report_only record with proposed comments + pending greenlight" do
      ws = github_ws("er-ro-rec")
      events = :ets.new(:ro_rec_events, [:public, :duplicate_bag])
      stub_report_only(events, head_sha: "sha-ro2", author: "coworker")

      assert {:ok, _} =
               ExternalReview.review(
                 pr: "octo/widget#42",
                 workspace: ws.name,
                 automation: "report_only",
                 follow_up: false,
                 check_runner: one_finding()
               )

      [rec] = records_for(ws.id, "octo/widget#42")
      assert rec.mode == :report_only
      assert rec.greenlight_status == :pending
      assert rec.verdict == :request_changes
      assert [pc] = rec.proposed_comments
      assert pc["file"] == "x.ex"
      assert pc["body"] == "**ERROR**: boom"
    end

    test "notifies the coordinator mailbox with the proposed comments" do
      ws = github_ws("er-ro-mail")
      events = :ets.new(:ro_mail_events, [:public, :duplicate_bag])
      stub_report_only(events, head_sha: "sha-ro3", author: "coworker")

      assert {:ok, _} =
               ExternalReview.review(
                 pr: "octo/widget#42",
                 workspace: ws.name,
                 automation: "report_only",
                 follow_up: false,
                 check_runner: one_finding()
               )

      msgs =
        Arbiter.Messages.Message
        |> Ash.Query.filter(to_ref == "coordinator" and workspace_id == ^ws.id)
        |> Ash.read!()

      assert Enum.any?(msgs, fn m ->
               m.subject =~ "Report-only review" and m.body =~ "**ERROR**: boom"
             end)
    end

    test "greenlight posts exactly the selected subset and flips greenlight_status" do
      ws = github_ws("er-gl-subset")
      events = :ets.new(:gl_events, [:public, :duplicate_bag])
      stub_report_only(events, head_sha: "sha-gl", author: "coworker")

      runner = fn _diff, _state ->
        {:ok,
         [
           %{severity: :error, file: "a.ex", line: 1, message: "one"},
           %{severity: :warning, file: "b.ex", line: 2, message: "two"},
           %{severity: :info, file: "c.ex", line: 3, message: "three"}
         ]}
      end

      assert {:ok, _} =
               ExternalReview.review(
                 pr: "octo/widget#42",
                 workspace: ws.name,
                 automation: "report_only",
                 follow_up: false,
                 check_runner: runner
               )

      [rec] = records_for(ws.id, "octo/widget#42")
      assert :ets.lookup(events, :comment) == []

      # Greenlight only comments #0 and #2.
      assert {:ok, gl} = ExternalReview.greenlight(record_id: rec.id, select: [0, 2])
      assert gl.posted == 2
      assert gl.selected == 2

      posted = :ets.lookup(events, :comment) |> Enum.map(fn {:comment, p} -> p["path"] end)
      assert Enum.sort(posted) == ["a.ex", "c.ex"]
      refute "b.ex" in posted

      # A verdict review was also submitted (default when ≥1 comment approved).
      assert [_] = :ets.lookup(events, :review)

      reloaded = Ash.get!(Record, rec.id)
      assert reloaded.greenlight_status == :posted
    end

    test "greenlight with an empty selection posts nothing (true no-op) and records :none" do
      ws = github_ws("er-gl-none")
      events = :ets.new(:gl_none_events, [:public, :duplicate_bag])
      stub_report_only(events, head_sha: "sha-gln", author: "coworker")

      assert {:ok, _} =
               ExternalReview.review(
                 pr: "octo/widget#42",
                 workspace: ws.name,
                 automation: "report_only",
                 follow_up: false,
                 check_runner: one_finding()
               )

      [rec] = records_for(ws.id, "octo/widget#42")

      assert {:ok, gl} = ExternalReview.greenlight(record_id: rec.id, select: [])
      assert gl.posted == 0

      assert :ets.lookup(events, :comment) == []
      assert :ets.lookup(events, :review) == []

      reloaded = Ash.get!(Record, rec.id)
      assert reloaded.greenlight_status == :none
    end

    test "a report_only follow-up engagement is created in :report_only mode" do
      ws = github_ws("er-ro-eng")
      events = :ets.new(:ro_eng_events, [:public, :duplicate_bag])
      stub_report_only(events, head_sha: "sha-eng", author: "coworker", max_comment_id: 7)

      assert {:ok, result} =
               ExternalReview.review(
                 pr: "octo/widget#42",
                 workspace: ws.name,
                 automation: "report_only",
                 follow_up: true,
                 check_runner: one_finding()
               )

      engagement = Ash.get!(Issue, result.engagement)
      assert engagement.review_automation == :report_only
    end

    # bd-887swr: the greenlight path had no DiffScope check at all — a selected
    # comment whose (path, line) isn't in the diff 422s and `{:halt, err}`
    # aborts every remaining comment. These tests cover the fix.

    test "proposed comments are labeled in_diff at report_only time" do
      ws = github_ws("er-ro-label")
      events = :ets.new(:ro_label_events, [:public, :duplicate_bag])
      stub_report_only(events, head_sha: "sha-label", author: "coworker")

      runner = fn _diff, _state ->
        {:ok,
         [
           %{severity: :error, file: "x.ex", line: 1, message: "in diff"},
           %{severity: :warning, file: "nope.ex", line: 5, message: "not in diff"}
         ]}
      end

      assert {:ok, _} =
               ExternalReview.review(
                 pr: "octo/widget#42",
                 workspace: ws.name,
                 automation: "report_only",
                 follow_up: false,
                 check_runner: runner
               )

      [rec] = records_for(ws.id, "octo/widget#42")
      assert [pc0, pc1] = rec.proposed_comments
      assert pc0["file"] == "x.ex" and pc0["in_diff"] == true
      assert pc1["file"] == "nope.ex" and pc1["in_diff"] == false
    end

    test "greenlight select: all posts the in-diff subset, skips the out-of-diff one, and still submits the verdict" do
      ws = github_ws("er-gl-mixed")
      events = :ets.new(:gl_mixed_events, [:public, :duplicate_bag])
      stub_report_only(events, head_sha: "sha-mixed", author: "coworker")

      runner = fn _diff, _state ->
        {:ok,
         [
           %{severity: :error, file: "x.ex", line: 1, message: "in diff"},
           %{severity: :warning, file: "nope.ex", line: 5, message: "not in diff"}
         ]}
      end

      assert {:ok, _} =
               ExternalReview.review(
                 pr: "octo/widget#42",
                 workspace: ws.name,
                 automation: "report_only",
                 follow_up: false,
                 check_runner: runner
               )

      [rec] = records_for(ws.id, "octo/widget#42")

      assert {:ok, gl} = ExternalReview.greenlight(record_id: rec.id, select: "all")

      # The in-diff comment posted; the out-of-diff one was skipped, not
      # attempted — and it did NOT halt/abort the batch.
      assert gl.posted == 1
      assert gl.selected == 2
      assert gl.skipped == 1
      assert gl.verdict_posted == true

      posted_files = :ets.lookup(events, :comment) |> Enum.map(fn {:comment, p} -> p["path"] end)
      assert posted_files == ["x.ex"]

      # The verdict still posted (a review), and its body surfaces the
      # skipped comment rather than silently dropping it.
      assert [{:review, review}] = :ets.lookup(events, :review)
      assert review["body"] =~ "1 finding(s) posted"
      assert review["body"] =~ "nope.ex:5"

      reloaded = Ash.get!(Record, rec.id)
      assert reloaded.greenlight_status == :posted
    end

    test "an adapter error on a middle comment does not prevent later comments from posting" do
      ws = github_ws("er-gl-midfail")
      events = :ets.new(:gl_midfail_events, [:public, :duplicate_bag])

      stub_report_only_with_post_failure(events,
        head_sha: "sha-midfail",
        author: "coworker",
        fail_path: "y.ex"
      )

      runner = fn _diff, _state ->
        {:ok,
         [
           %{severity: :error, file: "x.ex", line: 1, message: "one"},
           %{severity: :warning, file: "y.ex", line: 2, message: "two — this post 500s"},
           %{severity: :info, file: "a.ex", line: 1, message: "three"}
         ]}
      end

      assert {:ok, _} =
               ExternalReview.review(
                 pr: "octo/widget#42",
                 workspace: ws.name,
                 automation: "report_only",
                 follow_up: false,
                 check_runner: runner
               )

      [rec] = records_for(ws.id, "octo/widget#42")

      assert {:ok, gl} = ExternalReview.greenlight(record_id: rec.id, select: "all")

      # x.ex and a.ex posted despite y.ex (the middle comment) failing — no halt.
      assert gl.posted == 2
      assert gl.skipped == 1

      posted_files = :ets.lookup(events, :comment) |> Enum.map(fn {:comment, p} -> p["path"] end)
      assert Enum.sort(posted_files) == ["a.ex", "x.ex"]
      refute "y.ex" in posted_files

      # The verdict still posted, once, after every comment was attempted.
      assert [_] = :ets.lookup(events, :review)
    end

    test "the greenlight verdict summary reports the posted count, not the proposed count" do
      ws = github_ws("er-gl-count")
      events = :ets.new(:gl_count_events, [:public, :duplicate_bag])
      stub_report_only(events, head_sha: "sha-count", author: "coworker")

      runner = fn _diff, _state ->
        {:ok,
         [
           %{severity: :error, file: "a.ex", line: 1, message: "one"},
           %{severity: :warning, file: "b.ex", line: 2, message: "two"},
           %{severity: :info, file: "c.ex", line: 3, message: "three"}
         ]}
      end

      assert {:ok, _} =
               ExternalReview.review(
                 pr: "octo/widget#42",
                 workspace: ws.name,
                 automation: "report_only",
                 follow_up: false,
                 check_runner: runner
               )

      [rec] = records_for(ws.id, "octo/widget#42")
      assert rec.finding_count == 3

      # Greenlight only #0 and #2 (2 of the 3 proposed).
      assert {:ok, gl} = ExternalReview.greenlight(record_id: rec.id, select: [0, 2])
      assert gl.posted == 2

      assert [{:review, review}] = :ets.lookup(events, :review)
      assert review["body"] =~ "2 finding(s) posted"
      refute review["body"] =~ "3 finding(s)"
    end
  end

  # A check runner that always reports one finding (so a request_changes verdict
  # posts a comment + a review, matching the real review path).
  defp one_finding do
    fn _diff, _state ->
      {:ok, [%{severity: :error, file: "x.ex", line: 1, message: "boom"}]}
    end
  end

  defp engagements_for(ws_id, mr_ref) do
    Issue
    |> Ash.Query.filter(
      review_only == true and source_pr == ^mr_ref and status != :closed and
        workspace_id == ^ws_id
    )
    |> Ash.read!()
  end

  defp records_for(ws_id, pr_ref) do
    Record
    |> Ash.Query.filter(workspace_id == ^ws_id and pr_ref == ^pr_ref)
    |> Ash.read!()
  end

  # Stub every GitHub endpoint the review + engagement baseline touch:
  #   * diff GET (CodeReview reads the diff)
  #   * JSON pull GET (baseline head sha + author)
  #   * POST comments / POST reviews (the posted finding + verdict)
  #   * GET reviews, GET check-runs (adapter.get/1 internals)
  #   * POST /graphql (list_open_review_threads → comment high-watermark)
  defp stub_full_review(opts) do
    head_sha = Keyword.fetch!(opts, :head_sha)
    author = Keyword.get(opts, :author, "coworker")
    max_comment_id = Keyword.get(opts, :max_comment_id, 1)

    Req.Test.stub(Arbiter.Mergers.Github.HTTP, fn conn ->
      path = conn.request_path
      diff? = "application/vnd.github.v3.diff" in Plug.Conn.get_req_header(conn, "accept")

      cond do
        conn.method == "GET" and path == "/repos/octo/widget/pulls/42" and diff? ->
          conn
          |> Plug.Conn.put_resp_header("content-type", "text/plain")
          |> Plug.Conn.resp(
            200,
            "diff --git a/x.ex b/x.ex\n--- a/x.ex\n+++ b/x.ex\n@@ -0,0 +1 @@\n+boom\n"
          )

        conn.method == "GET" and path == "/repos/octo/widget/pulls/42" ->
          json(conn, %{
            "number" => 42,
            "state" => "open",
            "head" => %{"sha" => head_sha},
            "user" => %{"login" => author},
            "html_url" => "https://github.com/octo/widget/pull/42",
            "title" => Keyword.get(opts, :pr_title, "Fix widget overflow"),
            "body" => Keyword.get(opts, :pr_body, "Closes #42 by clamping the widget height.")
          })

        conn.method == "GET" and path == "/repos/octo/widget/pulls/42/reviews" ->
          json(conn, [])

        conn.method == "GET" and path =~ ~r{/commits/.+/check-runs$} ->
          json(conn, %{"check_runs" => []})

        conn.method == "POST" and path == "/repos/octo/widget/pulls/42/comments" ->
          json(conn, %{"id" => 1})

        conn.method == "POST" and path == "/repos/octo/widget/pulls/42/reviews" ->
          json(conn, %{"id" => 99})

        conn.method == "POST" and path == "/graphql" ->
          json(conn, %{
            "data" => %{
              "repository" => %{
                "pullRequest" => %{
                  "reviewThreads" => %{
                    "nodes" => [
                      %{
                        "id" => "T1",
                        "isResolved" => false,
                        "path" => "x.ex",
                        "line" => 1,
                        "comments" => %{
                          "nodes" => [
                            %{
                              "databaseId" => max_comment_id,
                              "author" => %{"login" => author},
                              "body" => "please look"
                            }
                          ]
                        }
                      }
                    ]
                  }
                }
              }
            }
          })

        true ->
          conn
          |> Plug.Conn.put_resp_header("content-type", "application/json")
          |> Plug.Conn.resp(
            404,
            Jason.encode!(%{"message" => "unhandled #{conn.method} #{path}"})
          )
      end
    end)
  end

  # Like stub_full_review but records every POST comment / POST review into
  # `events` so a report-only test can assert ZERO writes, and a greenlight test
  # can assert exactly the approved subset posted.
  # Diff covering every file the report_only/greenlight tests reference
  # (bd-887swr: greenlight now diff-scopes against the *current* diff, so the
  # stub must actually cover each test's proposed-comment files/lines).
  defp report_only_diff do
    "diff --git a/x.ex b/x.ex\n--- a/x.ex\n+++ b/x.ex\n@@ -0,0 +1 @@\n+boom\n" <>
      "diff --git a/y.ex b/y.ex\n--- a/y.ex\n+++ b/y.ex\n@@ -0,0 +1,2 @@\n+one\n+two\n" <>
      "diff --git a/a.ex b/a.ex\n--- a/a.ex\n+++ b/a.ex\n@@ -0,0 +1 @@\n+one\n" <>
      "diff --git a/b.ex b/b.ex\n--- a/b.ex\n+++ b/b.ex\n@@ -0,0 +1,2 @@\n+one\n+two\n" <>
      "diff --git a/c.ex b/c.ex\n--- a/c.ex\n+++ b/c.ex\n@@ -0,0 +1,3 @@\n+one\n+two\n+three\n"
  end

  # Like stub_report_only, but parametrized over owner/repo/number/head_sha so a
  # test can dispatch against an arbitrary repo (bd-7opdaf Part 1 regression) —
  # stub_report_only itself only ever answers for "octo/widget#42".
  defp stub_report_only_for(events, owner, repo, number, head_sha) do
    prefix = "/repos/#{owner}/#{repo}/pulls/#{number}"

    Req.Test.stub(Arbiter.Mergers.Github.HTTP, fn conn ->
      path = conn.request_path
      diff? = "application/vnd.github.v3.diff" in Plug.Conn.get_req_header(conn, "accept")

      cond do
        conn.method == "GET" and path == prefix and diff? ->
          conn
          |> Plug.Conn.put_resp_header("content-type", "text/plain")
          |> Plug.Conn.resp(200, report_only_diff())

        conn.method == "GET" and path == prefix ->
          json(conn, %{
            "number" => number,
            "state" => "open",
            "head" => %{"sha" => head_sha},
            "user" => %{"login" => "coworker"},
            "html_url" => "https://github.com/#{owner}/#{repo}/pull/#{number}"
          })

        conn.method == "GET" and path == "#{prefix}/reviews" ->
          json(conn, [])

        conn.method == "GET" and path =~ ~r{/commits/.+/check-runs$} ->
          json(conn, %{"check_runs" => []})

        conn.method == "POST" and path == "#{prefix}/comments" ->
          {:ok, body, conn} = Plug.Conn.read_body(conn)
          :ets.insert(events, {:comment, Jason.decode!(body)})
          json(conn, %{"id" => :rand.uniform(100_000)})

        conn.method == "POST" and path == "#{prefix}/reviews" ->
          {:ok, body, conn} = Plug.Conn.read_body(conn)
          :ets.insert(events, {:review, Jason.decode!(body)})
          json(conn, %{"id" => 99})

        true ->
          conn
          |> Plug.Conn.put_resp_header("content-type", "application/json")
          |> Plug.Conn.resp(
            404,
            Jason.encode!(%{"message" => "unhandled #{conn.method} #{path}"})
          )
      end
    end)
  end

  defp stub_report_only(events, opts) do
    head_sha = Keyword.fetch!(opts, :head_sha)
    author = Keyword.get(opts, :author, "coworker")
    max_comment_id = Keyword.get(opts, :max_comment_id, 1)

    Req.Test.stub(Arbiter.Mergers.Github.HTTP, fn conn ->
      path = conn.request_path
      diff? = "application/vnd.github.v3.diff" in Plug.Conn.get_req_header(conn, "accept")

      cond do
        conn.method == "GET" and path == "/repos/octo/widget/pulls/42" and diff? ->
          conn
          |> Plug.Conn.put_resp_header("content-type", "text/plain")
          |> Plug.Conn.resp(200, report_only_diff())

        conn.method == "GET" and path == "/repos/octo/widget/pulls/42" ->
          json(conn, %{
            "number" => 42,
            "state" => "open",
            "head" => %{"sha" => head_sha},
            "user" => %{"login" => author},
            "html_url" => "https://github.com/octo/widget/pull/42"
          })

        conn.method == "GET" and path == "/repos/octo/widget/pulls/42/reviews" ->
          json(conn, [])

        conn.method == "GET" and path =~ ~r{/commits/.+/check-runs$} ->
          json(conn, %{"check_runs" => []})

        conn.method == "POST" and path == "/repos/octo/widget/pulls/42/comments" ->
          {:ok, body, conn} = Plug.Conn.read_body(conn)
          :ets.insert(events, {:comment, Jason.decode!(body)})
          json(conn, %{"id" => :rand.uniform(100_000)})

        conn.method == "POST" and path == "/repos/octo/widget/pulls/42/reviews" ->
          {:ok, body, conn} = Plug.Conn.read_body(conn)
          :ets.insert(events, {:review, Jason.decode!(body)})
          json(conn, %{"id" => 99})

        conn.method == "POST" and path == "/graphql" ->
          json(conn, %{
            "data" => %{
              "repository" => %{
                "pullRequest" => %{
                  "reviewThreads" => %{
                    "nodes" => [
                      %{
                        "id" => "T1",
                        "isResolved" => false,
                        "path" => "x.ex",
                        "line" => 1,
                        "comments" => %{
                          "nodes" => [
                            %{
                              "databaseId" => max_comment_id,
                              "author" => %{"login" => author},
                              "body" => "please look"
                            }
                          ]
                        }
                      }
                    ]
                  }
                }
              }
            }
          })

        true ->
          conn
          |> Plug.Conn.put_resp_header("content-type", "application/json")
          |> Plug.Conn.resp(
            404,
            Jason.encode!(%{"message" => "unhandled #{conn.method} #{path}"})
          )
      end
    end)
  end

  # Like stub_report_only, but the inline-comment POST 500s for one specific
  # file path (`opts[:fail_path]`) and succeeds (recording into `events`) for
  # every other — so a test can prove a mid-batch adapter error doesn't halt
  # posting of the comments after it (bd-887swr).
  defp stub_report_only_with_post_failure(events, opts) do
    head_sha = Keyword.fetch!(opts, :head_sha)
    author = Keyword.get(opts, :author, "coworker")
    fail_path = Keyword.fetch!(opts, :fail_path)
    max_comment_id = Keyword.get(opts, :max_comment_id, 1)

    Req.Test.stub(Arbiter.Mergers.Github.HTTP, fn conn ->
      path = conn.request_path
      diff? = "application/vnd.github.v3.diff" in Plug.Conn.get_req_header(conn, "accept")

      cond do
        conn.method == "GET" and path == "/repos/octo/widget/pulls/42" and diff? ->
          conn
          |> Plug.Conn.put_resp_header("content-type", "text/plain")
          |> Plug.Conn.resp(200, report_only_diff())

        conn.method == "GET" and path == "/repos/octo/widget/pulls/42" ->
          json(conn, %{
            "number" => 42,
            "state" => "open",
            "head" => %{"sha" => head_sha},
            "user" => %{"login" => author},
            "html_url" => "https://github.com/octo/widget/pull/42"
          })

        conn.method == "GET" and path == "/repos/octo/widget/pulls/42/reviews" ->
          json(conn, [])

        conn.method == "GET" and path =~ ~r{/commits/.+/check-runs$} ->
          json(conn, %{"check_runs" => []})

        conn.method == "POST" and path == "/repos/octo/widget/pulls/42/comments" ->
          {:ok, raw, conn} = Plug.Conn.read_body(conn)
          decoded = Jason.decode!(raw)

          if decoded["path"] == fail_path do
            conn
            |> Plug.Conn.put_resp_header("content-type", "application/json")
            |> Plug.Conn.resp(500, Jason.encode!(%{"message" => "internal error"}))
          else
            :ets.insert(events, {:comment, decoded})
            json(conn, %{"id" => :rand.uniform(100_000)})
          end

        conn.method == "POST" and path == "/repos/octo/widget/pulls/42/reviews" ->
          {:ok, body, conn} = Plug.Conn.read_body(conn)
          :ets.insert(events, {:review, Jason.decode!(body)})
          json(conn, %{"id" => 99})

        conn.method == "POST" and path == "/graphql" ->
          json(conn, %{
            "data" => %{
              "repository" => %{
                "pullRequest" => %{
                  "reviewThreads" => %{
                    "nodes" => [
                      %{
                        "id" => "T1",
                        "isResolved" => false,
                        "path" => "x.ex",
                        "line" => 1,
                        "comments" => %{
                          "nodes" => [
                            %{
                              "databaseId" => max_comment_id,
                              "author" => %{"login" => author},
                              "body" => "please look"
                            }
                          ]
                        }
                      }
                    ]
                  }
                }
              }
            }
          })

        true ->
          conn
          |> Plug.Conn.put_resp_header("content-type", "application/json")
          |> Plug.Conn.resp(
            404,
            Jason.encode!(%{"message" => "unhandled #{conn.method} #{path}"})
          )
      end
    end)
  end

  describe "self-approve guard (bd-7z5pi5)" do
    setup do
      System.put_env(@env_var, "test-token")
      on_exit(fn -> System.delete_env(@env_var) end)
      :ok
    end

    test "review/1 refuses a PR this identity has already approved" do
      github_ws("er-guard-block")
      stub_review_flow("arb-bot", "APPROVED")

      assert {:error, {:already_approved, "octo/widget#42"}} =
               ExternalReview.review(pr: "octo/widget#42")
    end

    test "dispatch/1 refuses a PR this identity has already approved" do
      github_ws("er-guard-block-dispatch")
      stub_review_flow("arb-bot", "APPROVED")

      assert {:error, {:already_approved, "octo/widget#42"}} =
               ExternalReview.dispatch(pr: "octo/widget#42")
    end

    test "proceeds when our latest verdict is not an approval (guard fails through)" do
      github_ws("er-guard-open")
      stub_review_flow("arb-bot", "CHANGES_REQUESTED")
      runner = fn _diff, _state -> {:ok, []} end

      assert {:ok, %{mr_ref: "octo/widget#42", verdict: _}} =
               ExternalReview.review(pr: "octo/widget#42", check_runner: runner)
    end

    test "force: true runs the review despite an existing self-approval" do
      github_ws("er-guard-force")
      stub_review_flow("arb-bot", "APPROVED")
      runner = fn _diff, _state -> {:ok, []} end

      assert {:ok, %{mr_ref: "octo/widget#42", verdict: _}} =
               ExternalReview.review(pr: "octo/widget#42", force: true, check_runner: runner)
    end
  end

  describe "prepare/1 — rig_name resolution from the pr slug (bd-7opdaf Part 1)" do
    test "derives rig_name from an owner/repo#N slug when repo: is omitted" do
      ws = github_ws("er-rig-slug")

      assert {:ok, prepared} =
               ExternalReview.prepare(
                 pr: "leo-technologies-llc/voice_biometrics#450",
                 workspace: ws.name
               )

      assert prepared.rig_name == "voice_biometrics"
    end

    test "derives rig_name from a full forge URL when repo: is omitted" do
      ws = github_ws("er-rig-url")

      assert {:ok, prepared} =
               ExternalReview.prepare(
                 pr: "https://github.com/leo-technologies-llc/atlas/pull/1549",
                 workspace: ws.name
               )

      assert prepared.rig_name == "atlas"
    end

    test "an explicit repo: arg still wins over the parsed pr slug" do
      ws = github_ws("er-rig-explicit")

      assert {:ok, prepared} =
               ExternalReview.prepare(
                 pr: "leo-technologies-llc/voice_biometrics#450",
                 repo: "explicit_repo",
                 workspace: ws.name
               )

      assert prepared.rig_name == "explicit_repo"
    end

    test "rig_name is nil for a bare PR number with no repo: or checkout" do
      ws = github_ws("er-rig-bare")

      assert {:ok, prepared} = ExternalReview.prepare(pr: "42", workspace: ws.name)
      assert prepared.rig_name == nil
    end
  end

  describe "dispatch/1 — repo_overrides resolved on the pr: path (bd-7opdaf Part 1 regression)" do
    setup do
      System.put_env(@env_var, "test-token")
      on_exit(fn -> System.delete_env(@env_var) end)
      :ok
    end

    test "every configured repo_overrides entry resolves to its own mode when repo: is omitted" do
      {:ok, ws} =
        Ash.create(Workspace, %{
          name: "ra-multi-repo-ws",
          prefix: uniq_prefix(),
          config: %{
            "merge" => %{"strategy" => "github", "config" => %{}},
            "review_automation" => %{
              "default" => "auto",
              "repo_overrides" => %{
                "atlas" => "report_only",
                "voice_biometrics" => "report_only",
                "fast_lane" => "auto",
                "watched_repo" => "flag"
              }
            }
          }
        })

      for {repo, expected_mode} <- [
            {"atlas", :report_only},
            {"voice_biometrics", :report_only},
            {"fast_lane", :auto},
            {"watched_repo", :auto}
          ] do
        # `pr:` is a fully-qualified "owner/repo#N" slug with NO explicit `repo:`
        # arg — exactly the shape that silently fell back to :auto before the fix,
        # regardless of what repo_overrides said (bd-7opdaf).
        assert {:ok, ack} =
                 ExternalReview.dispatch(
                   pr: "leo-technologies-llc/#{repo}#1",
                   workspace: ws.name
                 )

        assert ack.mode == expected_mode,
               "expected #{repo} to resolve to #{inspect(expected_mode)}, got #{inspect(ack.mode)}"
      end
    end

    test "a report_only repo can never post to the PR via the pr: path" do
      {:ok, ws} =
        Ash.create(Workspace, %{
          name: "ra-report-only-guard-ws",
          prefix: uniq_prefix(),
          config: %{
            "merge" => %{
              "strategy" => "github",
              "config" => %{"credentials_ref" => "env:#{@env_var}"}
            },
            "review_automation" => %{
              "default" => "auto",
              "repo_overrides" => %{"voice_biometrics" => "report_only"}
            }
          }
        })

      events = :ets.new(:ro_guard_events, [:public, :duplicate_bag])
      stub_report_only_for(events, "leo-technologies-llc", "voice_biometrics", 1, "sha-guard")

      assert {:ok, result} =
               ExternalReview.review(
                 pr: "leo-technologies-llc/voice_biometrics#1",
                 workspace: ws.name,
                 check_runner: one_finding()
               )

      assert result.mode == :report_only
      assert result.report_only == true
      assert :ets.lookup(events, :comment) == []
      assert :ets.lookup(events, :review) == []
    end
  end

  describe "automation :off guard (bd-7opdaf Part 2)" do
    setup do
      System.put_env(@env_var, "test-token")
      on_exit(fn -> System.delete_env(@env_var) end)
      :ok
    end

    test "dispatch/1 refuses an off-gated repo_override before spawning anything" do
      {:ok, ws} =
        Ash.create(Workspace, %{
          name: "ra-off-repo-ws",
          prefix: uniq_prefix(),
          config: %{
            "merge" => %{"strategy" => "github", "config" => %{}},
            "review_automation" => %{
              "default" => "auto",
              "repo_overrides" => %{"quiet_repo" => "off"}
            }
          }
        })

      assert {:error, {:automation_off, "quiet_repo", :repo_override}} =
               ExternalReview.dispatch(
                 pr: "leo-technologies-llc/quiet_repo#1",
                 workspace: ws.name
               )

      assert [] = records_for(ws.id, "leo-technologies-llc/quiet_repo#1")
    end

    test "review/1 refuses an off-gated repo_override before spawning anything" do
      {:ok, ws} =
        Ash.create(Workspace, %{
          name: "ra-off-repo-ws2",
          prefix: uniq_prefix(),
          config: %{
            "merge" => %{"strategy" => "github", "config" => %{}},
            "review_automation" => %{
              "default" => "auto",
              "repo_overrides" => %{"quiet_repo" => "off"}
            }
          }
        })

      assert {:error, {:automation_off, "quiet_repo", :repo_override}} =
               ExternalReview.review(pr: "leo-technologies-llc/quiet_repo#1", workspace: ws.name)
    end

    test "a workspace default of off refuses every repo" do
      {:ok, ws} =
        Ash.create(Workspace, %{
          name: "ra-off-default-ws",
          prefix: uniq_prefix(),
          config: %{
            "merge" => %{"strategy" => "github", "config" => %{}},
            "review_automation" => %{"default" => "off"}
          }
        })

      # A bare PR number with no repo:/repo_paths — rig_name genuinely can't be
      # resolved, so the default applies with no repo name to report.
      assert {:error, {:automation_off, nil, :default}} =
               ExternalReview.dispatch(pr: "1", workspace: ws.name)
    end

    test "an explicit automation: \"off\" argument refuses even an :auto policy" do
      ws = github_ws("er-off-explicit")

      assert {:error, {:automation_off, "widget", :explicit}} =
               ExternalReview.dispatch(pr: "octo/widget#1", automation: "off", workspace: ws.name)
    end

    test "force: true overrides the off refusal, mirroring the self-approve guard" do
      {:ok, ws} =
        Ash.create(Workspace, %{
          name: "ra-off-force-ws",
          prefix: uniq_prefix(),
          config: %{
            "merge" => %{"strategy" => "github", "config" => %{}},
            "review_automation" => %{
              "default" => "auto",
              "repo_overrides" => %{"quiet_repo" => "off"}
            }
          }
        })

      assert {:ok, ack} =
               ExternalReview.dispatch(
                 pr: "leo-technologies-llc/quiet_repo#1",
                 workspace: ws.name,
                 force: true
               )

      assert ack.status == "dispatched"
    end

    test "describe_error names the repo and the config key responsible" do
      msg =
        ExternalReview.describe_error({:automation_off, "voice_biometrics", :repo_override})

      assert msg =~ "voice_biometrics"
      assert msg =~ "repo_overrides"
      assert msg =~ "force: true"
    end
  end

  # Full GitHub stub for a review-flow test: the guard's identity (`/user`) +
  # reviews lookups (self_login leaving `self_state`), plus the diff / comment /
  # verdict endpoints the CodeReview workflow drives. Unhandled paths → 404.
  defp stub_review_flow(self_login, self_state) do
    Req.Test.stub(Arbiter.Mergers.Github.HTTP, fn conn ->
      path = conn.request_path

      cond do
        conn.method == "GET" and path == "/user" ->
          json(conn, %{"login" => self_login})

        conn.method == "GET" and path == "/repos/octo/widget/pulls/42/reviews" ->
          json(conn, [%{"user" => %{"login" => self_login}, "state" => self_state}])

        conn.method == "GET" and path == "/repos/octo/widget/pulls/42" and
            "application/vnd.github.v3.diff" in Plug.Conn.get_req_header(conn, "accept") ->
          conn
          |> Plug.Conn.put_resp_content_type("text/plain")
          |> Plug.Conn.resp(
            200,
            "diff --git a/x.ex b/x.ex\n--- a/x.ex\n+++ b/x.ex\n@@ -0,0 +1 @@\n+boom\n"
          )

        conn.method == "GET" and path == "/repos/octo/widget/pulls/42" ->
          json(conn, %{"number" => 42, "head" => %{"sha" => "abc"}, "base" => %{"ref" => "main"}})

        conn.method == "POST" and path == "/repos/octo/widget/pulls/42/comments" ->
          conn |> Plug.Conn.put_status(201) |> Req.Test.json(%{"id" => 1})

        conn.method == "POST" and path == "/repos/octo/widget/pulls/42/reviews" ->
          json(conn, %{"id" => 99})

        true ->
          conn
          |> Plug.Conn.put_resp_header("content-type", "application/json")
          |> Plug.Conn.resp(
            404,
            Jason.encode!(%{"message" => "unhandled #{conn.method} #{path}"})
          )
      end
    end)
  end

  describe "failure tracking — bd-7rspia" do
    test "stores failure_stage and failure_reason when a record is created with failure info" do
      ws = github_ws("er-fail-stage-reason")

      {:ok, record} =
        Ash.create(Record, %{
          pr_ref: "test/repo#1",
          pr: "1",
          workspace_id: ws.id,
          strategy: "github",
          status: :failed,
          failure_stage: "read_diff",
          failure_reason: "forbidden: insufficient permissions",
          started_at: DateTime.utc_now()
        })

      assert record.status == :failed
      assert record.failure_stage == "read_diff"
      assert record.failure_reason == "forbidden: insufficient permissions"
    end

    test "stores failure_stage and failure_reason for file_findings failures" do
      ws = github_ws("er-fail-file-findings")

      {:ok, record} =
        Ash.create(Record, %{
          pr_ref: "test/repo#2",
          pr: "2",
          workspace_id: ws.id,
          strategy: "github",
          status: :completed_unposted,
          failure_stage: "file_findings",
          failure_reason: "forbidden 403: rate limited",
          started_at: DateTime.utc_now(),
          completed_at: DateTime.utc_now()
        })

      assert record.status == :completed_unposted
      assert record.failure_stage == "file_findings"
      assert record.failure_reason == "forbidden 403: rate limited"
    end

    test "allows nil failure fields when review succeeds" do
      ws = github_ws("er-success-no-failure")

      {:ok, record} =
        Ash.create(Record, %{
          pr_ref: "test/repo#3",
          pr: "3",
          workspace_id: ws.id,
          strategy: "github",
          status: :completed,
          verdict: :approve,
          started_at: DateTime.utc_now(),
          completed_at: DateTime.utc_now()
        })

      assert record.status == :completed
      assert is_nil(record.failure_stage)
      assert is_nil(record.failure_reason)
    end
  end

  # bd-7rspia: exercise the real MCP serializer (`Arbiter.MCP.Tools`), not a
  # test-local copy — the REST equivalent lives in
  # ArbiterWeb.Api.ExternalReviewControllerTest, alongside the real controller.
  describe "MCP serialization — failure fields (bd-7rspia)" do
    test "external_review_list and external_review_show include failure_stage and failure_reason" do
      ws = github_ws("er-mcp-failure-fields")

      {:ok, record} =
        Ash.create(Record, %{
          pr_ref: "test/repo#4",
          pr: "4",
          workspace_id: ws.id,
          strategy: "github",
          status: :failed,
          failure_stage: "read_diff",
          failure_reason: "connection timeout",
          started_at: DateTime.utc_now()
        })

      scope = %Arbiter.MCP.Scope{tier: :coordinator, workspace_id: ws.id, can_dispatch: true}

      assert {:ok, %{external_reviews: [listed]}} =
               Arbiter.MCP.Tools.external_review_list(scope, %{})

      assert listed.failure_stage == "read_diff"
      assert listed.failure_reason == "connection timeout"

      assert {:ok, shown} =
               Arbiter.MCP.Tools.external_review_show(scope, %{"record_id" => record.id})

      assert shown.failure_stage == "read_diff"
      assert shown.failure_reason == "connection timeout"
    end
  end

  defp json(conn, body) do
    conn
    |> Plug.Conn.put_resp_header("content-type", "application/json")
    |> Plug.Conn.resp(200, Jason.encode!(body))
  end

  defp tmp_git_repo(origin_url) do
    dir = Path.join(System.tmp_dir!(), "er-ref-#{:erlang.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    {_, 0} = System.cmd("git", ["init", "-q", dir])
    {_, 0} = System.cmd("git", ["-C", dir, "remote", "add", "origin", origin_url])
    on_exit(fn -> File.rm_rf!(dir) end)
    dir
  end
end
