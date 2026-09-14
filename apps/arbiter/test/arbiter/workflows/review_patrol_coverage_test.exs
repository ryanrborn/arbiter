defmodule Arbiter.Workflows.ReviewPatrolCoverageTest do
  @moduledoc """
  P1 of `docs/review-coverage-and-guard-policy.md` (design #1635) §3.3, the
  **ReviewPatrol post-review** row of the stamping table.

  A post-review records one `review_coverage` row — `kind: :reviewed`,
  `source: :review_patrol`, a non-nil `net_diff_id` — on the AUTHORING task,
  not on the reviewing engagement. The engagement cursor (`last_reviewed_sha` /
  `last_reviewed_at` / `posted_findings`) is untouched by this: it is written
  exactly as before, and asserted here so a regression shows up as a cursor
  failure rather than silently.

  A round that requested changes records nothing: §3.1 defines `:reviewed` as
  "an approving round covered this commit", and a rejecting round did not.
  """

  use Arbiter.DataCase, async: false

  alias Arbiter.Reviews.Coverage.Entry
  alias Arbiter.Tasks.{Issue, Workspace}
  alias Arbiter.Workflows.ReviewPatrol

  require Ash.Query

  @stub_name Arbiter.Mergers.Github.HTTP
  @head String.duplicate("b", 40)

  setup do
    {:ok, ws} =
      Ash.create(Workspace, %{
        name: "rp-cov-#{System.unique_integer([:positive])}",
        prefix: "rpc",
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

    prior = System.get_env("GITHUB_TOKEN")
    System.put_env("GITHUB_TOKEN", "test-token-rp-coverage")

    on_exit(fn ->
      if prior, do: System.put_env("GITHUB_TOKEN", prior), else: System.delete_env("GITHUB_TOKEN")
    end)

    {:ok, ws: ws}
  end

  # ---- helpers (mirroring review_patrol_test.exs) --------------------------

  defp stub(fun), do: Req.Test.stub(@stub_name, fun)

  defp start_patrol(ws) do
    name = String.to_atom("ReviewPatrolCov_#{System.unique_integer([:positive])}")

    pid =
      start_supervised!(
        Supervisor.child_spec(
          {ReviewPatrol,
           [repo: "owner/repo", workspace_id: ws.id, interval_ms: 60_000, name: name]},
          id: name
        )
      )

    Req.Test.allow(@stub_name, self(), pid)
    {pid, name}
  end

  defp engagement(ws, source_pr, attrs) do
    {:ok, task} =
      Ash.create(Issue, %{
        title: "Review PR ##{source_pr}",
        tracker_type: :none,
        source_pr: to_string(source_pr),
        workspace_id: ws.id
      })

    {:ok, task} = Ash.update(task, Map.merge(%{review_only: true}, attrs), action: :update)
    task
  end

  defp finding(file, line, message, severity) do
    %{"file" => file, "line" => line, "message" => message, "severity" => severity}
  end

  defp wide_diff(file) do
    context = Enum.map_join(1..19, "\n", &" line#{&1}")

    "diff --git a/#{file} b/#{file}\n--- a/#{file}\n+++ b/#{file}\n" <>
      "@@ -1,19 +1,20 @@\n#{context}\n+added\n"
  end

  defp put_invoker(findings) do
    json = Jason.encode!(%{"findings" => findings})
    Application.put_env(:arbiter, :code_review_invoker, fn _prompt, _state -> {:ok, json} end)
    on_exit(fn -> Application.delete_env(:arbiter, :code_review_invoker) end)
  end

  # The re-review conversation for an OPEN PR at `head`, with a real `base.ref`
  # so the coverage row can name what the net diff was taken against.
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
            "base" => %{"ref" => "main"},
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
          conn |> Plug.Conn.put_status(500) |> Req.Test.json(%{"message" => "unhandled #{path}"})
      end
    end)
  end

  defp coverage_rows(task_id) do
    Entry
    |> Ash.Query.filter(task_id == ^task_id)
    |> Ash.read!()
  end

  # ---- acceptance 1 --------------------------------------------------------

  describe "a post-review (§3.3 ReviewPatrol row)" do
    test "records one :reviewed row and leaves the engagement cursor unchanged", %{ws: ws} do
      eng =
        engagement(ws, 700, %{
          review_automation: :auto,
          last_reviewed_sha: "oldsha",
          posted_findings: [finding("lib/a.ex", 5, "prior issue", "error")]
        })

      # A `warning` keeps the verdict at :approve while still landing a finding
      # in the flagged file, so the relevance gate opens.
      put_invoker([finding("lib/a.ex", 10, "nit", "warning")])
      rereview_stub(700, @head, wide_diff("lib/a.ex"))

      {_pid, name} = start_patrol(ws)
      assert :ok = ReviewPatrol.tick(name)

      assert_receive {:submit_review, review}
      assert review["event"] == "APPROVE"

      # The cursor is written exactly as before — coverage is a dual write.
      reloaded = Ash.get!(Issue, eng.id)
      assert reloaded.last_reviewed_sha == @head
      assert reloaded.last_reviewed_at

      assert [entry] = coverage_rows(eng.id)
      assert entry.kind == :reviewed
      assert entry.source == :review_patrol
      assert entry.mr_ref == "700"
      assert entry.head_sha == @head
      assert entry.base_ref == "main"
      assert is_binary(entry.net_diff_id) and entry.net_diff_id != ""
      assert entry.round == nil
      assert entry.derived_from == nil
    end

    test "records on the authoring task when the fleet opened the PR", %{ws: ws} do
      {:ok, author} =
        Ash.create(Issue, %{title: "authored work", workspace_id: ws.id, issue_type: :feature})

      {:ok, author} = Ash.update(author, %{pr_ref: "701"}, action: :update)

      eng =
        engagement(ws, 701, %{
          review_automation: :auto,
          last_reviewed_sha: "oldsha",
          posted_findings: [finding("lib/a.ex", 5, "prior issue", "error")]
        })

      put_invoker([finding("lib/a.ex", 10, "nit", "warning")])
      rereview_stub(701, @head, wide_diff("lib/a.ex"))

      {_pid, name} = start_patrol(ws)
      assert :ok = ReviewPatrol.tick(name)
      assert_receive {:submit_review, _review}

      # §3.1: task_id is the authoring task, never the reviewing engagement.
      assert coverage_rows(eng.id) == []
      assert [entry] = coverage_rows(author.id)
      assert entry.source == :review_patrol
      assert entry.head_sha == @head
    end

    test "a round that requested changes records nothing", %{ws: ws} do
      eng =
        engagement(ws, 702, %{
          review_automation: :auto,
          last_reviewed_sha: "oldsha",
          posted_findings: [finding("lib/a.ex", 5, "prior issue", "error")]
        })

      put_invoker([finding("lib/a.ex", 10, "real bug", "error")])
      rereview_stub(702, @head, wide_diff("lib/a.ex"))

      {_pid, name} = start_patrol(ws)
      assert :ok = ReviewPatrol.tick(name)

      assert_receive {:submit_review, review}
      assert review["event"] == "REQUEST_CHANGES"

      # The cursor still advanced; coverage did not.
      assert Ash.get!(Issue, eng.id).last_reviewed_sha == @head
      assert coverage_rows(eng.id) == []
    end
  end
end
