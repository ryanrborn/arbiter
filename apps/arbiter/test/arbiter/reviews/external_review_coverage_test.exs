defmodule Arbiter.Reviews.ExternalReviewCoverageTest do
  @moduledoc """
  P1 of `docs/review-coverage-and-guard-policy.md` (design #1635) §3.3, the
  **ExternalReview baseline** row of the stamping table.

  The baseline that seeds a new review engagement records a `review_coverage`
  row — `kind: :reviewed`, `source: :external_review` — **only when the external
  verdict is an approval**. A `request_changes` first pass advances the cursor
  (`last_reviewed_sha`) exactly as before and records no coverage: §3.1 defines
  `:reviewed` as "an approving round covered this commit".
  """

  # async: false — the GitHub merger uses the process-global Req.Test stub
  # registry and the per-process active-config dictionary.
  use Arbiter.DataCase, async: false

  alias Arbiter.Reviews.Coverage.Entry
  alias Arbiter.Reviews.ExternalReview
  alias Arbiter.Tasks.{Issue, Workspace}

  require Ash.Query

  @env_var "EXTERNAL_REVIEW_COV_TOKEN"
  @head String.duplicate("c", 40)

  setup do
    System.put_env(@env_var, "test-token")
    on_exit(fn -> System.delete_env(@env_var) end)
    :ok
  end

  defp github_ws(name) do
    {:ok, ws} =
      Ash.create(Workspace, %{
        name: "#{name}-#{System.unique_integer([:positive])}",
        prefix: "erc" <> Integer.to_string(:erlang.unique_integer([:positive])),
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

  defp json(conn, body) do
    conn
    |> Plug.Conn.put_resp_header("content-type", "application/json")
    |> Plug.Conn.resp(200, Jason.encode!(body))
  end

  @diff "diff --git a/x.ex b/x.ex\n--- a/x.ex\n+++ b/x.ex\n@@ -0,0 +1 @@\n+boom\n"

  # Every endpoint the review + the engagement baseline + the coverage
  # fingerprint touch. Unlike the shared harness in external_review_test.exs
  # this PR carries a real `base.ref` and a 40-hex head, which is what a
  # coverage row needs to be well-formed.
  defp stub_review do
    Req.Test.stub(Arbiter.Mergers.Github.HTTP, fn conn ->
      path = conn.request_path
      diff? = "application/vnd.github.v3.diff" in Plug.Conn.get_req_header(conn, "accept")

      cond do
        conn.method == "GET" and String.starts_with?(path, "/repos/octo/widget/compare/") ->
          conn
          |> Plug.Conn.put_resp_header("content-type", "text/plain")
          |> Plug.Conn.resp(200, @diff)

        conn.method == "GET" and path == "/repos/octo/widget/pulls/42" and diff? ->
          conn
          |> Plug.Conn.put_resp_header("content-type", "text/plain")
          |> Plug.Conn.resp(200, @diff)

        conn.method == "GET" and path == "/repos/octo/widget/pulls/42" ->
          json(conn, %{
            "number" => 42,
            "state" => "open",
            "head" => %{"sha" => @head},
            "base" => %{"ref" => "main"},
            "user" => %{"login" => "coworker"},
            "html_url" => "https://github.com/octo/widget/pull/42",
            "title" => "Fix widget overflow",
            "body" => "Closes #42."
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
          json(conn, %{"data" => %{"repository" => %{"pullRequest" => %{"reviewThreads" => %{"nodes" => []}}}}})

        true ->
          conn
          |> Plug.Conn.put_resp_header("content-type", "application/json")
          |> Plug.Conn.resp(404, Jason.encode!(%{"message" => "unhandled #{conn.method} #{path}"}))
      end
    end)
  end

  defp coverage_rows(task_id) do
    Entry
    |> Ash.Query.filter(task_id == ^task_id)
    |> Ash.read!()
  end

  # ---- acceptance 4 --------------------------------------------------------

  describe "the engagement baseline (§3.3 ExternalReview row)" do
    test "an approving verdict records one :reviewed coverage row" do
      ws = github_ws("erc-approve")
      stub_review()

      assert {:ok, result} =
               ExternalReview.review(
                 pr: "octo/widget#42",
                 workspace: ws.name,
                 follow_up: true,
                 check_runner: fn _diff, _state -> {:ok, []} end
               )

      assert result.verdict == :approve
      engagement = Ash.get!(Issue, result.engagement)
      # The cursor baseline is written exactly as before.
      assert engagement.last_reviewed_sha == @head

      assert [entry] = coverage_rows(engagement.id)
      assert entry.kind == :reviewed
      assert entry.source == :external_review
      assert entry.mr_ref == "octo/widget#42"
      assert entry.head_sha == @head
      assert entry.base_ref == "main"
      assert is_binary(entry.net_diff_id) and entry.net_diff_id != ""
      assert entry.round == nil
      assert entry.derived_from == nil
    end

    test "a request-changes verdict records no coverage, cursor only" do
      ws = github_ws("erc-reject")
      stub_review()

      finding = %{severity: :error, file: "x.ex", line: 1, message: "boom"}

      assert {:ok, result} =
               ExternalReview.review(
                 pr: "octo/widget#42",
                 workspace: ws.name,
                 follow_up: true,
                 check_runner: fn _diff, _state -> {:ok, [finding]} end
               )

      assert result.verdict == :request_changes
      engagement = Ash.get!(Issue, result.engagement)
      assert engagement.last_reviewed_sha == @head
      assert coverage_rows(engagement.id) == []
    end

    test "records on the authoring task when the fleet opened the PR" do
      ws = github_ws("erc-authored")
      stub_review()

      {:ok, author} =
        Ash.create(Issue, %{title: "authored work", workspace_id: ws.id, issue_type: :feature})

      {:ok, author} = Ash.update(author, %{pr_ref: "octo/widget#42"}, action: :update)

      assert {:ok, result} =
               ExternalReview.review(
                 pr: "octo/widget#42",
                 workspace: ws.name,
                 follow_up: true,
                 check_runner: fn _diff, _state -> {:ok, []} end
               )

      assert coverage_rows(result.engagement) == []
      assert [entry] = coverage_rows(author.id)
      assert entry.source == :external_review
      assert entry.head_sha == @head
    end
  end
end
