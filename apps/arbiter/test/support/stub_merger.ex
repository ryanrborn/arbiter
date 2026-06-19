defmodule Arbiter.Test.StubMerger do
  @moduledoc """
  In-memory `Arbiter.Mergers.Merger` adapter for tests.

  Backed by a single named `Agent` so it can be observed from a different
  process than the one that configured it — the `Arbiter.Polecat.Warden`
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
    Agent.update(@name, fn _ -> %{gets: %{}, merges: %{}, open_ref: "!stub", opens: []} end)
    :ok
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
    Agent.update(@name, fn s -> update_in(s, [:merges, ref], &((&1 || 0) + 1)) end)
    :ok
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
  def post_inline_comment(_ref, _finding, _opts), do: {:ok, %{}}

  @impl true
  def submit_review(_ref, _verdict, _body, _opts), do: {:ok, %{}}

  @impl true
  def list_review_feedback(_ref),
    do: {:ok, %{changes_requested: false, latest_review_id: nil, feedback: []}}

  # ---- internals ----------------------------------------------------------

  defp ensure_started do
    case Process.whereis(@name) do
      nil ->
        case Agent.start(fn -> %{gets: %{}, merges: %{}, open_ref: "!stub", opens: []} end,
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
