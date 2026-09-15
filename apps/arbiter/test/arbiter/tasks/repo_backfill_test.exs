defmodule Arbiter.Tasks.RepoBackfillTest do
  @moduledoc """
  bd-9dwbvt: the one-shot backfill for issues filed before `:create` started
  binding a repo.
  """
  use Arbiter.DataCase, async: false

  alias Arbiter.Tasks.Issue
  alias Arbiter.Tasks.RepoBackfill
  alias Arbiter.Tasks.Workspace

  @env_key :repo_paths

  setup do
    prior = Application.get_env(:arbiter, @env_key)
    Application.delete_env(:arbiter, @env_key)

    on_exit(fn ->
      if prior,
        do: Application.put_env(:arbiter, @env_key, prior),
        else: Application.delete_env(:arbiter, @env_key)
    end)

    :ok
  end

  defp ws!(name, config) do
    {:ok, ws} =
      Ash.create(Workspace, %{
        name: "#{name}-#{System.unique_integer([:positive])}",
        prefix: "rbf",
        config: config
      })

    ws
  end

  defp report_for(reports, ws), do: Enum.find(reports, &(&1.workspace_id == ws.id))

  describe "plan/0" do
    test "proposes the sole repo for a single-repo workspace" do
      ws = ws!("single", %{"repo_paths" => %{"tonic" => "/srv/tonic"}})
      issue = issue_without_repo!(%{title: "orphan", workspace_id: ws.id})

      report = report_for(RepoBackfill.plan(), ws)

      assert report.resolved_repo == "tonic"
      assert report.null_repo_count == 1
      assert report.issue_ids == [issue.id]
      assert report.left_null == 0
    end

    test "proposes the default_repo for a multi-repo workspace" do
      ws =
        ws!("multi", %{
          "repo_paths" => %{"tonic" => "/srv/tonic", "tonic_device" => "/srv/device"},
          "default_repo" => "tonic_device"
        })

      _issue = issue_without_repo!(%{title: "orphan", workspace_id: ws.id})

      report = report_for(RepoBackfill.plan(), ws)

      assert report.resolved_repo == "tonic_device"
      assert report.null_repo_count == 1
    end

    test "leaves a multi-repo workspace with no default alone, and reports the count" do
      ws = ws!("ambig", %{"repo_paths" => %{"tonic" => "/srv/tonic", "dev" => "/srv/dev"}})
      _a = issue_without_repo!(%{title: "orphan a", workspace_id: ws.id})
      _b = issue_without_repo!(%{title: "orphan b", workspace_id: ws.id})

      report = report_for(RepoBackfill.plan(), ws)

      assert report.resolved_repo == nil
      assert report.null_repo_count == 2
      assert report.left_null == 2
      assert report.issue_ids == []
    end

    test "leaves a workspace with no repos configured alone" do
      ws = ws!("bare", %{})
      _issue = issue_without_repo!(%{title: "orphan", workspace_id: ws.id})

      report = report_for(RepoBackfill.plan(), ws)

      assert report.resolved_repo == nil
      assert report.left_null == 1
    end

    test "never touches an issue that already has a repo" do
      ws = ws!("has-repo", %{"repo_paths" => %{"tonic" => "/srv/tonic"}})
      {:ok, issue} = Ash.create(Issue, %{title: "already bound", workspace_id: ws.id})
      assert issue.repo == "tonic"

      report = report_for(RepoBackfill.plan(), ws)

      assert report.null_repo_count == 0
      assert report.issue_ids == []
    end
  end

  describe "apply!/1" do
    test "sets the repo on every null-repo issue, whatever its type or status" do
      ws = ws!("apply", %{"repo_paths" => %{"tonic" => "/srv/tonic"}})

      ids =
        for type <- [:feature, :bug, :chore, :task, :epic, :decision] do
          issue_without_repo!(%{title: "a #{type}", issue_type: type, workspace_id: ws.id}).id
        end

      closed = issue_without_repo!(%{title: "closed one", workspace_id: ws.id})
      {:ok, _} = Ash.update(closed, %{}, action: :close)

      results = RepoBackfill.apply!(RepoBackfill.plan())
      report = report_for(results, ws)

      assert report.updated == 7
      assert report.errors == []

      for id <- [closed.id | ids] do
        assert Ash.get!(Issue, id).repo == "tonic"
      end

      assert Ash.get!(Issue, closed.id).status == :closed
    end

    test "is idempotent — a second run changes nothing" do
      ws = ws!("idempotent", %{"repo_paths" => %{"tonic" => "/srv/tonic"}})
      issue = issue_without_repo!(%{title: "orphan", workspace_id: ws.id})

      first = RepoBackfill.apply!(RepoBackfill.plan())
      assert report_for(first, ws).updated == 1

      updated_at = Ash.get!(Issue, issue.id).updated_at

      second_plan = RepoBackfill.plan()
      assert report_for(second_plan, ws).null_repo_count == 0

      second = RepoBackfill.apply!(second_plan)
      assert report_for(second, ws).updated == 0

      reloaded = Ash.get!(Issue, issue.id)
      assert reloaded.repo == "tonic"
      assert reloaded.updated_at == updated_at
    end

    test "leaves the unresolvable workspaces null and still reports them" do
      ws = ws!("still-ambig", %{"repo_paths" => %{"a" => "/srv/a", "b" => "/srv/b"}})
      issue = issue_without_repo!(%{title: "orphan", workspace_id: ws.id})

      report = RepoBackfill.apply!(RepoBackfill.plan()) |> report_for(ws)

      assert report.updated == 0
      assert report.left_null == 1
      assert Ash.get!(Issue, issue.id).repo == nil
    end
  end
end
