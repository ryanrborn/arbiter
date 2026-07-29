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
end
