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
            |> Plug.Conn.resp(200, "diff --git a/x.ex b/x.ex\n+boom\n")

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
              message: "call site of changed function `#{ref.identifier}` — verify it still matches"
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
          |> Plug.Conn.resp(200, "diff --git a/x.ex b/x.ex\n+boom\n")

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
          |> Plug.Conn.resp(200, "diff --git a/x.ex b/x.ex\n+boom\n")

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
