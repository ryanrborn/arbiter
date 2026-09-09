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
  alias Arbiter.Agents.Claude, as: ClaudeAdapter
  alias Arbiter.Agents.Claude.Config, as: ClaudeConfig
  alias Arbiter.Mergers

  require Logger

  # A future CLI change could reintroduce a different stdin/startup diagnostic
  # on this same path (bd-79s7i1) — this strip is a backstop, not the fix.
  # The structural fix is in `default_compose/2`: stdin is explicitly closed
  # (`< /dev/null`) via `ClaudeAdapter.build_argv/3` so the CLI never times out
  # waiting for input, and only stdout is captured (stderr is left to inherit
  # the parent's, never merged in), so a diagnostic can't ride into the body
  # via either route.
  @cli_diagnostic_line ~r/\A\s*Warning: no stdin data received[^\n]*\n?/

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
        body = body |> String.trim_leading() |> strip_cli_diagnostic() |> String.trim()

        if body == "" do
          {:error, {:compose_failed, :empty_reply}}
        else
          {:ok, Map.put(state, :reply_body, body)}
        end

      {:ok, _} ->
        {:error, {:compose_failed, :empty_reply}}

      {:error, _} = err ->
        err
    end
  end

  def run_step(:compose_reply, _state),
    do: {:error, {:bad_state, "compose_reply requires :thread_context from :read_thread"}}

  # ---- :post_reply ----------------------------------------------------------

  # Pre-existing complexity 10 — baselined when bd-4x2yhq first
  # wired Credo up. Thresholds stay at the tool's own default so new
  # code is held to it; see the note in .credo.exs.
  # credo:disable-for-next-line Credo.Check.Refactor.CyclomaticComplexity
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

  # Pre-existing complexity 14 — baselined when bd-4x2yhq first
  # wired Credo up. Thresholds stay at the tool's own default so new
  # code is held to it; see the note in .credo.exs.
  # credo:disable-for-next-line Credo.Check.Refactor.CyclomaticComplexity
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

  defp strip_cli_diagnostic(body), do: Regex.replace(@cli_diagnostic_line, body, "")

  # `ClaudeAdapter.build_argv/3` wraps the spawn in `sh -c 'exec "$@" <
  # /dev/null'` (or the stdin-tmpfile variant for an oversized prompt) — the
  # same E2BIG-safe, stdin-closed invocation every other Claude spawn in
  # Arbiter uses. Before this fix this composer called `System.cmd/3`
  # directly with no stdin redirection at all and `stderr_to_stdout: true`,
  # so a stdin pipe that was never written left the CLI waiting, it emitted
  # its "no stdin data received in 3s" warning, and `stderr_to_stdout`
  # spliced that warning onto the front of the captured output — which this
  # composer then posted verbatim as the reply body (bd-79s7i1). Closing
  # stdin explicitly means the CLI never waits and never warns; capturing
  # only stdout (no `stderr_to_stdout`) means a diagnostic printed to stderr
  # can't reach the body even if the CLI's behavior changes again. `path` is
  # the Claude CLI location resolved from Arbiter's own agent config, not
  # from a request or a task field, so there's no shell-injection surface in
  # `sh -c` here.
  defp default_compose(thread_context, _state) do
    case System.find_executable("claude") do
      nil ->
        {:error, {:executable_not_found, "claude"}}

      path ->
        prompt = build_prompt(thread_context)
        flags = compose_flags()

        with {:ok, argv} <- ClaudeAdapter.build_argv(path, prompt, flags) do
          run_claude(argv)
        end
    end
  rescue
    e -> {:error, {:exception, Exception.message(e)}}
  end

  defp compose_flags do
    flags = ["--output-format", "text"]

    # Append the review_agent model when seeded (Agents.prepare/2 puts the
    # config in the process dict; Claude.Config reads it back here).
    case ClaudeConfig.active_model() do
      model when is_binary(model) and model != "" -> flags ++ ["--model", model]
      _ -> flags
    end
  end

  # `argv` comes from `ClaudeAdapter.build_argv/3` above, built from `path`
  # (resolved from Arbiter's own agent config, never a request field), so
  # there's no shell-injection surface here.
  # sobelow_skip ["CI.System"]
  defp run_claude([cmd | args] = argv) do
    case System.cmd(cmd, args) do
      {output, 0} -> {:ok, output}
      {output, code} -> {:error, {:claude_failed, code, String.trim(output)}}
    end
  after
    case ClaudeAdapter.prompt_tmpfile(argv) do
      nil -> :ok
      tmp -> File.rm(tmp)
    end
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
