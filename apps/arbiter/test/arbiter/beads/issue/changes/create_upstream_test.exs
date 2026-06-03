defmodule Arbiter.Beads.Issue.Changes.CreateUpstreamTest do
  @moduledoc """
  Wiring tests for the outbound-create after_transaction hook on `Issue.create`.

  Exercises the full Ash action path against the GitHub HTTP stub
  (`:github_http_stub` is true in the test env). Asserts that:

    * a github-tracked workspace causes `arb create` to POST to GitHub and
      write the returned number back into `tracker_ref`,
    * `--tracker-ref` (passing `tracker_ref` to the action) and
      `--no-tracker` (`skip_upstream_create: true`) both skip the POST, and
    * an upstream failure leaves the bead intact and surfaces a
      `:upstream_create_failed` error to the caller.
  """
  use Arbiter.DataCase, async: false

  alias Arbiter.Beads.Issue
  alias Arbiter.Beads.Workspace

  @owner "ryanrborn"
  @repo "arbiter"
  @env_var "GTE_CREATE_UPSTREAM_TEST_TOKEN"

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
        prefix: "gh",
        config: %{"tracker" => %{"type" => "github", "config" => @tracker_config}}
      })

    ws
  end

  defp plain_workspace do
    {:ok, ws} =
      Ash.create(Workspace, %{
        name: "plain-ws-#{System.unique_integer([:positive])}",
        prefix: "pl"
      })

    ws
  end

  defp stub(fun), do: Req.Test.stub(Arbiter.Trackers.GitHub.HTTP, fun)

  describe "create on a github-configured workspace" do
    test "POSTs to /repos/:owner/:repo/issues and persists the returned number as tracker_ref" do
      test_pid = self()

      stub(fn conn ->
        case conn.method do
          "POST" ->
            assert conn.request_path == "/repos/#{@owner}/#{@repo}/issues"
            {:ok, body, conn} = Plug.Conn.read_body(conn)
            decoded = Jason.decode!(body)
            send(test_pid, {:posted, decoded})

            conn
            |> Plug.Conn.put_status(201)
            |> Req.Test.json(%{"number" => 555})
        end
      end)

      ws = github_workspace()

      assert {:ok, issue} =
               Ash.create(Issue, %{
                 title: "from arb create",
                 description: "body text",
                 workspace_id: ws.id
               })

      assert issue.tracker_type == :github
      assert issue.tracker_ref == "555"

      # Sanity-check the body that was sent.
      assert_receive {:posted, %{"title" => "from arb create", "body" => "body text"}}

      # And the persisted bead reflects the ref (no stale in-memory shape).
      assert {:ok, refetched} = Ash.get(Issue, issue.id)
      assert refetched.tracker_ref == "555"
    end
  end

  describe "skip paths" do
    test "tracker_type :none — no POST, no tracker_ref" do
      stub(fn _conn -> flunk("must not call GitHub for a non-tracker workspace") end)
      ws = plain_workspace()

      assert {:ok, issue} =
               Ash.create(Issue, %{title: "local-only", workspace_id: ws.id})

      assert issue.tracker_type == :none
      assert is_nil(issue.tracker_ref)
    end

    test "tracker_ref supplied (--tracker-ref) — bind to existing issue, no POST" do
      stub(fn _conn -> flunk("must not call GitHub when tracker_ref is supplied") end)
      ws = github_workspace()

      assert {:ok, issue} =
               Ash.create(Issue, %{
                 title: "binding to existing",
                 tracker_ref: "777",
                 workspace_id: ws.id
               })

      assert issue.tracker_type == :github
      assert issue.tracker_ref == "777"
    end

    test "skip_upstream_create=true (--no-tracker) — local-only despite configured tracker" do
      stub(fn _conn -> flunk("must not call GitHub when skip_upstream_create is true") end)
      ws = github_workspace()

      assert {:ok, issue} =
               Ash.create(Issue, %{
                 title: "explicit local",
                 skip_upstream_create: true,
                 workspace_id: ws.id
               })

      assert issue.tracker_type == :github
      assert is_nil(issue.tracker_ref)
    end
  end

  describe "upstream-failure semantics" do
    test "GitHub 500 leaves the bead intact and stashes :upstream_create_failed" do
      stub(fn conn ->
        conn
        |> Plug.Conn.put_status(500)
        |> Req.Test.json(%{"message" => "boom"})
      end)

      ws = github_workspace()

      # The action succeeds — bead is durable. The upstream error is stashed
      # in a process-dict slot the controller drains.
      assert {:ok, issue} = Ash.create(Issue, %{title: "doomed", workspace_id: ws.id})
      assert issue.title == "doomed"
      assert is_nil(issue.tracker_ref)

      assert %{
               kind: :upstream_create_failed,
               bead_id: bead_id,
               tracker_type: :github,
               message: msg
             } = Arbiter.Beads.Issue.Changes.CreateUpstream.last_error()

      assert bead_id == issue.id
      assert msg =~ "upstream github create failed"

      # And `last_error/0` drains, so a follow-up call returns nil.
      assert is_nil(Arbiter.Beads.Issue.Changes.CreateUpstream.last_error())

      # Bead must exist — local create succeeded; only the upstream side failed.
      assert {:ok, persisted} = Ash.get(Issue, bead_id)
      assert persisted.title == "doomed"
      assert is_nil(persisted.tracker_ref)
    end

    test "missing GitHub token stashes :upstream_create_failed but bead is durable" do
      ws = github_workspace()
      System.delete_env(@env_var)

      assert {:ok, issue} = Ash.create(Issue, %{title: "no token", workspace_id: ws.id})

      assert %{kind: :upstream_create_failed, bead_id: bead_id} =
               Arbiter.Beads.Issue.Changes.CreateUpstream.last_error()

      assert bead_id == issue.id
      assert {:ok, _persisted} = Ash.get(Issue, bead_id)
    end

    test "a successful upstream create drains last_error/0 (no stale entry)" do
      stub(fn conn ->
        case conn.method do
          "POST" ->
            conn
            |> Plug.Conn.put_status(201)
            |> Req.Test.json(%{"number" => 222})
        end
      end)

      ws = github_workspace()
      assert {:ok, issue} = Ash.create(Issue, %{title: "fine", workspace_id: ws.id})
      assert issue.tracker_ref == "222"

      # No error stashed on success.
      assert is_nil(Arbiter.Beads.Issue.Changes.CreateUpstream.last_error())
    end
  end
end
