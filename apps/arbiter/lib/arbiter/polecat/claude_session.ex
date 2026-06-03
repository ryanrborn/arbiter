defmodule Arbiter.Polecat.ClaudeSession do
  @moduledoc """
  Port wrapper that runs a child process (eventually Claude Code CLI) inside a
  worktree and streams its stdout into a parent `Arbiter.Polecat` GenServer.

  This is Phase 2's I/O surface for the polecat. **No tmux** — we drive Claude
  Code (or any echo-script spike) directly through an Erlang `Port` so the
  parent process sees output line-by-line and can react to completion signals
  without polling a tty.

  ## Architecture

      caller (the polecat)
        │
        ▼
      ClaudeSession.start(opts)
        │   (synchronous GenServer.call to the owner polecat)
        ▼
      polecat handle_call(:__start_session__)
        │   Port.open/2 — polecat becomes the port owner
        ▼
      polecat handle_info({port, ...})
        │   • append line to meta[:output_lines]   (cap @line_cap)
        │   • Phoenix.PubSub.broadcast {:polecat_output, bead_id, line}
        │   • on "arb done" → Polecat.complete(self())
        │   • on {:exit_status, n} → meta[:exit_status], broadcast :polecat_exited
        ▼

  We deliberately open the `Port` *from inside* the polecat's process (via a
  GenServer.call hop) so the polecat itself owns the port. Port messages only
  flow to the port owner; if `ClaudeSession.start/1` opened the port in the
  caller process and then tried to hand it over, we'd race ownership transfer
  against early child output. The GenServer.call hop is synchronous from the
  caller's perspective and avoids that footgun.

  ## Invocation & streaming

  Real Claude runs use `claude --print <prompt> --output-format stream-json
  --verbose`, wrapped in `sh -c 'exec "$@" < /dev/null'` so the child's stdin
  is closed immediately (otherwise the CLI prints a "no stdin data received in
  3s" warning that pollutes the transcript). The prompt is passed as a literal
  positional parameter to `sh`, never interpolated into the command string, so
  there is no shell-injection surface.

  `--output-format stream-json` emits one JSON event per line (JSONL): a
  `system`/`init` header, one `assistant` event per turn (text + tool calls),
  `user` events carrying tool results, and a final `result` summary. We parse
  each line and emit human-readable display lines so the UI tails the session
  in near-real-time instead of waiting for the whole run to flush at exit.

  Lines that don't parse as a stream-json event (test echo scripts, non-Claude
  spikes, stray stderr) fall through unchanged to the raw-line path, so the
  PubSub/line-cap plumbing behaves identically for them.

  ## Completion detection

  A display line matching `~r/\\barb done\\b/` triggers `Polecat.complete/2`.
  The regex is intentionally word-bounded so the substring "arb doneness"
  doesn't trip it — but a literal marker line like `arb done` (or
  `>> arb done <<`) does. Under stream-json, detection is scoped to the
  acolyte's **assistant text** (and the raw-line fallback): tool calls and tool
  *results* are displayed but never trip completion, so an acolyte that greps
  or cats "arb done" mid-task can't falsely complete itself.

  ## Output buffering

  We keep at most `#{1000}` recent lines in `meta[:output_lines]` to avoid
  unbounded memory growth on chatty children. The list is stored newest-first
  for O(1) prepend; flip with `Enum.reverse/1` for display. The cap is
  arbitrary; reviewers should weigh it against expected Claude session length.
  No back-pressure to the child — we never block on slow consumers.

  ## Durable transcript

  The capped buffer above is for *liveness* — it bounds memory and feeds the
  UI tail. For audit, every emitted line is *also* appended, uncapped, to a
  per-run on-disk transcript via `Arbiter.Polecat.OutputLog`, when the session
  was opened with an `:output_log` handle (the polecat opens one keyed on the
  run id). This durable capture sits alongside the live path and never gates
  it: a session opened without a handle behaves exactly as before.

  ## PubSub topic

  Default topic is `"polecat:" <> bead_id`. Subscribers (LiveView, CLI
  followers, tests) must know the bead_id to subscribe. The `:topic` opt
  overrides this.
  """

  alias Arbiter.Polecat
  alias Arbiter.Polecat.OutputLog

  @line_cap 1000
  @done_regex ~r/\barb done\b/

  @typedoc "Accepted options for `start/1`."
  @type opt ::
          {:worktree_path, String.t()}
          | {:prompt, String.t()}
          | {:command, [String.t()] | nil}
          | {:topic, String.t() | nil}
          | {:owner, pid()}

  @type opts :: [opt()]

  @doc false
  def line_cap, do: @line_cap

  @doc false
  def done_regex, do: @done_regex

  @doc """
  Start a Claude (or echo-spike) session in `worktree_path`, streaming output
  into the `:owner` polecat.

  ## Required opts

    * `:worktree_path` — absolute path, must exist. The child runs with this
      as cwd.
    * `:owner` — pid of the parent polecat GenServer. Becomes the port owner
      and receives all port messages.

  ## Optional opts

    * `:prompt` — passed to Claude as the prompt. Required when `:command`
      is `nil` (real Claude invocation).
    * `:command` — full argv list as `[exec, arg1, arg2, ...]`. When set,
      overrides the default streaming `claude` invocation and is spawned
      verbatim (no `sh`/stdin wrapping). Tests **must** pass this so we don't
      shell out to real Claude.
    * `:topic` — PubSub topic to broadcast output on. Defaults to
      `"polecat:" <> bead_id`.

  ## Returns

    * `{:ok, port}` on success. The port is owned by the `:owner` polecat.
    * `{:error, reason}` if the executable can't be resolved or the worktree
      path is invalid.
  """
  @spec start(opts()) :: {:ok, port()} | {:error, term()}
  def start(opts) when is_list(opts) do
    with {:ok, owner} <- fetch_owner(opts),
         {:ok, worktree_path} <- fetch_worktree(opts),
         {:ok, argv} <- resolve_argv(opts),
         {:ok, exec} <- resolve_executable(argv) do
      bead_id = bead_id_for(owner)
      topic = Keyword.get(opts, :topic) || default_topic(bead_id)

      session_config = %{
        bead_id: bead_id,
        topic: topic,
        line_cap: @line_cap,
        done_regex: @done_regex
      }

      port_args = %{
        exec: exec,
        argv: argv,
        cd: worktree_path
      }

      GenServer.call(owner, {:__claude_session_open__, port_args, session_config})
    end
  end

  # ---- option resolution -------------------------------------------------

  defp fetch_owner(opts) do
    case Keyword.fetch(opts, :owner) do
      {:ok, pid} when is_pid(pid) -> {:ok, pid}
      _ -> {:error, :missing_owner}
    end
  end

  defp fetch_worktree(opts) do
    case Keyword.fetch(opts, :worktree_path) do
      {:ok, path} when is_binary(path) ->
        if File.dir?(path), do: {:ok, path}, else: {:error, {:invalid_worktree, path}}

      _ ->
        {:error, :missing_worktree_path}
    end
  end

  defp resolve_argv(opts) do
    case Keyword.get(opts, :command) do
      nil ->
        case Keyword.fetch(opts, :prompt) do
          {:ok, prompt} when is_binary(prompt) ->
            default_claude_argv(prompt)

          _ ->
            {:error, :missing_prompt}
        end

      [exec | _rest] = argv when is_binary(exec) ->
        {:ok, argv}

      _ ->
        {:error, :invalid_command}
    end
  end

  # Real Claude invocation. We stream with `--output-format stream-json
  # --verbose` (the CLI requires `--verbose` alongside stream-json under
  # `--print`) so the parent port sees per-turn events instead of a single
  # buffered blob at exit.
  #
  # The whole thing is wrapped in `sh -c 'exec "$@" < /dev/null'` so the
  # child's stdin is closed immediately — without this the CLI waits ~3s for
  # piped stdin and prints a warning that pollutes the transcript. The claude
  # path and prompt are passed as positional params ("$@"), never spliced into
  # the command string, so there is no shell-injection surface.
  defp default_claude_argv(prompt) do
    case resolve_claude() do
      {:ok, claude} ->
        inner = [claude, "--print", prompt, "--output-format", "stream-json", "--verbose"]
        {:ok, ["sh", "-c", ~s(exec "$@" < /dev/null), "sh" | inner]}

      {:error, _} = err ->
        err
    end
  end

  defp resolve_claude do
    case System.find_executable("claude") do
      nil -> {:error, {:executable_not_found, "claude"}}
      path -> {:ok, path}
    end
  end

  defp resolve_executable([exec | _]) do
    cond do
      String.contains?(exec, "/") and File.exists?(exec) ->
        {:ok, exec}

      String.contains?(exec, "/") ->
        {:error, {:executable_not_found, exec}}

      true ->
        case System.find_executable(exec) do
          nil -> {:error, {:executable_not_found, exec}}
          path -> {:ok, path}
        end
    end
  end

  defp bead_id_for(owner) do
    case Polecat.state(owner) do
      %{bead_id: id} -> id
      _ -> nil
    end
  end

  defp default_topic(nil), do: "polecat:unknown"
  defp default_topic(bead_id), do: "polecat:" <> bead_id

  # ---- helpers called from Polecat's handle_info -------------------------
  #
  # These live here (rather than inlined into polecat.ex) so the port message
  # routing logic stays colocated with the rest of the session module. The
  # polecat just shuttles messages to us.

  @doc """
  Feed one port fragment into the session.

  `eol?` reflects the port's `{:line, _}` framing: `true` for a complete
  logical line (`{:eol, _}`), `false` for a mid-line chunk (`{:noeol, _}`) of a
  line that exceeded the port line limit. We buffer `noeol` fragments and only
  process once a full line has arrived, because a stream-json event split
  across chunks is not valid JSON until reassembled.
  """
  @spec handle_data(map(), binary(), boolean()) :: map()
  def handle_data(%{} = session, fragment, eol?) when is_binary(fragment) do
    buf = Map.get(session, :line_buf, "")

    if eol? do
      process_line(%{session | line_buf: ""}, buf <> fragment)
    else
      %{session | line_buf: buf <> fragment}
    end
  end

  # A complete logical line. If it parses as a stream-json event, expand it into
  # display lines; otherwise treat the raw line as output (test echo scripts,
  # non-Claude spikes, stray stderr). The raw fallback path detects "arb done"
  # so non-stream-json children still signal completion.
  #
  # The `init` and `result` events also carry structured usage (model, tokens,
  # cost, duration) — we accumulate that on the session under `:usage` so the
  # polecat can mint an `Arbiter.Usage.Event` row on session exit.
  defp process_line(%{} = session, line) do
    case decode_event(line) do
      {:ok, event} ->
        session = absorb_usage(session, event)

        event
        |> format_event()
        |> Enum.reduce(session, fn {text, detect?}, acc -> emit_line(acc, text, detect?) end)

      :error ->
        emit_line(session, line, true)
    end
  end

  # Capture structured usage off the two events that carry it. The `init` event
  # tells us the model and session_id up front; the terminal `result` event
  # carries tokens + cost + duration. Both update an in-session `:usage` map
  # that the polecat reads on exit. Best-effort — missing keys leave their slot
  # nil and the row is still persisted (graceful degradation).
  defp absorb_usage(session, %{"type" => "system", "subtype" => "init"} = event) do
    update_usage(session, %{
      model: event["model"],
      session_id: event["session_id"]
    })
  end

  defp absorb_usage(session, %{"type" => "result"} = event) do
    usage = event["usage"] || %{}

    update_usage(session, %{
      tokens_in: number(usage["input_tokens"]),
      tokens_out: number(usage["output_tokens"]),
      cache_creation_tokens: number(usage["cache_creation_input_tokens"]),
      cache_read_tokens: number(usage["cache_read_input_tokens"]),
      cost_usd: number(event["total_cost_usd"]),
      duration_ms: number(event["duration_ms"]),
      result_subtype: event["subtype"],
      is_error: event["is_error"],
      raw: event
    })
  end

  defp absorb_usage(session, _event), do: session

  defp update_usage(%{} = session, fields) do
    existing = Map.get(session, :usage, %{}) || %{}

    merged =
      Enum.reduce(fields, existing, fn {k, v}, acc ->
        case v do
          nil -> acc
          val -> Map.put(acc, k, val)
        end
      end)

    Map.put(session, :usage, merged)
  end

  defp number(n) when is_integer(n), do: n
  defp number(n) when is_float(n), do: n
  defp number(_), do: nil

  @doc """
  Read the accumulated structured usage off a session map.

  Returns an empty map when the session never produced an `init`/`result`
  event (test echo scripts, non-Claude spikes, premature crashes). Callers
  treat that as "graceful degradation" — they may still write a usage row
  with whatever fields they do have.
  """
  @spec usage_summary(map()) :: map()
  def usage_summary(%{} = session), do: Map.get(session, :usage, %{}) || %{}

  # Emit a single display line: broadcast it (unless blank), optionally run
  # completion detection, and accumulate it (cap-bounded). Blank/whitespace-only
  # lines still accumulate (so snapshot rendering preserves spacing) but skip
  # the PubSub hop — live followers only care about lines with content.
  defp emit_line(%{} = session, line, detect_done?) do
    unless blank?(line) do
      broadcast(session, {:polecat_output, session.bead_id, line})
    end

    if detect_done? and Regex.match?(session.done_regex, line) do
      send(self(), {:__claude_session_done__, line})
    end

    append_durable(session, line)

    %{session | output_lines: prepend_capped(session.output_lines, line, session.line_cap)}
  end

  # Append the line to the durable, uncapped per-run transcript when the
  # session carries an :output_log handle. Best-effort and never blocks the
  # live path: a session without a handle (tests, run_id-less polecats) is a
  # no-op.
  defp append_durable(session, line) do
    case Map.get(session, :output_log) do
      nil -> :ok
      handle -> OutputLog.append(handle, line)
    end
  end

  defp blank?(line), do: String.trim(line) == ""

  # Decode a line into a stream-json event map. We require it to look like a
  # JSON object with a "type" key so plain-text lines (which may parse as bare
  # JSON scalars, e.g. "42") fall through to the raw path.
  defp decode_event(line) do
    with "{" <> _ <- String.trim_leading(line),
         {:ok, %{"type" => _} = event} <- Jason.decode(line) do
      {:ok, event}
    else
      _ -> :error
    end
  end

  # Expand a stream-json event into `{display_line, detect_done?}` tuples.
  # Only assistant *text* opts into completion detection (see moduledoc).
  defp format_event(%{"type" => "assistant", "message" => %{"content" => content}})
       when is_list(content) do
    Enum.flat_map(content, &assistant_block_lines/1)
  end

  defp format_event(%{"type" => "user", "message" => %{"content" => content}})
       when is_list(content) do
    Enum.flat_map(content, &tool_result_lines/1)
  end

  defp format_event(%{"type" => "result"} = event), do: [{result_summary(event), false}]

  defp format_event(%{"type" => "system", "subtype" => "init"} = event),
    do: [{init_summary(event), false}]

  # rate_limit_event, partial-message deltas, unknown types: shown to no one.
  defp format_event(_event), do: []

  defp assistant_block_lines(%{"type" => "text", "text" => text}) when is_binary(text) do
    Enum.map(text_lines(text), &{&1, true})
  end

  defp assistant_block_lines(%{"type" => "thinking", "thinking" => text})
       when is_binary(text) do
    Enum.map(text_lines(text), &{&1, false})
  end

  defp assistant_block_lines(%{"type" => "tool_use", "name" => name} = block) do
    [{"⏵ #{name}(#{summarize_tool_input(Map.get(block, "input"))})", false}]
  end

  defp assistant_block_lines(_block), do: []

  # Tool results are displayed (truncated) but never trip completion.
  defp tool_result_lines(%{"type" => "tool_result"} = block) do
    label = if block["is_error"], do: "⏴ tool error", else: "⏴ tool result"

    lines =
      block
      |> Map.get("content")
      |> tool_result_content_text()
      |> text_lines()
      |> Enum.reject(&(&1 == ""))
      |> truncate_lines(40)

    Enum.map([label | lines], &{&1, false})
  end

  defp tool_result_lines(_block), do: []

  defp tool_result_content_text(text) when is_binary(text), do: text

  defp tool_result_content_text(blocks) when is_list(blocks) do
    blocks
    |> Enum.map(fn
      %{"type" => "text", "text" => t} when is_binary(t) -> t
      _ -> ""
    end)
    |> Enum.join("\n")
  end

  defp tool_result_content_text(_), do: ""

  defp summarize_tool_input(input) when is_map(input) do
    cond do
      is_binary(input["command"]) -> truncate(input["command"], 200)
      is_binary(input["file_path"]) -> input["file_path"]
      is_binary(input["path"]) -> input["path"]
      is_binary(input["pattern"]) -> truncate(input["pattern"], 200)
      is_binary(input["description"]) -> truncate(input["description"], 200)
      true -> truncate(Jason.encode!(input), 200)
    end
  end

  defp summarize_tool_input(_), do: ""

  defp init_summary(event) do
    model = event["model"] || "?"
    "⚙ claude session started (model #{model})"
  end

  defp result_summary(event) do
    status = if event["is_error"], do: "error", else: event["subtype"] || "done"
    parts = ["⚙ claude session #{status}"]

    parts =
      case event["duration_ms"] do
        ms when is_integer(ms) -> parts ++ ["#{Float.round(ms / 1000, 1)}s"]
        _ -> parts
      end

    parts =
      case event["total_cost_usd"] do
        cost when is_number(cost) -> parts ++ ["$#{Float.round(cost / 1, 4)}"]
        _ -> parts
      end

    Enum.join(parts, " · ")
  end

  defp text_lines(text) when is_binary(text), do: String.split(text, "\n")
  defp text_lines(_), do: []

  defp truncate_lines(lines, max) do
    case Enum.split(lines, max) do
      {kept, []} -> kept
      {kept, dropped} -> kept ++ ["… (#{length(dropped)} more lines)"]
    end
  end

  defp truncate(str, max) when is_binary(str) do
    if String.length(str) > max, do: String.slice(str, 0, max) <> "…", else: str
  end

  @doc false
  @spec handle_exit(map(), integer()) :: map()
  def handle_exit(%{} = session, status) when is_integer(status) do
    # Flush any buffered partial line the child left without a trailing newline.
    session =
      case Map.get(session, :line_buf, "") do
        "" -> session
        buf -> process_line(%{session | line_buf: ""}, buf)
      end

    broadcast(session, {:polecat_exited, session.bead_id, status})
    close_durable(session)
    %{session | exit_status: status, exited_at: DateTime.utc_now()}
  end

  # Close the durable transcript handle (if any) once the child has exited.
  # The handle is also linked to the polecat, so an unclean death still flushes
  # and closes; this is the clean-exit path.
  defp close_durable(session) do
    case Map.get(session, :output_log) do
      nil -> :ok
      handle -> OutputLog.close(handle)
    end
  end

  defp broadcast(%{topic: topic}, msg) when is_binary(topic) do
    # Phoenix.PubSub.broadcast/3 returns :ok on the no-subscriber case too;
    # we don't care about the return value.
    _ = Phoenix.PubSub.broadcast(Arbiter.PubSub, topic, msg)
    :ok
  end

  defp prepend_capped(list, line, cap) do
    new_list = [line | list]

    if length(new_list) > cap do
      Enum.take(new_list, cap)
    else
      new_list
    end
  end

  @doc false
  @spec open_port(map()) :: port()
  def open_port(%{exec: exec, argv: [_ | rest], cd: cd}) do
    Port.open(
      {:spawn_executable, exec},
      [
        {:args, rest},
        {:cd, cd},
        {:line, 65_536},
        :binary,
        :exit_status,
        :stderr_to_stdout
      ]
    )
  end
end
