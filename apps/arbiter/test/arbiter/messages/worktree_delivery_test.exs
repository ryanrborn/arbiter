defmodule Arbiter.Messages.WorktreeDeliveryTest do
  use Arbiter.DataCase, async: false

  alias Arbiter.Messages.{Message, WorktreeDelivery}
  alias Arbiter.Worker

  @ws "ws-wt-delivery-test"

  defp new_task_id, do: "wt-delivery-#{System.unique_integer([:positive])}"

  defp start_worker(task_id, worktree_path) do
    {:ok, pid} =
      Worker.start(task_id: task_id, repo: "arbiter", meta: %{worktree_path: worktree_path})

    on_exit(fn ->
      if Process.alive?(pid), do: GenServer.stop(pid, :normal)
    end)

    pid
  end

  describe "maybe_deliver/1" do
    test "no-ops when no worker is running for to_ref" do
      result =
        WorktreeDelivery.maybe_deliver(%{
          kind: :direction,
          to_ref: "bd-no-running-worker",
          body: "hello",
          inserted_at: DateTime.utc_now()
        })

      assert result == :ok
    end

    test "no-ops for notification kind" do
      result =
        WorktreeDelivery.maybe_deliver(%{
          kind: :notification,
          to_ref: "bd-anything",
          body: "broadcast",
          inserted_at: DateTime.utc_now()
        })

      assert result == :ok
    end

    test "no-ops for coordinator-bound kinds even with a matching worker" do
      task_id = new_task_id()
      tmp = System.tmp_dir!() |> Path.join("arb-inbox-#{task_id}")
      on_exit(fn -> File.rm_rf!(tmp) end)
      start_worker(task_id, tmp)

      for kind <- [:completion, :failure, :escalation, :info] do
        WorktreeDelivery.maybe_deliver(%{
          kind: kind,
          to_ref: task_id,
          body: "shouldn't land",
          inserted_at: DateTime.utc_now()
        })
      end

      refute File.exists?(Path.join([tmp, ".arbiter", "INBOX"]))
    end

    test "no-ops when the running worker has no worktree_path in meta" do
      task_id = new_task_id()
      {:ok, pid} = Worker.start(task_id: task_id, repo: "arbiter", meta: %{})

      on_exit(fn ->
        if Process.alive?(pid), do: GenServer.stop(pid, :normal)
      end)

      result =
        WorktreeDelivery.maybe_deliver(%{
          kind: :direction,
          to_ref: task_id,
          body: "hello",
          inserted_at: DateTime.utc_now()
        })

      assert result == :ok
    end

    test "writes .arbiter/INBOX in the worktree when a worker is running" do
      task_id = new_task_id()
      tmp = System.tmp_dir!() |> Path.join("arb-inbox-#{task_id}")
      on_exit(fn -> File.rm_rf!(tmp) end)
      start_worker(task_id, tmp)

      WorktreeDelivery.maybe_deliver(%{
        kind: :direction,
        to_ref: task_id,
        body: "check the merge conflict before continuing",
        inserted_at: ~U[2026-06-23 20:45:00Z]
      })

      inbox = Path.join([tmp, ".arbiter", "INBOX"])
      assert File.exists?(inbox)
      content = File.read!(inbox)
      assert content =~ "[2026-06-23T20:45:00Z]"
      assert content =~ "check the merge conflict before continuing"
      assert content =~ "---"
    end

    test "creates .arbiter/ directory if absent" do
      task_id = new_task_id()
      tmp = System.tmp_dir!() |> Path.join("arb-inbox-#{task_id}")
      File.mkdir_p!(tmp)
      on_exit(fn -> File.rm_rf!(tmp) end)
      start_worker(task_id, tmp)

      refute File.exists?(Path.join(tmp, ".arbiter"))

      WorktreeDelivery.maybe_deliver(%{
        kind: :direction,
        to_ref: task_id,
        body: "go",
        inserted_at: DateTime.utc_now()
      })

      assert File.exists?(Path.join([tmp, ".arbiter", "INBOX"]))
    end

    test "multiple deliveries before worker reads accumulate via append" do
      task_id = new_task_id()
      tmp = System.tmp_dir!() |> Path.join("arb-inbox-#{task_id}")
      on_exit(fn -> File.rm_rf!(tmp) end)
      start_worker(task_id, tmp)

      WorktreeDelivery.maybe_deliver(%{
        kind: :direction,
        to_ref: task_id,
        body: "first message",
        inserted_at: ~U[2026-06-23 20:45:00Z]
      })

      WorktreeDelivery.maybe_deliver(%{
        kind: :direction,
        to_ref: task_id,
        body: "second message",
        inserted_at: ~U[2026-06-23 20:46:00Z]
      })

      inbox = Path.join([tmp, ".arbiter", "INBOX"])
      content = File.read!(inbox)
      assert content =~ "first message"
      assert content =~ "second message"
    end

    test "after worker deletes the file, the next message creates a fresh file" do
      task_id = new_task_id()
      tmp = System.tmp_dir!() |> Path.join("arb-inbox-#{task_id}")
      on_exit(fn -> File.rm_rf!(tmp) end)
      start_worker(task_id, tmp)

      WorktreeDelivery.maybe_deliver(%{
        kind: :direction,
        to_ref: task_id,
        body: "first",
        inserted_at: ~U[2026-06-23 20:45:00Z]
      })

      inbox = Path.join([tmp, ".arbiter", "INBOX"])
      File.rm!(inbox)

      WorktreeDelivery.maybe_deliver(%{
        kind: :direction,
        to_ref: task_id,
        body: "second",
        inserted_at: ~U[2026-06-23 20:46:00Z]
      })

      content = File.read!(inbox)
      refute content =~ "first"
      assert content =~ "second"
    end

    test "delivers for :flag kind (worker-to-worker)" do
      task_id = new_task_id()
      tmp = System.tmp_dir!() |> Path.join("arb-inbox-#{task_id}")
      on_exit(fn -> File.rm_rf!(tmp) end)
      start_worker(task_id, tmp)

      WorktreeDelivery.maybe_deliver(%{
        kind: :flag,
        to_ref: task_id,
        body: "sibling flag",
        inserted_at: DateTime.utc_now()
      })

      inbox = Path.join([tmp, ".arbiter", "INBOX"])
      assert File.exists?(inbox)
      assert File.read!(inbox) =~ "sibling flag"
    end
  end

  describe "end-to-end via Message.send_mail/1" do
    test "send_mail delivers to the worktree INBOX when a worker is running" do
      task_id = new_task_id()
      tmp = System.tmp_dir!() |> Path.join("arb-inbox-e2e-#{task_id}")
      on_exit(fn -> File.rm_rf!(tmp) end)
      start_worker(task_id, tmp)

      {:ok, _msg} =
        Message.send_mail(%{
          kind: :direction,
          workspace_id: @ws,
          from_ref: "coordinator",
          to_ref: task_id,
          body: "please prioritise the merge conflict"
        })

      inbox = Path.join([tmp, ".arbiter", "INBOX"])
      assert File.exists?(inbox)
      content = File.read!(inbox)
      assert content =~ "please prioritise the merge conflict"
    end

    test "send_mail with no running worker leaves inbox unchanged (DB only)" do
      task_id = new_task_id()

      {:ok, _msg} =
        Message.send_mail(%{
          kind: :direction,
          workspace_id: @ws,
          from_ref: "coordinator",
          to_ref: task_id,
          body: "no worker here"
        })

      [msg] = Message.inbox(task_id, workspace_id: @ws)
      assert msg.body == "no worker here"
    end

    test "existing inbox tests are unaffected (send_mail to coordinator still works)" do
      {:ok, _msg} =
        Message.send_mail(%{
          kind: :escalation,
          workspace_id: @ws,
          from_ref: "bd-some-worker",
          to_ref: "coordinator",
          directive_ref: "bd-some-worker",
          body: "needs attention"
        })

      [msg] = Message.inbox("coordinator", workspace_id: @ws)
      assert msg.body == "needs attention"
    end
  end
end
