defmodule Arbiter.Workflows.ReviewReply do
  @moduledoc """
  Reply to an author's question on a pull-request review thread.

  Kept DISTINCT from `Arbiter.Workflows.CodeReview` (decision 4: reply and
  re-review are separate workflows/behaviors). This workflow reads the thread
  + diff context, composes a concise answer, and posts it as a threaded
  reply via the adapter's `reply_to_review_comment/4` callback (task E).

  Runs as a `review_only` worker: no worktree, no branch, no tracker writes.
  Routes the composition step through the `review_agent` model slot.

  ## Forbidden actions

  A `review_reply` worker MUST NOT:

    * post a review verdict (`submit_review/4` — no APPROVE/REQUEST_CHANGES)
    * push code (no `Worker.Worktree.push/2`)
    * write to the issue tracker

  These constraints are enforced **statically** — this module simply does not
  call those functions.

  ## Steps

  1. `:read_thread`   — validate inputs, assemble the `thread_context` string
  2. `:compose_reply` — invoke Claude (review_agent slot) to write the reply
  3. `:post_reply`    — post via `adapter.reply_to_review_comment/4`;
                        falls back to `add_comment/2` if the adapter omits it

  ## State

      %{
        adapter: module(),         # implements Merger; must export reply_to_review_comment/4
        mr_ref: String.t(),        # opaque PR ref (minted by the adapter)
        thread: review_thread(),   # the review thread (from list_open_review_threads/1)
        comment_id: pos_integer(), # the specific comment id to reply to
        workspace: Workspace.t() | nil,
        adapter_opts: map(),

        # optional — (thread_context, state) -> {:ok, body} | {:error, term()}
        # inject in tests to avoid calling the real Claude CLI
        reply_composer: (String.t(), map() -> {:ok, String.t()} | {:error, term()}) | nil,

        # populated as steps run:
        thread_context: String.t(),
        reply_body: String.t(),
        posted_comment: term()
      }

  ## Test override

  Set `Application.put_env(:arbiter, :review_reply_composer, fun)` where
  `fun` is a `(thread_context, state) -> {:ok, body} | {:error, term()}`
  function. This bypasses Claude entirely. The default composer shells out
  to `claude --print ... --output-format text`.
  """

  use Arbiter.Workflow,
    steps: [:read_thread, :compose_reply, :post_reply]

  alias Arbiter.Agents
  alias Arbiter.Mergers

  require Logger

  step(:read_thread,
    description: "Validate thread input and assemble context string",
    needs: [],
    vars: [:thread, :comment_id]
  )

  step(:compose_reply,
    description: "Invoke Claude (review_agent slot) to compose the reply",
    needs: [:read_thread],
    vars: [:workspace, :reply_composer]
  )

  step(:post_reply,
    description: "Post the reply via adapter.reply_to_review_comment/4",
    needs: [:compose_reply],
    vars: [:adapter, :mr_ref, :adapter_opts]
  )

  # ---- :read_thread --------------------------------------------------------

  @impl Arbiter.Workflow
  def run_step(:read_thread, %{thread: thread, comment_id: comment_id} = state)
      when is_map(thread) and is_integer(comment_id) and comment_id > 0 do
    {:ok, Map.put(state, :thread_context, build_thread_context(thread))}
  end

  def run_step(:read_thread, state) do
    {:error,
     {:bad_state,
      "read_thread requires :thread (map) and :comment_id (pos_integer), got: " <>
        inspect(Map.take(state, [:thread, :comment_id]))}}
  end

  # ---- :compose_reply -------------------------------------------------------

  def run_step(:compose_reply, %{thread_context: ctx} = state) do
    prepare_review_agent(state)
    composer = Map.get(state, :reply_composer) || resolve_composer()

    case composer.(ctx, state) do
      {:ok, body} when is_binary(body) and body != "" ->
        {:ok, Map.put(state, :reply_body, String.trim(body))}

      {:ok, _} ->
        {:error, {:compose_failed, :empty_reply}}

      {:error, _} = err ->
        err
    end
  end

  def run_step(:compose_reply, _state),
    do: {:error, {:bad_state, "compose_reply requires :thread_context from :read_thread"}}

  # ---- :post_reply ----------------------------------------------------------

  def run_step(
        :post_reply,
        %{adapter: adapter, mr_ref: mr_ref, comment_id: comment_id, reply_body: body} = state
      )
      when is_atom(adapter) and is_binary(mr_ref) and is_integer(comment_id) and is_binary(body) do
    prepare_adapter(state)
    opts = adapter_opts(state)

    Code.ensure_loaded(adapter)

    if function_exported?(adapter, :reply_to_review_comment, 4) do
      case safe_adapter_call(adapter, :reply_to_review_comment, [mr_ref, comment_id, body, opts]) do
        {:ok, response} ->
          {:ok, Map.put(state, :posted_comment, response)}

        {:error, _} = err ->
          err
      end
    else
      # Adapter doesn't support in-thread replies; fall back to a top-level comment.
      case safe_adapter_call(adapter, :add_comment, [mr_ref, body]) do
        :ok -> {:ok, Map.put(state, :posted_comment, :fallback_comment)}
        {:ok, response} -> {:ok, Map.put(state, :posted_comment, response)}
        {:error, _} = err -> err
      end
    end
  end

  def run_step(:post_reply, _state),
    do: {:error, {:bad_state, "post_reply requires :adapter, :mr_ref, :comment_id, :reply_body"}}

  # ---- helpers --------------------------------------------------------------

  defp build_thread_context(thread) do
    parts = []

    parts =
      case Map.get(thread, :path) do
        p when is_binary(p) and p != "" -> ["File: #{p}" | parts]
        _ -> parts
      end

    parts =
      case Map.get(thread, :diff_hunk) do
        h when is_binary(h) and h != "" -> ["Diff context:\n#{h}" | parts]
        _ -> parts
      end

    comments = Map.get(thread, :comments) || []

    parts =
      if comments != [] do
        lines =
          Enum.map(comments, fn c ->
            author = Map.get(c, :author) || "unknown"
            body = Map.get(c, :body) || ""
            "#{author}: #{body}"
          end)

        ["Thread:\n" <> Enum.join(lines, "\n") | parts]
      else
        case Map.get(thread, :body) do
          b when is_binary(b) and b != "" -> ["Opening comment: #{b}" | parts]
          _ -> parts
        end
      end

    parts
    |> Enum.reverse()
    |> Enum.join("\n\n")
  end

  defp build_prompt(thread_context) do
    """
    You are a code reviewer answering a follow-up question on a pull request
    review thread. Compose a concise, helpful reply that directly addresses
    the author's question or concern. Be specific and clear. Respond with the
    text of your reply only — no preamble.

    #{thread_context}

    Reply:
    """
  end

  defp resolve_composer do
    Application.get_env(:arbiter, :review_reply_composer) || (&default_compose/2)
  end

  defp default_compose(thread_context, _state) do
    case System.find_executable("claude") do
      nil ->
        {:error, {:executable_not_found, "claude"}}

      path ->
        prompt = build_prompt(thread_context)
        args = ["--print", prompt, "--output-format", "text"]

        # Append the review_agent model when seeded (Agents.prepare/2 puts the
        # config in the process dict; Claude.Config reads it back here).
        args =
          case Arbiter.Agents.Claude.Config.active_model() do
            model when is_binary(model) and model != "" -> args ++ ["--model", model]
            _ -> args
          end

        case System.cmd(path, args, stderr_to_stdout: true) do
          {output, 0} -> {:ok, output}
          {output, code} -> {:error, {:claude_failed, code, String.trim(output)}}
        end
    end
  rescue
    e -> {:error, {:exception, Exception.message(e)}}
  end

  defp prepare_review_agent(%{workspace: ws}) when not is_nil(ws),
    do: Agents.prepare(ws, :review_agent)

  defp prepare_review_agent(_), do: :ok

  defp prepare_adapter(%{workspace: ws}) when not is_nil(ws), do: Mergers.prepare(ws)
  defp prepare_adapter(_), do: :ok

  defp adapter_opts(state), do: Map.get(state, :adapter_opts, %{})

  defp safe_adapter_call(adapter, fun, args) do
    apply(adapter, fun, args)
  rescue
    e -> {:error, {:exception, Exception.message(e)}}
  catch
    :exit, reason -> {:error, {:exit, reason}}
  end
end
