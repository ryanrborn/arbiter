defmodule Arbiter.Tasks.Issue.Changes.SyncFieldsTest do
  @moduledoc """
  Tests for SyncFields — the after-action hook that propagates title/description
  changes on :update to the linked external tracker.
  """
  use Arbiter.DataCase, async: false

  alias Arbiter.Tasks.Issue
  alias Arbiter.Tasks.Workspace

  @owner "ryanrborn"
  @repo "arbiter"
  @ref "42"
  @env_var "GTE_SYNC_FIELDS_TEST_TOKEN"

  @tracker_config %{
    "owner" => @owner,
    "repo" => @repo,
    "credentials_ref" => "env:#{@env_var}"
  }

  setup do
    System.put_env(@env_var, "test-github-token")
    on_exit(fn -> System.delete_env(@env_var) end)
    :ok
  end

  defp github_workspace do
    {:ok, ws} =
      Ash.create(Workspace, %{
        name: "sf-gh-ws-#{System.unique_integer([:positive])}",
        prefix: "sf",
        config: %{"tracker" => %{"type" => "github", "config" => @tracker_config}}
      })

    ws
  end

  defp plain_workspace do
    {:ok, ws} =
      Ash.create(Workspace, %{
        name: "sf-plain-ws-#{System.unique_integer([:positive])}",
        prefix: "sp"
      })

    ws
  end

  defp patch_stub(test_pid) do
    Req.Test.stub(Arbiter.Trackers.GitHub.HTTP, fn conn ->
      case conn.method do
        "GET" ->
          conn
          |> Plug.Conn.put_status(200)
          |> Req.Test.json(%{"number" => 42, "state" => "open", "labels" => []})

        "PATCH" ->
          {:ok, body, conn} = Plug.Conn.read_body(conn)
          send(test_pid, {:patch, conn.request_path, Jason.decode!(body)})

          conn
          |> Plug.Conn.put_status(200)
          |> Req.Test.json(%{"number" => 42})
      end
    end)
  end

  describe "title change on a github-tracked task" do
    test "PATCHes the upstream issue with the new title" do
      patch_stub(self())
      ws = github_workspace()

      {:ok, issue} =
        Ash.create(Issue, %{
          title: "original title",
          tracker_type: :github,
          tracker_ref: @ref,
          workspace_id: ws.id
        })

      assert {:ok, updated} = Ash.update(issue, %{title: "updated title"}, action: :update)
      assert updated.title == "updated title"

      expected_path = "/repos/#{@owner}/#{@repo}/issues/#{@ref}"
      assert_receive {:patch, ^expected_path, payload}
      assert payload["title"] == "updated title"
    end
  end

  describe "description change on a github-tracked task" do
    test "PATCHes the upstream issue with the new body" do
      patch_stub(self())
      ws = github_workspace()

      {:ok, issue} =
        Ash.create(Issue, %{
          title: "my task",
          description: "",
          tracker_type: :github,
          tracker_ref: @ref,
          workspace_id: ws.id
        })

      assert {:ok, updated} =
               Ash.update(issue, %{description: "new description"}, action: :update)

      assert updated.description == "new description"

      expected_path = "/repos/#{@owner}/#{@repo}/issues/#{@ref}"
      assert_receive {:patch, ^expected_path, payload}
      assert payload["body"] == "new description"
    end
  end

  describe "title + description changed together" do
    test "sends both fields in a single PATCH" do
      patch_stub(self())
      ws = github_workspace()

      {:ok, issue} =
        Ash.create(Issue, %{
          title: "old title",
          description: "old description",
          tracker_type: :github,
          tracker_ref: @ref,
          workspace_id: ws.id
        })

      assert {:ok, _updated} =
               Ash.update(issue, %{title: "new title", description: "new desc"}, action: :update)

      expected_path = "/repos/#{@owner}/#{@repo}/issues/#{@ref}"
      assert_receive {:patch, ^expected_path, payload}
      assert payload["title"] == "new title"
      assert payload["body"] == "new desc"
    end
  end

  describe "no tracked field changed" do
    test "does NOT call the adapter when only untracked fields change" do
      patch_stub(self())
      ws = github_workspace()

      {:ok, issue} =
        Ash.create(Issue, %{
          title: "stable title",
          tracker_type: :github,
          tracker_ref: @ref,
          workspace_id: ws.id
        })

      # Change only `notes`, which is not in [:title, :description]
      assert {:ok, _updated} = Ash.update(issue, %{notes: "some notes"}, action: :update)

      refute_receive {:patch, _, _}
    end

    test "does NOT call the adapter when the same value is written back" do
      patch_stub(self())
      ws = github_workspace()

      {:ok, issue} =
        Ash.create(Issue, %{
          title: "same title",
          tracker_type: :github,
          tracker_ref: @ref,
          workspace_id: ws.id
        })

      # Write the exact same title — no real change.
      assert {:ok, _updated} = Ash.update(issue, %{title: "same title"}, action: :update)

      refute_receive {:patch, _, _}
    end
  end

  describe "untracked tasks" do
    test "tracker_type :none does NOT call the adapter" do
      patch_stub(self())
      ws = plain_workspace()

      {:ok, issue} =
        Ash.create(Issue, %{
          title: "no tracker",
          tracker_type: :none,
          workspace_id: ws.id
        })

      assert {:ok, _updated} = Ash.update(issue, %{title: "renamed"}, action: :update)

      refute_receive {:patch, _, _}
    end

    test "github task WITHOUT a tracker_ref does NOT call the adapter" do
      patch_stub(self())
      ws = github_workspace()

      {:ok, issue} =
        Ash.create(Issue, %{
          title: "no ref",
          tracker_type: :github,
          tracker_ref: nil,
          skip_upstream_create: true,
          workspace_id: ws.id
        })

      assert {:ok, _updated} = Ash.update(issue, %{title: "renamed"}, action: :update)

      refute_receive {:patch, _, _}
    end
  end

  describe "review_only: true suppresses description sync (bd-6xaaam)" do
    test "does NOT PATCH the upstream issue when review_only is true and description changes" do
      patch_stub(self())
      ws = github_workspace()

      {:ok, issue} =
        Ash.create(Issue, %{
          title: "review-only task",
          description: "original brief",
          tracker_type: :github,
          tracker_ref: @ref,
          workspace_id: ws.id
        })

      # Set review_only: true and change the description in the same update.
      assert {:ok, updated} =
               Ash.update(issue, %{review_only: true, description: "internal review brief"},
                 action: :update
               )

      assert updated.description == "internal review brief"
      assert updated.review_only == true

      refute_receive {:patch, _, _}
    end
  end

  describe "sync failure is best-effort" do
    test "a tracker error does not break the local update" do
      Req.Test.stub(Arbiter.Trackers.GitHub.HTTP, fn conn ->
        conn
        |> Plug.Conn.put_status(500)
        |> Req.Test.json(%{"message" => "internal server error"})
      end)

      ws = github_workspace()

      {:ok, issue} =
        Ash.create(Issue, %{
          title: "tracker down",
          tracker_type: :github,
          tracker_ref: @ref,
          workspace_id: ws.id
        })

      assert {:ok, updated} =
               Ash.update(issue, %{title: "renamed despite error"}, action: :update)

      assert updated.title == "renamed despite error"
    end
  end
end
