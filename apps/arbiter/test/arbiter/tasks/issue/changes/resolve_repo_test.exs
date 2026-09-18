defmodule Arbiter.Tasks.Issue.Changes.ResolveRepoTest do
  @moduledoc """
  bd-9dwbvt: every issue-creation path funnels through `Ash.create(Issue, …)`,
  so the `:create` action is where the repo requirement is enforced. These are
  the action-level tests; the per-path tests (MCP `task_create`, the REST
  create `arb issue create` posts to, claim/sync, the dashboard form) live
  with their own modules.
  """
  use Arbiter.DataCase, async: false

  alias Arbiter.Tasks.Issue
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

  defp ws!(config) do
    {:ok, ws} =
      Ash.create(Workspace, %{
        name: "rr-#{System.unique_integer([:positive])}",
        prefix: "rr",
        config: config
      })

    ws
  end

  defp errors(%Ash.Error.Invalid{errors: errors}), do: errors

  defp repo_error_message(error) do
    error
    |> errors()
    |> Enum.filter(&(Map.get(&1, :field) == :repo))
    |> Enum.map_join(" ", &Map.get(&1, :message, ""))
  end

  describe "single-repo workspace" do
    test "auto-fills the sole repo on create" do
      ws = ws!(%{"repo_paths" => %{"tonic" => "/srv/tonic"}})

      {:ok, issue} = Ash.create(Issue, %{title: "no repo given", workspace_id: ws.id})

      assert issue.repo == "tonic"
      assert Ash.get!(Issue, issue.id).repo == "tonic"
    end

    test "auto-fills epics, decisions and tasks the same way" do
      ws = ws!(%{"repo_paths" => %{"tonic" => "/srv/tonic"}})

      for type <- [:epic, :decision, :task, :bug, :chore, :feature] do
        {:ok, issue} =
          Ash.create(Issue, %{title: "a #{type}", issue_type: type, workspace_id: ws.id})

        assert issue.repo == "tonic", "#{type} did not get the workspace repo"
      end
    end
  end

  describe "multi-repo workspace" do
    test "uses the workspace default_repo" do
      ws =
        ws!(%{
          "repo_paths" => %{"tonic" => "/srv/tonic", "tonic_device" => "/srv/device"},
          "default_repo" => "tonic_device"
        })

      {:ok, issue} = Ash.create(Issue, %{title: "defaulted", workspace_id: ws.id})

      assert issue.repo == "tonic_device"
    end

    test "refuses to create with no repo and no default, naming the configured keys" do
      ws = ws!(%{"repo_paths" => %{"tonic" => "/srv/tonic", "tonic_device" => "/srv/device"}})

      assert {:error, error} = Ash.create(Issue, %{title: "ambiguous", workspace_id: ws.id})

      message = repo_error_message(error)
      assert message =~ "tonic"
      assert message =~ "tonic_device"
      assert message =~ "default_repo"
    end

    test "an explicit repo is kept" do
      ws = ws!(%{"repo_paths" => %{"tonic" => "/srv/tonic", "tonic_device" => "/srv/device"}})

      {:ok, issue} =
        Ash.create(Issue, %{title: "explicit", workspace_id: ws.id, repo: "tonic_device"})

      assert issue.repo == "tonic_device"
    end

    test "an explicit repo is canonicalized onto the configured key" do
      ws = ws!(%{"repo_paths" => %{"apex-server" => "/srv/vs", "client" => "/srv/client"}})

      {:ok, issue} =
        Ash.create(Issue, %{title: "loose", workspace_id: ws.id, repo: "acme/apex_server"})

      assert issue.repo == "apex-server"
    end

    test "keeps the named key when two keys alias the same checkout" do
      ws =
        ws!(%{
          "repo_paths" => %{"tonic" => "/srv/x", "tonic-alias" => "/srv/x"},
          "default_repo" => "tonic"
        })

      {:ok, issue} =
        Ash.create(Issue, %{title: "aliased", workspace_id: ws.id, repo: "tonic-alias"})

      assert issue.repo == "tonic-alias"
    end
  end

  describe "explicit repo validation" do
    test "rejects a repo that is not a configured repo_paths key" do
      ws = ws!(%{"repo_paths" => %{"tonic" => "/srv/tonic"}})

      assert {:error, error} =
               Ash.create(Issue, %{title: "typo", workspace_id: ws.id, repo: "tonc"})

      message = repo_error_message(error)
      assert message =~ "tonc"
      assert message =~ "tonic"
    end
  end

  describe "workspace with no repos configured" do
    test "leaves repo nil rather than refusing the create" do
      ws = ws!(%{})

      {:ok, issue} = Ash.create(Issue, %{title: "unconfigured", workspace_id: ws.id})

      assert issue.repo == nil
    end

    test "passes an explicit repo through unvalidated" do
      ws = ws!(%{})

      {:ok, issue} =
        Ash.create(Issue, %{title: "unconfigured explicit", workspace_id: ws.id, repo: "someday"})

      assert issue.repo == "someday"
    end
  end

  describe "install-wide repo_paths" do
    test "counts towards resolution when the workspace configures none" do
      Application.put_env(:arbiter, @env_key, %{"arbiter" => "/srv/arbiter"})
      ws = ws!(%{})

      {:ok, issue} = Ash.create(Issue, %{title: "install-wide", workspace_id: ws.id})

      assert issue.repo == "arbiter"
    end
  end

  describe "update" do
    test "is left alone: an existing issue's repo can still be cleared or repointed" do
      ws = ws!(%{"repo_paths" => %{"tonic" => "/srv/tonic"}})
      {:ok, issue} = Ash.create(Issue, %{title: "repointable", workspace_id: ws.id})

      {:ok, cleared} = Ash.update(issue, %{repo: nil})
      assert cleared.repo == nil

      {:ok, stale} = Ash.update(cleared, %{repo: "org/gone"})
      assert stale.repo == "org/gone"
    end
  end
end
