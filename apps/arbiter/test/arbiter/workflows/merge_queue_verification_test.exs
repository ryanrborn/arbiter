defmodule Arbiter.Workflows.MergeQueueVerificationTest do
  @moduledoc """
  bd-9so315 — a merge of a `verify_after_deploy` task parks the task at
  `:awaiting_verification` instead of closing it, and notifies the coordinator
  once. Unflagged tasks close on merge exactly as before (regression).
  """
  # async: false — DataCase sandbox can't be shared with the GenServer process
  # in async mode.
  use Arbiter.DataCase, async: false

  alias Arbiter.Messages.Message
  alias Arbiter.Tasks.Issue
  alias Arbiter.Tasks.Workspace
  alias Arbiter.Workflows.MergeQueue

  defmodule FakeWorktree do
    def worktree_path(branch), do: "/fake/worktrees/#{branch}"
    def push(_path, _opts), do: {:ok, ""}
    def rebase_onto_origin(_path, _branch), do: {:ok, :up_to_date}
  end

  @ws_github %{
    "merge" => %{
      "strategy" => "github",
      "config" => %{
        "owner" => "octo",
        "repo" => "widget",
        "credentials_ref" => "test-token-abc123"
      }
    }
  }

  setup do
    {:ok, workspace} =
      Ash.create(Workspace, %{
        name: "ws-#{System.unique_integer([:positive])}",
        prefix: "vq#{System.unique_integer([:positive])}",
        config: @ws_github
      })

    %{workspace: workspace}
  end

  defp new_task(ws, attrs) do
    {:ok, task} =
      Ash.create(
        Issue,
        Map.merge(%{title: "merge me", description: "body", workspace_id: ws.id}, attrs)
      )

    task
  end

  defp stub(fun), do: Req.Test.stub(Arbiter.Mergers.Github.HTTP, fun)

  defp full_cycle_stub(number) do
    stub(fn conn ->
      cond do
        conn.method == "POST" and String.ends_with?(conn.request_path, "/pulls") ->
          conn
          |> Plug.Conn.put_status(201)
          |> Req.Test.json(%{
            "number" => number,
            "html_url" => "https://github.com/octo/widget/pull/#{number}"
          })

        conn.method == "GET" and String.ends_with?(conn.request_path, "/reviews") ->
          conn |> Plug.Conn.put_status(200) |> Req.Test.json([%{"state" => "APPROVED"}])

        conn.method == "GET" and String.contains?(conn.request_path, "/pulls/#{number}") ->
          conn
          |> Plug.Conn.put_status(200)
          |> Req.Test.json(%{
            "number" => number,
            "state" => "open",
            "mergeable" => true,
            "mergeStateStatus" => "clean",
            "html_url" => "https://github.com/octo/widget/pull/#{number}"
          })

        conn.method == "PUT" and String.ends_with?(conn.request_path, "/merge") ->
          conn
          |> Plug.Conn.put_status(200)
          |> Req.Test.json(%{"merged" => true, "sha" => "deadbeef"})

        true ->
          conn |> Plug.Conn.put_status(500) |> Req.Test.json(%{"message" => "unexpected"})
      end
    end)
  end

  defp start_merge_queue(workspace) do
    name = :"merge_queue_#{System.unique_integer([:positive])}"

    {:ok, pid} =
      MergeQueue.start_link(
        workspace_id: workspace.id,
        base: "main",
        auto_tick: false,
        name: name,
        worktree_module: FakeWorktree
      )

    Req.Test.allow(Arbiter.Mergers.Github.HTTP, self(), pid)
    Ecto.Adapters.SQL.Sandbox.allow(Arbiter.Repo, self(), pid)
    {pid, name}
  end

  defp run_to_merge(ws, task, pr_number) do
    full_cycle_stub(pr_number)
    {_pid, name} = start_merge_queue(ws)
    :ok = MergeQueue.enqueue(name, task.id)
    :ok = MergeQueue.tick(name)
    Ash.get!(Issue, task.id)
  end

  describe "flagged task" do
    test "parks at :awaiting_verification instead of closing", %{workspace: ws} do
      task = new_task(ws, %{verify_after_deploy: true})
      :ok = Phoenix.PubSub.subscribe(Arbiter.PubSub, "merge_queue:" <> ws.id)

      reloaded = run_to_merge(ws, task, 301)

      assert reloaded.status == :awaiting_verification
      assert reloaded.closed_at == nil
      assert %DateTime{} = reloaded.awaiting_verification_at

      task_id = task.id
      assert_receive {:task_awaiting_verification, ^task_id}, 500
      refute_received {:task_closed_by_merge_queue, ^task_id}
    end

    test "sends exactly one coordinator escalation naming the restart question", %{workspace: ws} do
      task = new_task(ws, %{verify_after_deploy: true})

      _ = run_to_merge(ws, task, 302)

      assert [escalation] = Message.inbox("coordinator", workspace_id: ws.id)
      assert escalation.kind == :escalation
      assert escalation.to_ref == "coordinator"
      assert escalation.directive_ref == task.id
      assert escalation.subject =~ "awaiting verification"
      assert escalation.body =~ "restart"
      # It must say whether the running server predates the merge. The test VM
      # booted before this merge, so it must call for a restart first.
      assert escalation.body =~ "booted before"
      assert escalation.body =~ "arb issue verify #{task.id}"
    end
  end

  describe "unflagged task (regression)" do
    test "closes on merge exactly as before", %{workspace: ws} do
      task = new_task(ws, %{})
      :ok = Phoenix.PubSub.subscribe(Arbiter.PubSub, "merge_queue:" <> ws.id)

      reloaded = run_to_merge(ws, task, 303)

      assert reloaded.status == :closed
      assert %DateTime{} = reloaded.closed_at
      assert reloaded.awaiting_verification_at == nil

      task_id = task.id
      assert_receive {:task_closed_by_merge_queue, ^task_id}, 500
      refute_received {:task_awaiting_verification, ^task_id}
      assert Message.inbox("coordinator", workspace_id: ws.id) == []
    end
  end
end
