defmodule Arbiter.Test.StubMerger do
  @moduledoc """
  In-memory `Arbiter.Mergers.Merger` adapter for tests.

  Backed by a single named `Agent` so it can be observed from a different
  process than the one that configured it — the `Arbiter.Worker.Watchdog`
  polls from its own process, so a process-dictionary stub wouldn't do.

  Usage:

      StubMerger.reset()
      StubMerger.queue_get("!1", [%{status: :open, approved: false}, %{status: :merged}])

  Each `get/1` pops the next queued result for that ref; once the queue is
  drained the last result repeats. `merge/1` records the call (assert via
  `merge_count/1`). `open/4` records its args (assert via `last_open/0`) and
  returns the ref from `next_open_ref/0` (default `"!stub"`).
  """

  @behaviour Arbiter.Mergers.Merger

  @name __MODULE__.Store

  # ---- test-facing API ----------------------------------------------------

  def reset do
    ensure_started()

    Agent.update(@name, fn _ ->
      %{
        gets: %{},
        merges: %{},
        open_ref: "!stub",
        opens: [],
        review_feedbacks: %{},
        review_threads: %{},
        update_branches: %{},
        update_branch_result: :ok,
        failing_checks: %{},
        merge_result: :ok,
        inline_comments: [],
        submitted_reviews: []
      }
    end)

    :ok
  end

  @doc "All inline comments posted via post_inline_comment/3 (newest first)."
  def inline_comments do
    ensure_started()
    Agent.get(@name, fn s -> Map.get(s, :inline_comments, []) end)
  end

  @doc "All reviews submitted via submit_review/4 (newest first)."
  def submitted_reviews do
    ensure_started()
    Agent.get(@name, fn s -> Map.get(s, :submitted_reviews, []) end)
  end

  @doc "Queue the sequence of `get/1` result maps returned for `ref`."
  def queue_get(ref, results) when is_list(results) do
    ensure_started()
    Agent.update(@name, fn s -> put_in(s, [:gets, ref], results) end)
    :ok
  end

  @doc "Set the ref that the next `open/4` returns."
  def next_open_ref(ref) when is_binary(ref) do
    ensure_started()
    Agent.update(@name, fn s -> %{s | open_ref: ref} end)
    :ok
  end

  @doc "How many times `merge/1` was called for `ref`."
  def merge_count(ref) do
    ensure_started()
    Agent.get(@name, fn s -> Map.get(s.merges, ref, 0) end)
  end

  @doc "The args of the most recent `open/4` call, or nil."
  def last_open do
    ensure_started()
    Agent.get(@name, fn s -> List.first(s.opens) end)
  end

  @doc "Set the `list_review_feedback/1` result for `ref`."
  def set_review_feedback(ref, feedback) when is_map(feedback) do
    ensure_started()
    Agent.update(@name, fn s -> put_in(s, [:review_feedbacks, ref], feedback) end)
    :ok
  end

  @doc "Set the `list_open_review_threads/1` result list for `ref`."
  def set_review_threads(ref, threads) when is_list(threads) do
    ensure_started()
    Agent.update(@name, fn s -> put_in(s, [:review_threads, ref], threads) end)
    :ok
  end

  @doc "How many times `update_branch/1` was called for `ref`."
  def update_branch_count(ref) do
    ensure_started()
    Agent.get(@name, fn s -> Map.get(s.update_branches, ref, 0) end)
  end

  @doc "Set the result `update_branch/1` returns (`:ok` or `{:error, term}`)."
  def set_update_branch_result(result) do
    ensure_started()
    Agent.update(@name, fn s -> %{s | update_branch_result: result} end)
    :ok
  end

  @doc "Set the result `merge/1` returns (`:ok` or `{:error, term}`)."
  def set_merge_result(result) do
    ensure_started()
    Agent.update(@name, fn s -> %{s | merge_result: result} end)
    :ok
  end

  @doc "Set the `failing_check_logs/1` result list for `ref`."
  def set_failing_checks(ref, checks) when is_list(checks) do
    ensure_started()
    Agent.update(@name, fn s -> put_in(s, [:failing_checks, ref], checks) end)
    :ok
  end

  # ---- Merger behaviour ---------------------------------------------------

  @impl true
  def open(branch, title, description, opts) do
    ensure_started()

    Agent.update(@name, fn s ->
      %{
        s
        | opens: [%{branch: branch, title: title, description: description, opts: opts} | s.opens]
      }
    end)

    ref = Agent.get(@name, & &1.open_ref)
    {:ok, ref}
  end

  @impl true
  def get(ref) do
    ensure_started()

    defaults = %{
      status: :open,
      approved: false,
      ci_clean: false,
      conflicting: false,
      changes_requested: false,
      latest_review_id: nil,
      pipeline: nil
    }

    result =
      Agent.get_and_update(@name, fn s ->
        case Map.get(s.gets, ref, []) do
          [only] -> {Map.merge(defaults, only), s}
          [head | rest] -> {Map.merge(defaults, head), put_in(s, [:gets, ref], rest)}
          [] -> {defaults, s}
        end
      end)

    {:ok, result}
  end

  @impl true
  def merge(ref) do
    ensure_started()

    Agent.get_and_update(@name, fn s ->
      s = update_in(s, [:merges, ref], &((&1 || 0) + 1))
      {s.merge_result, s}
    end)
  end

  @impl true
  def update_branch(ref) do
    ensure_started()

    Agent.get_and_update(@name, fn s ->
      s = update_in(s, [:update_branches, ref], &((&1 || 0) + 1))
      {s.update_branch_result, s}
    end)
  end

  @impl true
  def failing_check_logs(ref) do
    ensure_started()
    checks = Agent.get(@name, fn s -> Map.get(s.failing_checks, ref, []) end)
    {:ok, checks}
  end

  @impl true
  def close(_ref), do: :ok

  @impl true
  def add_comment(_ref, _body), do: :ok

  @impl true
  def request_review(_ref, _reviewers), do: :ok

  @impl true
  def link_for(ref), do: "https://stub.example/mr/" <> ref

  @impl true
  def get_diff(_ref, _opts), do: {:ok, ""}

  @impl true
  def post_inline_comment(ref, finding, opts) do
    ensure_started()

    Agent.update(@name, fn s ->
      update_in(s, [:inline_comments], fn cs ->
        [%{ref: ref, finding: finding, opts: opts} | cs || []]
      end)
    end)

    {:ok, %{id: 1}}
  end

  @impl true
  def submit_review(ref, verdict, body, opts) do
    ensure_started()

    Agent.update(@name, fn s ->
      update_in(s, [:submitted_reviews], fn rs ->
        [%{ref: ref, verdict: verdict, body: body, opts: opts} | rs || []]
      end)
    end)

    {:ok, %{}}
  end

  @impl true
  def list_review_feedback(ref) do
    ensure_started()
    default = %{changes_requested: false, latest_review_id: nil, feedback: []}
    result = Agent.get(@name, fn s -> Map.get(s.review_feedbacks, ref, default) end)
    {:ok, result}
  end

  @impl true
  def list_open_review_threads(ref) do
    ensure_started()
    threads = Agent.get(@name, fn s -> Map.get(s.review_threads, ref, []) end)
    {:ok, threads}
  end

  @impl true
  def reply_to_review_comment(_ref, _comment_id, _body, _opts), do: {:ok, %{}}

  # ---- internals ----------------------------------------------------------

  defp ensure_started do
    case Process.whereis(@name) do
      nil ->
        case Agent.start(
               fn ->
                 %{
                   gets: %{},
                   merges: %{},
                   open_ref: "!stub",
                   opens: [],
                   review_feedbacks: %{},
                   review_threads: %{},
                   update_branches: %{},
                   update_branch_result: :ok,
                   failing_checks: %{},
                   merge_result: :ok,
                   inline_comments: [],
                   submitted_reviews: []
                 }
               end,
               name: @name
             ) do
          {:ok, _} -> :ok
          {:error, {:already_started, _}} -> :ok
        end

      _pid ->
        :ok
    end
  end
end
