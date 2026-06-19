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
  worker's **assistant text** (and the raw-line fallback): tool calls and tool
  *results* are displayed but never trip completion, so an worker that greps
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
          | {:env, [{String.t(), String.t() | false}]}
          | {:provider, String.t() | nil}
          | {:model, String.t() | nil}

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
        done_regex: @done_regex,
        provider: Keyword.get(opts, :provider),
        # Pre-resolved model id for adapters whose stream carries none (Gemini).
        # Claude omits this and learns the model from its `init` event instead.
        model: Keyword.get(opts, :model)
      }

      port_args = %{
        exec: exec,
        argv: argv,
        cd: worktree_path,
        env: env_pairs(opts, bead_id)
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
        # Even this built-in path (workspace-less ReviewGate runs, bare
        # ClaudeSession.start/1 callers) is hardened with the install-wide
        # default security posture, so no worker spawn inherits the operator's
        # personal ~/.claude permission posture (bd-9u10op). Workspace-aware
        # callers route through Arbiter.Agents.Claude.default_argv/2 instead,
        # which resolves a per-domain policy.
        policy = Arbiter.Agents.SecurityPolicy.default()

        inner =
          [claude, "--print", prompt] ++
            Arbiter.Agents.Claude.Security.permission_argv(policy) ++
            Arbiter.Agents.Claude.Security.settings_argv(policy) ++
            ["--output-format", "stream-json", "--verbose"]

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
  #
  # A decoded event also refreshes the session's coarse :activity ("thinking",
  # "editing run.ex", "running tests", …) — the live progress signal the polecat
  # mirrors into meta for claude-driven views, which have no ticking workflow
  # Machine to advance a real step (see Arbiter.Polecat.Driver claude-driven mode
  # and bd-c919xj).
  defp process_line(%{} = session, line) do
    case decode_event(line) do
      {:ok, event} ->
        session =
          session
          |> absorb_usage(event)
          |> scan_split_done(event)

        event
        |> format_event(session)
        |> Enum.reduce(maybe_update_activity(session, event), fn {text, detect?}, acc ->
          emit_line(acc, text, detect?)
        end)

      :error ->
        emit_line(session, line, true)
    end
  end

  # Gemini streams assistant output as `delta: true` chunks, so the `arb done`
  # sentinel can straddle two events that the per-line check in emit_line/3 would
  # miss. Keep a small rolling tail of assistant text and fire completion as soon
  # as the concatenation matches — a safety net alongside (not a replacement for)
  # the per-line detection. The done handler is idempotent, so the belt-and-
  # suspenders double-fire on the common (single-chunk) case is harmless; the
  # `:split_done_fired` flag stops the buffer re-matching on every later chunk.
  # Claude turns aren't chunked this way, so this only engages for Gemini.
  defp scan_split_done(%{provider: "gemini", split_done_fired: true} = session, _event),
    do: session

  defp scan_split_done(
         %{provider: "gemini"} = session,
         %{"type" => "message", "role" => "assistant", "content" => content}
       )
       when is_binary(content) do
    buf = scan_tail(Map.get(session, :split_done_buf, "") <> content)
    session = Map.put(session, :split_done_buf, buf)

    if Regex.match?(session.done_regex, buf) do
      send(self(), {:__claude_session_done__, buf})
      Map.put(session, :split_done_fired, true)
    else
      session
    end
  end

  defp scan_split_done(session, _event), do: session

  # Keep only the last 256 graphemes — enough to span a sentinel split across a
  # chunk boundary without growing unbounded on a long turn.
  defp scan_tail(text) when is_binary(text) do
    if String.length(text) > 256, do: String.slice(text, -256, 256), else: text
  end

  # Capture structured usage off the two events that carry it. The `init` event
  # tells us the model and session_id up front; the terminal `result` event
  # carries tokens + cost + duration. Both update an in-session `:usage` map
  # that the polecat reads on exit. Best-effort — missing keys leave their slot
  # nil and the row is still persisted (graceful degradation).
  # Gemini sessions carry a different stream-json schema, so route their events
  # to the Gemini stream parser (which also derives cost from a price table,
  # since the gemini CLI emits no dollar figure). Provider is set on the session
  # config at spawn time; the `init`/`result` event clauses below are Claude's.
  defp absorb_usage(%{provider: "gemini"} = session, event) do
    update_usage(
      session,
      Arbiter.Agents.Gemini.Stream.usage_fields(event, Map.get(session, :model))
    )
  end

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

  # Refresh the session's activity from a decoded event, stamping :activity_at.
  # Events that carry no salient activity (tool *results*, partial deltas,
  # unknown types) leave the prior activity in place — so "editing run.ex"
  # persists across the tool-result turn until the next action.
  defp maybe_update_activity(%{} = session, event) do
    label =
      case Map.get(session, :provider) do
        "gemini" -> Arbiter.Agents.Gemini.Stream.activity_for_event(event)
        _ -> activity_for_event(event)
      end

    case label do
      nil ->
        session

      label ->
        since =
          case Map.get(session, :activity) do
            %{label: ^label, since: since} -> since
            _ -> DateTime.utc_now()
          end

        session
        |> Map.put(:activity, %{label: label, since: since})
        |> Map.put(:activity_at, since)
    end
  end

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

  # Provider-aware dispatch: Gemini's stream-json events have a different shape,
  # so they're formatted by the Gemini parser. Claude (and the nil/default
  # provider) use the clauses below.
  defp format_event(event, %{provider: "gemini"}),
    do: Arbiter.Agents.Gemini.Stream.format_event(event)

  defp format_event(event, _session), do: format_event(event)

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

  # ---- live activity derivation ------------------------------------------
  #
  # Reduce a stream-json event to a short, human-readable activity phrase — the
  # coarse "what is the worker doing right now" signal a claude-driven view
  # shows in place of a frozen workflow step. Returns nil for events that carry
  # no salient action (tool results, deltas, unknown types) so the caller keeps
  # the previous activity.

  @doc false
  @spec activity_for_event(map()) :: String.t() | nil
  def activity_for_event(%{"type" => "system", "subtype" => "init"}), do: "starting"

  def activity_for_event(%{"type" => "result"}), do: "wrapping up"

  def activity_for_event(%{"type" => "assistant", "message" => %{"content" => content}})
      when is_list(content) do
    # An assistant turn may mix thinking, text, and tool calls. Take the last
    # block that maps to an activity so a turn ending in a tool call reports the
    # tool (the more informative signal) rather than the preceding prose.
    content
    |> Enum.map(&block_activity/1)
    |> Enum.reject(&is_nil/1)
    |> List.last()
  end

  def activity_for_event(_event), do: nil

  defp block_activity(%{"type" => "thinking"}), do: "thinking"

  defp block_activity(%{"type" => "text", "text" => text}) when is_binary(text) do
    if String.trim(text) == "", do: nil, else: "responding"
  end

  defp block_activity(%{"type" => "tool_use", "name" => name} = block),
    do: tool_activity(name, Map.get(block, "input"))

  defp block_activity(_block), do: nil

  defp tool_activity(edit, input) when edit in ~w(Edit Write MultiEdit NotebookEdit),
    do: verb_for(edit) <> " " <> file_label(input)

  defp tool_activity("Read", input), do: "reading " <> file_label(input)
  defp tool_activity("Bash", input), do: bash_activity(input)
  defp tool_activity(search, _input) when search in ~w(Grep Glob), do: "searching"
  defp tool_activity("Task", input), do: "delegating" <> desc_suffix(input)
  defp tool_activity(web, _input) when web in ~w(WebFetch WebSearch), do: "researching"
  # Any other tool (MCP tools, future built-ins) surfaces by its own name rather
  # than a generic placeholder — still a live, changing signal.
  defp tool_activity(name, _input) when is_binary(name) and name != "", do: name
  defp tool_activity(_name, _input), do: nil

  defp verb_for("Read"), do: "reading"
  defp verb_for("Write"), do: "writing"
  defp verb_for(_edit), do: "editing"

  defp file_label(input) when is_map(input) do
    case input["file_path"] || input["path"] || input["notebook_path"] do
      p when is_binary(p) and p != "" -> Path.basename(p)
      _ -> "a file"
    end
  end

  defp file_label(_input), do: "a file"

  defp bash_activity(input) when is_map(input) do
    cmd = input["command"]

    cond do
      is_binary(cmd) and test_command?(cmd) -> "running tests"
      is_binary(cmd) and cmd != "" -> "running: " <> truncate(cmd, 60)
      true -> "running a command"
    end
  end

  defp bash_activity(_input), do: "running a command"

  defp test_command?(cmd),
    do: Regex.match?(~r/\b(mix test|npm test|pytest|go test|cargo test|rspec|jest)\b/, cmd)

  defp desc_suffix(input) when is_map(input) do
    case input["description"] do
      d when is_binary(d) and d != "" -> " (" <> truncate(d, 40) <> ")"
      _ -> ""
    end
  end

  defp desc_suffix(_input), do: ""

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
  def open_port(%{exec: exec, argv: [_ | rest], cd: cd} = port_args) do
    base_opts = [
      {:args, rest},
      {:cd, cd},
      {:line, 65_536},
      :binary,
      :exit_status,
      :stderr_to_stdout
    ]

    opts =
      case Map.get(port_args, :env, []) do
        [] -> base_opts
        pairs -> base_opts ++ [{:env, env_charlists(pairs)}]
      end

    Port.open({:spawn_executable, exec}, opts)
  end

  # The Agent behaviour returns env as [{String.t(), String.t() | false}]
  # for ergonomics; Port.open wants charlists. Normalize once at the
  # boundary so adapters don't have to know about Erlang's I/O list shape.
  defp env_charlists(pairs) do
    Enum.map(pairs, fn
      {name, false} ->
        {to_charlist(name), false}

      {name, value} when is_binary(name) and is_binary(value) ->
        {to_charlist(name), to_charlist(value)}
    end)
  end

  # When the caller passes an explicit `:env` (the workspace-aware Dispatch /
  # ReviewGate path always does, via the adapter's spawn_env/1) we use it
  # verbatim. When it's absent (bare ClaudeSession.start/1 callers, the
  # workspace-less ReviewGate path) we default to the isolated CLAUDE_CONFIG_DIR
  # so even those spawns don't inherit the operator's ~/.claude. In the test
  # env config isolation is disabled, so this resolves to [] there.
  #
  # bd-crqku8: always inject ARB_ACOLYTE_BEAD_ID so any `arb restart/update/
  # start` invoked from inside the worker session can detect it and refuse,
  # preventing an worker from bouncing the live orchestrating server.
  defp env_pairs(opts, bead_id) do
    base =
      case Keyword.fetch(opts, :env) do
        {:ok, list} when is_list(list) -> list
        _ -> Arbiter.Agents.Claude.ConfigDir.env()
      end

    case bead_id do
      id when is_binary(id) and id != "" ->
        base ++ [{"ARB_ACOLYTE_BEAD_ID", id}]

      _ ->
        base
    end
  end
end
