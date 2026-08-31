defmodule Arbiter.Workflows.CodeReview.ChecksTest do
  @moduledoc """
  Prompt persistence coverage for bd-9rdwe4 (#1017 gap G5): external reviews
  and ReviewPatrol re-reviews share this module's default invoker, and
  neither spawns through `Arbiter.Worker` — so they need their own choke
  point for "persist what the agent was told, redacted".
  """
  use Arbiter.DataCase, async: false

  alias Arbiter.Tasks.Workspace
  alias Arbiter.Workflows.CodeReview.Checks
  alias Arbiter.Worker.PromptLog
  alias Arbiter.Reviews.Transcript

  @diff """
  diff --git a/lib/foo.ex b/lib/foo.ex
  index abc..def 100644
  --- a/lib/foo.ex
  +++ b/lib/foo.ex
  @@ -1 +1 @@
  -old
  +new
  """

  setup do
    Application.put_env(:arbiter, :code_review_invoker, fn _prompt, _state ->
      {:ok, ~s({"findings": []})}
    end)

    on_exit(fn -> Application.delete_env(:arbiter, :code_review_invoker) end)

    root =
      Path.join(System.tmp_dir!(), "checks-prompt-test-#{System.unique_integer([:positive])}")

    prev = Application.get_env(:arbiter, :output_log_root)
    Application.put_env(:arbiter, :output_log_root, root)

    on_exit(fn ->
      File.rm_rf(root)

      if prev,
        do: Application.put_env(:arbiter, :output_log_root, prev),
        else: Application.delete_env(:arbiter, :output_log_root)
    end)

    :ok
  end

  test "persists the composed prompt, redacted, keyed by state[:review_record_id]" do
    {:ok, ws} =
      Ash.create(Workspace, %{
        name: "checks-prompt-ws-#{System.unique_integer([:positive])}",
        worker_env: %{
          "MCP_SCOPE_TOKEN" => %{"value" => "tok_reviewsecret", "secret" => true}
        }
      })

    record_id = "review-record-#{System.unique_integer([:positive])}"

    state = %{
      review_record_id: record_id,
      workspace: ws,
      task: %{id: "bd-1", title: "reviewed task, token tok_reviewsecret"}
    }

    assert {:ok, []} = Checks.run(@diff, state)

    assert {:ok, persisted} = PromptLog.read(record_id)
    refute persisted =~ "tok_reviewsecret"
    assert persisted =~ "[REDACTED]"
    assert persisted =~ "BEGIN DIFF"
  end

  test "does nothing when state carries no review_record_id (unchanged behavior)" do
    state = %{}
    assert {:ok, []} = Checks.run(@diff, state)
  end

  describe "transcript persistence (bd-7efini)" do
    @stream_json Enum.join(
                   [
                     ~s({"type":"system","subtype":"init","model":"claude-opus-5","session_id":"sess-9"}),
                     ~s({"type":"assistant","message":{"content":[{"type":"tool_use","id":"t1","name":"Grep","input":{"pattern":"tok_reviewsecret"}}]}}),
                     ~s({"type":"user","message":{"content":[{"type":"tool_result","tool_use_id":"t1","content":"one hit"}]}}),
                     ~s({"type":"result","subtype":"success","result":"{\\"findings\\": []}"})
                   ],
                   "\n"
                 )

    test "persists the reviewer's raw stream-json transcript, keyed by review_record_id" do
      Application.put_env(:arbiter, :code_review_invoker, fn _prompt, _state ->
        {:ok, ~s({"findings": []}), %{model: "claude-opus-5"}, @stream_json}
      end)

      record_id = "review-record-#{System.unique_integer([:positive])}"

      assert {:ok, [], %{model: "claude-opus-5"}} =
               Checks.run(@diff, %{review_record_id: record_id})

      assert Transcript.exists?(record_id)
      assert %{line_count: 4, tool_use_count: 1} = Transcript.summary(record_id)
      assert [%{name: "Grep", result: "one hit"}] = Transcript.tool_uses(record_id)
    end

    test "redacts workspace secrets out of the transcript before it hits disk" do
      {:ok, ws} =
        Ash.create(Workspace, %{
          name: "checks-transcript-ws-#{System.unique_integer([:positive])}",
          worker_env: %{
            "MCP_SCOPE_TOKEN" => %{"value" => "tok_reviewsecret", "secret" => true}
          }
        })

      Application.put_env(:arbiter, :code_review_invoker, fn _prompt, _state ->
        {:ok, ~s({"findings": []}), %{}, @stream_json}
      end)

      record_id = "review-record-#{System.unique_integer([:positive])}"

      assert {:ok, [], %{}} =
               Checks.run(@diff, %{review_record_id: record_id, workspace: ws})

      {:ok, lines} = Transcript.read_lines(record_id)
      refute Enum.any?(lines, &(&1 =~ "tok_reviewsecret"))
      assert Enum.any?(lines, &(&1 =~ "[REDACTED]"))
    end

    test "captures the output of a failed reviewer invocation too" do
      Application.put_env(:arbiter, :code_review_invoker, fn _prompt, _state ->
        {:error, {:claude_failed, 1, "boom"}, "boom\ncrashed"}
      end)

      record_id = "review-record-#{System.unique_integer([:positive])}"

      assert {:error, {:claude_failed, 1, "boom"}} =
               Checks.run(@diff, %{review_record_id: record_id})

      assert {:ok, ["boom", "crashed"]} = Transcript.read_lines(record_id)
    end

    test "an invoker that returns no raw output writes no transcript (unchanged behavior)" do
      record_id = "review-record-#{System.unique_integer([:positive])}"

      assert {:ok, []} = Checks.run(@diff, %{review_record_id: record_id})

      refute Transcript.exists?(record_id)
    end
  end
end
