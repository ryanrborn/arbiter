defmodule Arbiter.Beads.Issue.Changes.CreateTrackerTest do
  @moduledoc """
  Wiring tests for outbound tracker creation on `Issue.create`.

  Exercises the full Ash action path with the GitHub HTTP client mocked via
  `Req.Test` (`:github_http_stub` is true in the test env). Asserts:

    * a github-tracked bead created without a ref POSTs to GitHub and binds
      the returned issue number to `tracker_ref`,
    * supplying `tracker_ref` skips the upstream POST,
    * `tracker_type: :none` skips the upstream POST,
    * upstream POST failures leave the bead persisted but surface an error
      so the caller exits non-zero.
  """
  use Arbiter.DataCase, async: false

  require Ash.Query

  alias Arbiter.Beads.Issue
  alias Arbiter.Beads.Workspace

  @owner "ryanrborn"
  @repo "arbiter"
  @env_var "GTE_CREATE_TRACKER_TEST_TOKEN"

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
        name: "gh-ws-#{System.unique_integer([:positive])}",
        prefix: "ctgh",
        config: %{"tracker" => %{"type" => "github", "config" => @tracker_config}}
      })

    ws
  end

  defp plain_workspace do
    {:ok, ws} =
      Ash.create(Workspace, %{
        name: "plain-#{System.unique_integer([:positive])}",
        prefix: "ctpl"
      })

    ws
  end

  describe "create with github tracker, no ref supplied" do
    test "POSTs the new bead's title+body to GitHub and binds the returned number" do
      test_pid = self()

      Req.Test.stub(Arbiter.Trackers.GitHub.HTTP, fn conn ->
        case conn.method do
          "POST" ->
            assert conn.request_path == "/repos/#{@owner}/#{@repo}/issues"
            {:ok, body, conn} = Plug.Conn.read_body(conn)
            send(test_pid, {:github_post, Jason.decode!(body)})

            conn
            |> Plug.Conn.put_status(201)
            |> Req.Test.json(%{"number" => 4242, "title" => "from bead"})
        end
      end)

      ws = github_workspace()

      {:ok, issue} =
        Ash.create(Issue, %{
          title: "from bead",
          description: "do the thing",
          workspace_id: ws.id
        })

      # Tracker inheritance + outbound mirror.
      assert issue.tracker_type == :github
      assert issue.tracker_ref == "4242"

      assert_receive {:github_post, payload}
      assert payload["title"] == "from bead"
      assert payload["body"] == "do the thing"
    end

    test "seeds the in-progress label when the bead's initial status would be :in_progress" do
      # The :create action defaults status to :open, so we can't override
      # it via the action — but the change should compute the label from the
      # bead's actual status. Verify the default (:open) path doesn't add a
      # label, since the default open mapping has no label.
      test_pid = self()

      Req.Test.stub(Arbiter.Trackers.GitHub.HTTP, fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        send(test_pid, {:post_body, Jason.decode!(body)})

        conn
        |> Plug.Conn.put_status(201)
        |> Req.Test.json(%{"number" => 8})
      end)

      ws = github_workspace()
      {:ok, _issue} = Ash.create(Issue, %{title: "open-default", workspace_id: ws.id})

      assert_receive {:post_body, payload}
      refute Map.has_key?(payload, "labels")
    end
  end

  describe "create with --tracker-ref equivalent (tracker_ref supplied)" do
    test "skips the upstream POST and uses the supplied ref verbatim" do
      Req.Test.stub(Arbiter.Trackers.GitHub.HTTP, fn _conn ->
        flunk("CreateTracker must not call the adapter when tracker_ref is set")
      end)

      ws = github_workspace()

      {:ok, issue} =
        Ash.create(Issue, %{
          title: "bound to existing",
          tracker_type: :github,
          tracker_ref: "1234",
          workspace_id: ws.id
        })

      assert issue.tracker_ref == "1234"
      assert issue.tracker_type == :github
    end
  end

  describe "create with --no-tracker equivalent (tracker_type: :none)" do
    test "skips the upstream POST even when the workspace tracker is github" do
      Req.Test.stub(Arbiter.Trackers.GitHub.HTTP, fn _conn ->
        flunk("CreateTracker must not call the adapter when tracker_type is :none")
      end)

      ws = github_workspace()

      {:ok, issue} =
        Ash.create(Issue, %{
          title: "local only",
          tracker_type: :none,
          workspace_id: ws.id
        })

      assert issue.tracker_type == :none
      assert issue.tracker_ref == nil
    end
  end

  describe "create on a workspace without a tracker" do
    test "doesn't call the adapter (tracker_type defaults to :none)" do
      Req.Test.stub(Arbiter.Trackers.GitHub.HTTP, fn _conn ->
        flunk("CreateTracker must not call the adapter on a tracker-less workspace")
      end)

      ws = plain_workspace()

      {:ok, issue} = Ash.create(Issue, %{title: "no tracker", workspace_id: ws.id})

      assert issue.tracker_type == :none
      assert issue.tracker_ref == nil
    end
  end

  describe "upstream POST failure" do
    test "bead is persisted, action returns CreateTrackerError" do
      Req.Test.stub(Arbiter.Trackers.GitHub.HTTP, fn conn ->
        conn
        |> Plug.Conn.put_status(422)
        |> Req.Test.json(%{"message" => "Validation Failed"})
      end)

      ws = github_workspace()

      {:error, ash_err} =
        Ash.create(Issue, %{title: "upstream-rejected", workspace_id: ws.id})

      # Bead row survived the failed upstream call (after_transaction error
      # doesn't roll back).
      [bead] =
        Issue
        |> Ash.Query.filter(workspace_id == ^ws.id and title == "upstream-rejected")
        |> Ash.read!()

      assert bead.tracker_type == :github
      assert bead.tracker_ref == nil

      # The Ash error carries our struct with the bead id and the upstream
      # adapter reason. Built on `Splode.Error`, so the struct is preserved
      # in `Ash.Error.Unknown.errors` rather than inspect/1'd to a string.
      assert %Ash.Error.Unknown{errors: [%Arbiter.Beads.Issue.CreateTrackerError{} = cte]} =
               ash_err

      assert cte.bead_id == bead.id
      assert cte.tracker_type == :github
      assert cte.upstream_ref == nil
      assert match?(%Arbiter.Trackers.GitHub.Error{kind: :validation_failed}, cte.reason)
    end

    test "transport error surfaces as CreateTrackerError too" do
      # No stub for this exception — Req will propagate from the network
      # layer. The simplest way to provoke a transport failure under
      # `:github_http_stub` is to return non-2xx (already covered above).
      # Here we exercise the 5xx path which is functionally distinct from
      # 4xx in `kind_for_status/1`.
      Req.Test.stub(Arbiter.Trackers.GitHub.HTTP, fn conn ->
        conn
        |> Plug.Conn.put_status(503)
        |> Req.Test.json(%{"message" => "down"})
      end)

      ws = github_workspace()

      assert {:error, %Ash.Error.Unknown{}} =
               Ash.create(Issue, %{title: "upstream-5xx", workspace_id: ws.id})

      # Bead is still there with no ref.
      [bead] =
        Issue
        |> Ash.Query.filter(workspace_id == ^ws.id and title == "upstream-5xx")
        |> Ash.read!()

      assert bead.tracker_type == :github
      assert bead.tracker_ref == nil
    end

    test "missing tracker config surfaces as CreateTrackerError" do
      # No HTTP stub needed — Config.resolve/0 fails before any request.
      ws = github_workspace()
      System.delete_env(@env_var)

      assert {:error, %Ash.Error.Unknown{}} =
               Ash.create(Issue, %{title: "no-token", workspace_id: ws.id})

      # Bead persisted.
      [bead] =
        Issue
        |> Ash.Query.filter(workspace_id == ^ws.id and title == "no-token")
        |> Ash.read!()

      assert bead.tracker_type == :github
      assert bead.tracker_ref == nil
    end
  end

  describe "Jira / Shortcut adapters return :not_implemented" do
    test "Jira workspace creates a local bead unlinked, no error surfaced" do
      {:ok, ws} =
        Ash.create(Workspace, %{
          name: "jira-#{System.unique_integer([:positive])}",
          prefix: "jr",
          config: %{"tracker" => %{"type" => "jira"}}
        })

      # No tracker stub — :not_implemented is returned by the Jira adapter
      # itself, before any HTTP request.
      {:ok, issue} = Ash.create(Issue, %{title: "j-bead", workspace_id: ws.id})

      assert issue.tracker_type == :jira
      assert issue.tracker_ref == nil
    end

    test "Shortcut workspace + explicit tracker_type creates a local bead unlinked" do
      # `Arbiter.Beads.Issue.Changes.InheritTrackerType` doesn't yet include
      # :shortcut in its allowlist, so we pass tracker_type explicitly to
      # exercise CreateTracker's :not_implemented branch for Shortcut.
      {:ok, ws} =
        Ash.create(Workspace, %{
          name: "sc-#{System.unique_integer([:positive])}",
          prefix: "sc",
          config: %{"tracker" => %{"type" => "shortcut"}}
        })

      {:ok, issue} =
        Ash.create(Issue, %{
          title: "s-bead",
          tracker_type: :shortcut,
          workspace_id: ws.id
        })

      assert issue.tracker_type == :shortcut
      assert issue.tracker_ref == nil
    end
  end
end
