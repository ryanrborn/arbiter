# ---- stub adapters used by the tests ----------------------------------------

defmodule Arbiter.Workflows.ReviewReplyTest.Stubs do
  @moduledoc false

  defmodule Base do
    @moduledoc false
    @behaviour Arbiter.Mergers.Merger
    @impl true
    def open(_, _, _, _), do: {:error, :unused}
    @impl true
    def get(_), do: {:ok, %{}}
    @impl true
    def merge(_), do: :ok
    @impl true
    def close(_), do: :ok
    @impl true
    def add_comment(_, _), do: :ok
    @impl true
    def request_review(_, _), do: :ok
    @impl true
    def link_for(_), do: ""
    @impl true
    def get_diff(_, _), do: {:ok, ""}
    @impl true
    def post_inline_comment(_, _, _), do: {:ok, %{}}
    @impl true
    def submit_review(_, _, _, _), do: {:ok, %{}}
    @impl true
    def list_review_feedback(_), do: {:ok, %{changes_requested: false}}
  end

  # Adapter that DOES export reply_to_review_comment/4; records calls via message.
  defmodule ReplySpy do
    @moduledoc false
    @behaviour Arbiter.Mergers.Merger
    @impl true
    def open(_, _, _, _), do: {:error, :unused}
    @impl true
    def get(_), do: {:ok, %{}}
    @impl true
    def merge(_), do: :ok
    @impl true
    def close(_), do: :ok
    @impl true
    def add_comment(_, _), do: :ok
    @impl true
    def request_review(_, _), do: :ok
    @impl true
    def link_for(_), do: ""
    @impl true
    def get_diff(_, _), do: {:ok, ""}
    @impl true
    def post_inline_comment(_, _, _), do: {:ok, %{}}
    @impl true
    def submit_review(_, _, _, _), do: {:ok, %{}}
    @impl true
    def list_review_feedback(_), do: {:ok, %{changes_requested: false}}

    @impl true
    def reply_to_review_comment(mr_ref, comment_id, body, _opts) do
      send(:review_reply_test_pid, {:replied, mr_ref, comment_id, body})
      {:ok, %{id: 9001}}
    end
  end

  # Adapter that DOES NOT export reply_to_review_comment/4 — falls back to add_comment.
  defmodule FallbackSpy do
    @moduledoc false
    @behaviour Arbiter.Mergers.Merger
    @impl true
    def open(_, _, _, _), do: {:error, :unused}
    @impl true
    def get(_), do: {:ok, %{}}
    @impl true
    def merge(_), do: :ok
    @impl true
    def close(_), do: :ok
    @impl true
    def add_comment(mr_ref, body) do
      send(:review_reply_test_pid, {:fallback_comment, mr_ref, body})
      :ok
    end

    @impl true
    def request_review(_, _), do: :ok
    @impl true
    def link_for(_), do: ""
    @impl true
    def get_diff(_, _), do: {:ok, ""}
    @impl true
    def post_inline_comment(_, _, _), do: {:ok, %{}}
    @impl true
    def submit_review(_, _, _, _), do: {:ok, %{}}
    @impl true
    def list_review_feedback(_), do: {:ok, %{changes_requested: false}}
  end

  # Adapter whose reply_to_review_comment/4 returns an error.
  defmodule ReplyError do
    @moduledoc false
    @behaviour Arbiter.Mergers.Merger
    @impl true
    def open(_, _, _, _), do: {:error, :unused}
    @impl true
    def get(_), do: {:ok, %{}}
    @impl true
    def merge(_), do: :ok
    @impl true
    def close(_), do: :ok
    @impl true
    def add_comment(_, _), do: :ok
    @impl true
    def request_review(_, _), do: :ok
    @impl true
    def link_for(_), do: ""
    @impl true
    def get_diff(_, _), do: {:ok, ""}
    @impl true
    def post_inline_comment(_, _, _), do: {:ok, %{}}
    @impl true
    def submit_review(_, _, _, _), do: {:ok, %{}}
    @impl true
    def list_review_feedback(_), do: {:ok, %{changes_requested: false}}

    @impl true
    def reply_to_review_comment(_mr_ref, _comment_id, _body, _opts),
      do: {:error, :forbidden}
  end
end

defmodule Arbiter.Workflows.ReviewReplyTest do
  # async: false — tests that spy via a named process share the registered
  # name :review_reply_test_pid and must not run concurrently.
  use ExUnit.Case, async: false

  alias Arbiter.Workflows.ReviewReplyTest.Stubs
  alias Arbiter.Workflows.ReviewReply

  # A minimal thread fixture for tests.
  defp thread(overrides \\ %{}) do
    Map.merge(
      %{
        id: "thread_abc123",
        resolved: false,
        path: "lib/foo.ex",
        line: 42,
        diff_hunk: "@@ -40,6 +40,8 @@ def run(state) do\n+  new_line\n",
        author: "reviewer",
        body: "Why did you add this line here?",
        comments: [
          %{id: 101, author: "reviewer", body: "Why did you add this line here?"},
          %{id: 102, author: "author", body: "To fix the nil guard — is that the right approach?"}
        ]
      },
      overrides
    )
  end

  defp stub_composer(reply_text) do
    fn _ctx, _state -> {:ok, reply_text} end
  end

  # ==========================================================================
  # Workflow declaration
  # ==========================================================================

  describe "workflow declaration" do
    test "steps/0 returns the three step atoms in declared order" do
      assert ReviewReply.steps() == [:read_thread, :compose_reply, :post_reply]
    end

    test "vars/0 includes core inputs" do
      vars = ReviewReply.vars()
      assert :thread in vars
      assert :comment_id in vars
      assert :adapter in vars
      assert :mr_ref in vars
      assert :workspace in vars
    end

    test "step_definition(:read_thread) has no needs and references :thread, :comment_id" do
      defn = ReviewReply.step_definition(:read_thread)
      assert defn.needs == []
      assert :thread in defn.vars
      assert :comment_id in defn.vars
      assert is_binary(defn.description)
    end

    test "step_definition(:compose_reply) depends on :read_thread" do
      assert ReviewReply.step_definition(:compose_reply).needs == [:read_thread]
    end

    test "step_definition(:post_reply) depends on :compose_reply" do
      assert ReviewReply.step_definition(:post_reply).needs == [:compose_reply]
    end

    test "module does not call submit_review, merge, or Worktree.push" do
      source = File.read!(Path.expand("../../../lib/arbiter/workflows/review_reply.ex", __DIR__))

      stripped =
        Regex.replace(~r/@moduledoc\s+"""(.|\n)*?"""/m, source, "", global: false)

      refute stripped =~ "submit_review"
      refute stripped =~ "Merger.merge"
      refute stripped =~ "Worktree.push"
    end
  end

  # ==========================================================================
  # :read_thread
  # ==========================================================================

  describe "run_step(:read_thread, ...)" do
    test "valid thread + comment_id assembles thread_context and stores it" do
      state = %{thread: thread(), comment_id: 102}
      assert {:ok, new_state} = ReviewReply.run_step(:read_thread, state)
      assert is_binary(new_state.thread_context)
      assert new_state.thread_context =~ "lib/foo.ex"
      assert new_state.thread_context =~ "@@ -40"
    end

    test "thread context includes the comment thread when comments list is present" do
      t = thread()
      state = %{thread: t, comment_id: 102}
      {:ok, %{thread_context: ctx}} = ReviewReply.run_step(:read_thread, state)
      assert ctx =~ "Thread:"
      assert ctx =~ "reviewer: Why did you add this line here?"
      assert ctx =~ "author: To fix the nil guard"
    end

    test "falls back to :body when comments list is empty" do
      t = thread(%{comments: [], body: "Is this safe?"})
      state = %{thread: t, comment_id: 99}
      {:ok, %{thread_context: ctx}} = ReviewReply.run_step(:read_thread, state)
      assert ctx =~ "Opening comment: Is this safe?"
    end

    test "omits path/diff_hunk sections when absent" do
      t = thread(%{path: nil, diff_hunk: nil, comments: [], body: "Why?"})
      state = %{thread: t, comment_id: 99}
      {:ok, %{thread_context: ctx}} = ReviewReply.run_step(:read_thread, state)
      refute ctx =~ "File:"
      refute ctx =~ "Diff context:"
    end

    test "missing :thread returns {:error, {:bad_state, _}}" do
      assert {:error, {:bad_state, _}} = ReviewReply.run_step(:read_thread, %{comment_id: 1})
    end

    test "missing :comment_id returns {:error, {:bad_state, _}}" do
      assert {:error, {:bad_state, _}} = ReviewReply.run_step(:read_thread, %{thread: thread()})
    end

    test "non-positive comment_id returns {:error, {:bad_state, _}}" do
      assert {:error, {:bad_state, _}} =
               ReviewReply.run_step(:read_thread, %{thread: thread(), comment_id: 0})
    end
  end

  # ==========================================================================
  # :compose_reply
  # ==========================================================================

  describe "run_step(:compose_reply, ...)" do
    test "uses injected :reply_composer" do
      state = %{
        thread_context: "File: lib/foo.ex\n\nThread:\nauthor: Why?",
        reply_composer: stub_composer("Because nil safety.")
      }

      assert {:ok, %{reply_body: "Because nil safety."}} =
               ReviewReply.run_step(:compose_reply, state)
    end

    test "uses Application env :review_reply_composer when no state composer" do
      Application.put_env(:arbiter, :review_reply_composer, stub_composer("App env reply."))
      on_exit(fn -> Application.delete_env(:arbiter, :review_reply_composer) end)

      state = %{thread_context: "some context"}
      assert {:ok, %{reply_body: "App env reply."}} = ReviewReply.run_step(:compose_reply, state)
    end

    test "trims whitespace from the reply body" do
      state = %{
        thread_context: "some context",
        reply_composer: fn _ctx, _state -> {:ok, "  trimmed reply\n"} end
      }

      assert {:ok, %{reply_body: "trimmed reply"}} = ReviewReply.run_step(:compose_reply, state)
    end

    test "returns error when composer returns empty string" do
      state = %{
        thread_context: "ctx",
        reply_composer: fn _ctx, _state -> {:ok, ""} end
      }

      assert {:error, {:compose_failed, :empty_reply}} =
               ReviewReply.run_step(:compose_reply, state)
    end

    test "propagates composer errors" do
      state = %{
        thread_context: "ctx",
        reply_composer: fn _ctx, _state -> {:error, :claude_unavailable} end
      }

      assert {:error, :claude_unavailable} = ReviewReply.run_step(:compose_reply, state)
    end

    test "returns bad_state when :thread_context is missing" do
      assert {:error, {:bad_state, _}} = ReviewReply.run_step(:compose_reply, %{})
    end
  end

  # ==========================================================================
  # :post_reply
  # ==========================================================================

  describe "run_step(:post_reply, ...) — adapter with reply_to_review_comment/4" do
    test "calls reply_to_review_comment/4 with (mr_ref, comment_id, reply_body, opts)" do
      Process.register(self(), :review_reply_test_pid)

      try do
        state = %{
          adapter: Stubs.ReplySpy,
          mr_ref: "#77",
          comment_id: 102,
          reply_body: "Yes, that is correct."
        }

        assert {:ok, %{posted_comment: %{id: 9001}}} = ReviewReply.run_step(:post_reply, state)
        assert_received {:replied, "#77", 102, "Yes, that is correct."}
      after
        Process.unregister(:review_reply_test_pid)
      end
    end

    test "propagates adapter reply errors" do
      state = %{
        adapter: Stubs.ReplyError,
        mr_ref: "#1",
        comment_id: 5,
        reply_body: "A reply."
      }

      assert {:error, :forbidden} = ReviewReply.run_step(:post_reply, state)
    end
  end

  describe "run_step(:post_reply, ...) — adapter without reply_to_review_comment/4" do
    test "falls back to add_comment/2 when reply_to_review_comment is not exported" do
      Process.register(self(), :review_reply_test_pid)

      try do
        state = %{
          adapter: Stubs.FallbackSpy,
          mr_ref: "#55",
          comment_id: 8,
          reply_body: "Fallback reply."
        }

        assert {:ok, %{posted_comment: :fallback_comment}} =
                 ReviewReply.run_step(:post_reply, state)

        assert_received {:fallback_comment, "#55", "Fallback reply."}
      after
        Process.unregister(:review_reply_test_pid)
      end
    end
  end

  describe "run_step(:post_reply, ...) — missing keys" do
    test "returns {:error, {:bad_state, _}} when adapter missing" do
      assert {:error, {:bad_state, _}} =
               ReviewReply.run_step(:post_reply, %{mr_ref: "#1", comment_id: 1, reply_body: "x"})
    end
  end

  # ==========================================================================
  # End-to-end — compose → reply
  # ==========================================================================

  describe "Arbiter.Workflow.run/2 — end-to-end compose→reply" do
    test "full workflow posts a reply and completes all steps" do
      Process.register(self(), :review_reply_test_pid)

      try do
        initial = %{
          adapter: Stubs.ReplySpy,
          mr_ref: "#42",
          thread: thread(),
          comment_id: 102,
          reply_composer: stub_composer("Correct — the nil guard prevents a crash on empty input.")
        }

        assert {:ok, final} = Arbiter.Workflow.run(ReviewReply, initial)

        assert final.completed_steps == [:read_thread, :compose_reply, :post_reply]
        assert is_binary(final.thread_context)
        assert final.reply_body == "Correct — the nil guard prevents a crash on empty input."
        assert final.posted_comment == %{id: 9001}

        assert_received {:replied, "#42", 102,
                         "Correct — the nil guard prevents a crash on empty input."}
      after
        Process.unregister(:review_reply_test_pid)
      end
    end

    test "fails cleanly on a read_thread error (bad comment_id)" do
      initial = %{
        adapter: Stubs.ReplySpy,
        mr_ref: "#1",
        thread: thread(),
        comment_id: -1,
        reply_composer: stub_composer("irrelevant")
      }

      assert {:error, {:read_thread, {:bad_state, _}}} = Arbiter.Workflow.run(ReviewReply, initial)
    end

    test "fails cleanly on a compose error" do
      initial = %{
        adapter: Stubs.ReplySpy,
        mr_ref: "#1",
        thread: thread(),
        comment_id: 102,
        reply_composer: fn _ctx, _state -> {:error, :timeout} end
      }

      assert {:error, {:compose_reply, :timeout}} = Arbiter.Workflow.run(ReviewReply, initial)
    end

    test "fails cleanly on a post error" do
      initial = %{
        adapter: Stubs.ReplyError,
        mr_ref: "#1",
        thread: thread(),
        comment_id: 102,
        reply_composer: stub_composer("a reply")
      }

      assert {:error, {:post_reply, :forbidden}} = Arbiter.Workflow.run(ReviewReply, initial)
    end

    test "no verdict, no worktree writes, no tracker writes in the final state" do
      Process.register(self(), :review_reply_test_pid)

      try do
        initial = %{
          adapter: Stubs.ReplySpy,
          mr_ref: "#10",
          thread: thread(),
          comment_id: 102,
          reply_composer: stub_composer("Looks good to me.")
        }

        assert {:ok, final} = Arbiter.Workflow.run(ReviewReply, initial)

        refute Map.has_key?(final, :verdict)
        refute Map.has_key?(final, :worktree_path)
      after
        Process.unregister(:review_reply_test_pid)
      end
    end
  end
end
