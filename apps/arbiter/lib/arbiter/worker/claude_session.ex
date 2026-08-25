defmodule Arbiter.Worker.ClaudeSession do
  @moduledoc """
  Port wrapper that runs a child process (eventually Claude Code CLI) inside a
  worktree and streams its stdout into a parent `Arbiter.Worker` GenServer.

  This is Phase 2's I/O surface for the worker. **No tmux** — we drive Claude
  Code (or any echo-script spike) directly through an Erlang `Port` so the
  parent process sees output line-by-line and can react to completion signals
  without polling a tty.

  ## Architecture

      caller (the worker)
        │
        ▼
      ClaudeSession.start(opts)
        │   (synchronous GenServer.call to the owner worker)
        ▼
      worker handle_call(:__start_session__)
        │   Port.open/2 — worker becomes the port owner
        ▼
      worker handle_info({port, ...})
        │   • append line to meta[:output_lines]   (cap @line_cap)
        │   • Phoenix.PubSub.broadcast {:worker_output, task_id, line}
        │   • on "arb done" → Worker.complete(self())
        │   • on {:exit_status, n} → meta[:exit_status], broadcast :worker_exited
        ▼

  We deliberately open the `Port` *from inside* the worker's process (via a
  GenServer.call hop) so the worker itself owns the port. Port messages only
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

  A display line matching `~r/\\barb done[^\\p{L}\\p{N}]*$/u` triggers
  `Worker.complete/2`. The marker must be the **last** token on the line
  (only whitespace / punctuation / decoration may trail it), so a literal
  marker line like `arb done`, `>> arb done <<`, or a turn ending in
  `… — arb done` trips it, but a prose line that merely *mentions* the marker
  mid-sentence ("I'll print arb done when the tests pass") does NOT (bd-7a0pi8:
  a worker narrating its intent to finish must not falsely complete before it
  has done the work). The leading `\\b` still rejects the "arb doneness"
  substring. Under stream-json, detection is additionally scoped to the
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
  per-run on-disk transcript via `Arbiter.Worker.OutputLog`, when the session
  was opened with an `:output_log` handle (the worker opens one keyed on the
  run id). This durable capture sits alongside the live path and never gates
  it: a session opened without a handle behaves exactly as before.

  ## PubSub topic

  Default topic is `"worker:" <> task_id`. Subscribers (LiveView, CLI
  followers, tests) must know the task_id to subscribe. The `:topic` opt
  overrides this.
  """

  alias Arbiter.Worker
  alias Arbiter.Worker.OutputLog
  alias Arbiter.Worker.StepSummary
  alias Arbiter.Workers.RunStep

  require Logger

  @line_cap 1000
  # bd-7a0pi8: anchor the marker to end-of-line. `\barb done` still rejects the
  # "arb doneness" substring; the trailing `[^\p{L}\p{N}]*$` requires the marker
  # to be the last token (only whitespace/punctuation/decoration may follow), so
  # a worker narrating "I'll print arb done once the tests pass" no longer trips
  # a premature, false completion.
  @done_regex ~r/\barb done[^\p{L}\p{N}]*$/u

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
  Builds the session-config map that every site opening a worker port must
  stash alongside the port.

  Three sites open ports for the same task — `start/1` here, plus the gate-nudge
  and auto-resume respawns in `Arbiter.Worker` — and each respawn inherits the
  original port's `:env`, secrets included. Any field missing from a respawn's
  map silently degrades that session: a missing `:redact_values` (bd-62d3jh)
  means the relaunched child can echo a secret straight through `redact_line/2`
  to the PubSub stream, `worker_runs.output_lines`, and the durable log. This
  constructor is the single owner of the shape, so a new field can't drift out
  of two of the three callers.

  ## Options

    * `:provider` / `:model` — routing config for the session's adapter.
    * `:redact_values` — secret worker env values to scrub from output. Resolved
      from the task's workspace when omitted; pass the previous session's list
      on a respawn to skip the redundant DB read.
    * `:composed_prompt` — the raw prompt text this spawn was built from
      (bd-9rdwe4, #1017 gap G5), carried purely for durable persistence
      (`Arbiter.Worker.PromptLog`) — it plays no role in argv construction.
      A caller that already built its own argv (`command:` opts, e.g.
      `Arbiter.Worker.Dispatch` / `Arbiter.Worker.ReviewGate`) should still
      pass the prompt string it composed here so the worker can record what
      the agent was actually told.
  """
  @spec build_session_config(String.t() | nil, String.t() | nil, keyword()) :: map()
  def build_session_config(task_id, topic \\ nil, opts \\ []) do
    %{
      task_id: task_id,
      topic: topic || default_topic(task_id),
      line_cap: @line_cap,
      done_regex: @done_regex,
      provider: Keyword.get(opts, :provider),
      model: Keyword.get(opts, :model),
      redact_values:
        Keyword.get_lazy(opts, :redact_values, fn ->
          Arbiter.Worker.WorkerEnv.secret_values(task_id)
        end),
      composed_prompt: Keyword.get(opts, :composed_prompt)
    }
  end

  @doc """
  Start a Claude (or echo-spike) session in `worktree_path`, streaming output
  into the `:owner` worker.

  ## Required opts

    * `:worktree_path` — absolute path, must exist. The child runs with this
      as cwd.
    * `:owner` — pid of the parent worker GenServer. Becomes the port owner
      and receives all port messages.

  ## Optional opts

    * `:prompt` — passed to Claude as the prompt. Required when `:command`
      is `nil` (real Claude invocation).
    * `:command` — full argv list as `[exec, arg1, arg2, ...]`. When set,
      overrides the default streaming `claude` invocation and is spawned
      verbatim (no `sh`/stdin wrapping). Tests **must** pass this so we don't
      shell out to real Claude.
    * `:topic` — PubSub topic to broadcast output on. Defaults to
      `"worker:" <> task_id`.

  ## Returns

    * `{:ok, port}` on success. The port is owned by the `:owner` worker.
    * `{:error, reason}` if the executable can't be resolved or the worktree
      path is invalid.
  """
  @spec start(opts()) :: {:ok, port()} | {:error, term()}
  def start(opts) when is_list(opts) do
    with {:ok, owner} <- fetch_owner(opts),
         {:ok, worktree_path} <- fetch_worktree(opts),
         {:ok, argv} <- resolve_argv(opts),
         {:ok, exec} <- resolve_executable(argv) do
      task_id = task_id_for(owner)

      # One workspace load serves both halves (bd-62d3jh): the pairs go into the
      # child's env, the secret values into the session's redaction list.
      {worker_env, redact_values} = Arbiter.Worker.WorkerEnv.resolve(task_id)

      # bd-2zigo1: the install-wide CLAUDE_CODE_OAUTH_TOKEN (and any
      # ANTHROPIC_API_KEY) travel in via the caller-explicit `:env` opt
      # (`Claude.spawn_env/1`'s output), not the workspace's `worker_env`
      # store — so they're invisible to the redaction list above. Without
      # this, a worker that runs `env` or whose error output quotes its
      # environment would emit the long-TTL token verbatim into
      # worker_runs.output_lines / the dashboard stream / OutputLog.
      redact_values = redact_values ++ credential_env_values(opts)

      session_config =
        build_session_config(task_id, Keyword.get(opts, :topic),
          provider: Keyword.get(opts, :provider),
          # Pre-resolved model id for adapters whose stream carries none
          # (Gemini). Claude omits this and learns the model from its `init`
          # event instead.
          model: Keyword.get(opts, :model),
          redact_values: redact_values,
          # bd-9rdwe4: `:prompt` still means "raw prompt text" even when
          # `:command` (a caller-built argv) wins argv resolution below — it's
          # carried through purely for the worker to persist.
          composed_prompt: Keyword.get(opts, :prompt)
        )

      port_args = %{
        exec: exec,
        argv: argv,
        cd: worktree_path,
        env: env_pairs(opts, task_id, worker_env)
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
  # Delegates argv construction to `Arbiter.Agents.Claude.build_argv/3` (the
  # `sh -c 'exec "$@" < /dev/null'` wrapper described there) so this
  # workspace-less path gets the same bd-11abk2 E2BIG fix as the
  # workspace-aware `Arbiter.Agents.Claude.default_argv/2` path: a prompt over
  # MAX_ARG_STRLEN is delivered via a temp file + stdin instead of being
  # spliced into argv. The claude path and prompt are passed as positional
  # params, never spliced into the command string, so there is no
  # shell-injection surface either way.
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

        flags =
          Arbiter.Agents.Claude.Security.permission_argv(policy) ++
            Arbiter.Agents.Claude.Security.settings_argv(policy) ++
            ["--output-format", "stream-json", "--verbose"]

        Arbiter.Agents.Claude.build_argv(claude, prompt, flags)

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

  defp task_id_for(owner) do
    case Worker.state(owner) do
      %{task_id: id} -> id
      _ -> nil
    end
  end

  defp default_topic(nil), do: "worker:unknown"
  defp default_topic(task_id), do: "worker:" <> task_id

  # ---- helpers called from Worker's handle_info -------------------------
  #
  # These live here (rather than inlined into worker.ex) so the port message
  # routing logic stays colocated with the rest of the session module. The
  # worker just shuttles messages to us.

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
  # worker can mint an `Arbiter.Usage.Event` row on session exit.
  #
  # A decoded event also refreshes the session's coarse :activity ("thinking",
  # "editing run.ex", "running tests", …) — the live progress signal the worker
  # mirrors into meta for claude-driven views, which have no ticking workflow
  # Machine to advance a real step (see Arbiter.Worker.Driver claude-driven mode
  # and bd-c919xj).
  defp process_line(%{} = session, line) do
    case decode_event(line) do
      {:ok, event} ->
        session =
          session
          |> absorb_usage(event)
          |> capture_steps(event)
          |> scan_split_done(event)
          |> buffer_gemini_display(event)

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

  # `agy` (the Gemini fork preferred by `resolve_executable/0`, bd-2fzwlc)
  # speaks a completely different wire schema than upstream gemini — a
  # top-level `"event"` discriminator with assistant text nested under
  # `step_update.text_delta`. The clause above only matches upstream's
  # `"type" => "message"` shape, so every agy event fell through to the
  # catch-all below and this safety net never armed for agy sessions — the
  # one Gemini executable that actually needs it, since it streams deltas
  # that can split "arb done" mid-word. Mirrors the codex clause's rolling
  # buffer.
  defp scan_split_done(
         %{provider: "gemini"} = session,
         %{
           "event" => "step_update",
           "step_update" => %{"step_type" => "agent_response", "text_delta" => text}
         }
       )
       when is_binary(text) do
    buf = scan_tail(Map.get(session, :split_done_buf, "") <> text)
    session = Map.put(session, :split_done_buf, buf)

    if Regex.match?(session.done_regex, buf) do
      send(self(), {:__claude_session_done__, buf})
      Map.put(session, :split_done_fired, true)
    else
      session
    end
  end

  # Codex streams assistant output as `agent_message_delta` chunks too, so the
  # sentinel can straddle a delta boundary the same way Gemini's can. Mirror the
  # rolling-buffer safety net for codex sessions, across both wire schemas
  # (bd-80kdgy).
  defp scan_split_done(%{provider: "codex", split_done_fired: true} = session, _event),
    do: session

  defp scan_split_done(%{provider: "codex"} = session, event) do
    case codex_assistant_text(event) do
      nil -> session
      text -> scan_codex_done(session, text)
    end
  end

  defp scan_split_done(session, _event), do: session

  # Assistant text carried by either codex wire schema: the legacy
  # `agent_message`/`agent_message_delta` events, or the 0.142.5+
  # `item.completed` envelope around an `agent_message` item (bd-80kdgy).
  defp codex_assistant_text(%{"type" => type} = event)
       when type in ["agent_message", "agent_message_delta"] do
    event["message"] || event["delta"] || ""
  end

  defp codex_assistant_text(%{"type" => "item.completed", "item" => %{} = item}) do
    case item do
      %{"type" => "agent_message", "text" => text} when is_binary(text) -> text
      _ -> nil
    end
  end

  defp codex_assistant_text(_event), do: nil

  defp scan_codex_done(session, text) do
    buf = scan_tail(Map.get(session, :split_done_buf, "") <> text)
    session = Map.put(session, :split_done_buf, buf)

    if Regex.match?(session.done_regex, buf) do
      send(self(), {:__claude_session_done__, buf})
      Map.put(session, :split_done_fired, true)
    else
      session
    end
  end

  # Keep only the last 256 graphemes — enough to span a sentinel split across a
  # chunk boundary without growing unbounded on a long turn.
  defp scan_tail(text) when is_binary(text) do
    if String.length(text) > 256, do: String.slice(text, -256, 256), else: text
  end

  # `agy`'s `text_delta` chunks can split mid-word (bd-2fzwlc round 2: a live
  # probe split "converts" across two deltas), so formatting each delta as its
  # own complete line breaks both readability and line-anchored downstream
  # parsing (e.g. ReviewGate's `VERDICT: APPROVE` regex). Buffer per-session
  # and emit only through the last newline; flush the remainder when the step
  # reports `state: "DONE"` (whose own trailing `text_delta` is often just
  # `"\n"`, which this also stops from rendering as an extra blank line) or
  # when the session's terminal `result` event arrives as a fallback. Sets
  # `:gemini_pending_lines` for `format_event/2` to read.
  defp buffer_gemini_display(%{provider: "gemini"} = session, %{
         "event" => "step_update",
         "step_update" => %{"step_type" => "agent_response", "text_delta" => text} = step
       })
       when is_binary(text) do
    buf = Map.get(session, :gemini_text_buf, "")

    {lines, remainder} =
      if step["state"] == "DONE" do
        flush_display_buffer(buf <> text)
      else
        split_display_lines(buf <> text)
      end

    session
    |> Map.put(:gemini_text_buf, remainder)
    |> Map.put(:gemini_pending_lines, lines)
  end

  defp buffer_gemini_display(%{provider: "gemini"} = session, %{"event" => "result"}) do
    {lines, remainder} = flush_display_buffer(Map.get(session, :gemini_text_buf, ""))

    session
    |> Map.put(:gemini_text_buf, remainder)
    |> Map.put(:gemini_pending_lines, lines)
  end

  defp buffer_gemini_display(%{provider: "gemini"} = session, _event),
    do: Map.put(session, :gemini_pending_lines, [])

  defp buffer_gemini_display(session, _event), do: session

  # Split off every *complete* line (text up to and including a "\n"), keeping
  # whatever trails the last newline as the new buffer.
  defp split_display_lines(text) do
    parts = String.split(text, "\n")
    {complete, [last]} = Enum.split(parts, -1)
    {complete, last}
  end

  # Flush everything buffered, e.g. at the step's `state: "DONE"` or the
  # session's terminal `result` event. Strips exactly one trailing newline —
  # agy's DONE step carries its own trailing `text_delta` (observed: `"\n"`),
  # which is the message's closing newline, not an intentional blank line —
  # so without this a fully-flushed buffer renders a spurious empty line.
  defp flush_display_buffer(text) do
    trimmed = if String.ends_with?(text, "\n"), do: String.slice(text, 0..-2//1), else: text

    case trimmed do
      "" -> {[], ""}
      _ -> {String.split(trimmed, "\n"), ""}
    end
  end

  # Capture structured usage off the two events that carry it. The `init` event
  # tells us the model and session_id up front; the terminal `result` event
  # carries tokens + cost + duration. Both update an in-session `:usage` map
  # that the worker reads on exit. Best-effort — missing keys leave their slot
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

  # Codex's `exec --json` events carry a different schema again (token_count /
  # task_complete / turn_context), so route them to the Codex stream parser.
  defp absorb_usage(%{provider: "codex"} = session, event) do
    update_usage(
      session,
      Arbiter.Agents.Codex.Stream.usage_fields(event, Map.get(session, :model))
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
      # bd-9rdwe4: the structured terminal record (#1017 gap G5) — the CLI's
      # own outcome/verdict plus the final assistant-facing text, redacted
      # through the SAME choke-point (`redact_line/2`) that already protects
      # every transcript line, since this text is what lands on the
      # `worker_runs` row rather than staying inside the uncapped transcript.
      result_is_error: event["is_error"],
      result_message: redact_optional(session, event["result"]),
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

  # ---- typed step capture (bd-7xftps / bd-apwfmy Phase 1) ---------------
  #
  # Promote tool_use/tool_result block pairs out of rendered transcript prose
  # into a queryable `Arbiter.Workers.RunStep` row, without disturbing the
  # display-line formatting that `assistant_block_lines/1` /
  # `tool_result_lines/1` already do for the exact same blocks (the "byte
  # identical" acceptance bar). A `tool_use` block stashes what it knows
  # (name, redacted input) on the session under `:pending_tool_calls`, keyed
  # by the block's `id`; the matching `tool_result` block (correlated by
  # `tool_use_id`) pops that entry, computes `duration_ms`, and issues the
  # (best-effort) DB write. A `tool_use` with no matching result — the
  # session was killed mid-call — leaves its pending entry stranded and never
  # writes a row: absent, not garbage.
  #
  # Deliberately Claude-only: Gemini/Codex speak different stream-json
  # shapes (see their own `Stream.format_event/1` modules) and are routed
  # around here explicitly rather than relying on the shape match to miss,
  # so the "rows absent for non-Claude runs" property is asserted, not
  # accidental.
  defp capture_steps(%{provider: provider} = session, _event)
       when provider in ["gemini", "codex"],
       do: session

  defp capture_steps(session, %{"type" => "assistant", "message" => %{"content" => content}})
       when is_list(content) do
    Enum.reduce(content, session, &remember_tool_use/2)
  end

  defp capture_steps(session, %{"type" => "user", "message" => %{"content" => content}})
       when is_list(content) do
    Enum.reduce(content, session, &record_tool_result/2)
  end

  defp capture_steps(session, _event), do: session

  defp remember_tool_use(%{"type" => "tool_use", "id" => id, "name" => name} = block, session)
       when is_binary(id) do
    input = Map.get(block, "input")

    entry = %{
      name: name,
      input_summary: StepSummary.input_summary(input, redact_values(session)),
      input_digest: StepSummary.input_digest(input, redact_values(session)),
      started_at: System.monotonic_time(:millisecond)
    }

    pending = Map.get(session, :pending_tool_calls, %{})
    Map.put(session, :pending_tool_calls, Map.put(pending, id, entry))
  end

  defp remember_tool_use(_block, session), do: session

  defp record_tool_result(%{"type" => "tool_result", "tool_use_id" => id} = block, session)
       when is_binary(id) do
    pending = Map.get(session, :pending_tool_calls, %{})
    {call, pending} = Map.pop(pending, id)
    session = Map.put(session, :pending_tool_calls, pending)

    duration_ms =
      case call do
        %{started_at: started_at} -> System.monotonic_time(:millisecond) - started_at
        nil -> nil
      end

    output_summary =
      block
      |> Map.get("content")
      |> tool_result_content_text()
      |> StepSummary.output_summary(redact_values(session))

    write_step(session, %{
      run_id: Map.get(session, :run_id),
      task_id: Map.get(session, :task_id),
      tool_use_id: id,
      name: call && call.name,
      is_error: !!Map.get(block, "is_error"),
      duration_ms: duration_ms,
      input_digest: call && call.input_digest,
      input_summary: call && call.input_summary,
      output_summary: output_summary,
      occurred_at: DateTime.utc_now()
    })

    session
  end

  defp record_tool_result(_block, session), do: session

  # Best-effort, like `record_usage_event/3` in `Arbiter.Worker`: a DB hiccup
  # logs a warning and never fails the run. Written from inside the emit path
  # (unlike the usage ledger, which batches at session exit) so `duration_ms`
  # and the tool_use_id correlation are captured while still fresh.
  defp write_step(session, attrs) do
    case Ash.create(RunStep, attrs) do
      {:ok, _row} ->
        :ok

      {:error, reason} ->
        Logger.warning(
          "ClaudeSession.write_step/2 swallowed for task=#{Map.get(session, :task_id)}: #{inspect(reason)}"
        )

        :error
    end
  rescue
    e ->
      Logger.warning(
        "ClaudeSession.write_step/2 raised for task=#{Map.get(session, :task_id)}: #{Exception.message(e)}"
      )

      :error
  end

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
        "codex" -> Arbiter.Agents.Codex.Stream.activity_for_event(event)
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
    # Redact secret-marked worker env var values (bd-62d3jh) at this single
    # choke-point: the redacted line is what reaches every human-facing surface
    # — the live PubSub stream, the capped in-memory buffer that becomes
    # `worker_runs.output_lines`, and the durable on-disk transcript. Done
    # detection still runs on the ORIGINAL line so a secret value can never
    # perturb the "arb done" sentinel match.
    redacted = redact_line(session, line)

    unless blank?(redacted) do
      broadcast(session, {:worker_output, session.task_id, redacted})
    end

    if detect_done? and Regex.match?(session.done_regex, line) do
      send(self(), {:__claude_session_done__, line})
    end

    append_durable(session, redacted)

    %{session | output_lines: prepend_capped(session.output_lines, redacted, session.line_cap)}
  end

  # Scrub secret worker env var values from a line. `redact_values` is populated
  # in `start/1` from the workspace's secret-flagged worker env vars; sessions
  # without any (tests, workspace-less spawns) carry an empty list and pass the
  # line through untouched.
  defp redact_values(session) do
    case Map.get(session, :redact_values) do
      [_ | _] = values -> values
      _ -> []
    end
  end

  defp redact_line(session, line) do
    case Map.get(session, :redact_values) do
      [_ | _] = values -> Arbiter.Redaction.redact(line, values)
      _ -> line
    end
  end

  # Same choke-point as `redact_line/2`, for a value that may be absent (the
  # terminal `result` event's text is nil on some error subtypes). Truncated
  # to the `result_message` column's `max_length: 20_000` constraint (see
  # `Arbiter.Workers.Run`) — that Ash constraint rejects rather than
  # truncates an over-length string, which silently dropped the ENTIRE
  # terminal write (status, completed_at, exit_code, every `result_*` field)
  # for any run whose final assistant message ran long.
  @result_message_max_length 20_000

  defp redact_optional(_session, nil), do: nil

  defp redact_optional(session, text) when is_binary(text) do
    session
    |> redact_line(text)
    |> String.slice(0, @result_message_max_length)
  end

  # Append the line to the durable, uncapped per-run transcript when the
  # session carries an :output_log handle. Best-effort and never blocks the
  # live path: a session without a handle (tests, run_id-less workers) is a
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
  #
  # `normalize_event/1` also unwraps the two envelope shapes Codex's
  # `exec --json` may use — a rollout-style `{"type":"event_msg","payload":{…}}`
  # or an `{"id":…,"msg":{…}}` protocol wrapper — down to the inner payload
  # (which carries its own `"type"`). Claude/Gemini events never match those
  # wrapper clauses, so this is a no-op for them.
  defp decode_event(line) do
    with "{" <> _ <- String.trim_leading(line),
         {:ok, obj} when is_map(obj) <- Jason.decode(line),
         {:ok, event} <- normalize_event(obj) do
      {:ok, event}
    else
      _ -> :error
    end
  end

  defp normalize_event(%{"type" => "event_msg", "payload" => %{"type" => _} = p}), do: {:ok, p}
  defp normalize_event(%{"msg" => %{"type" => _} = msg}), do: {:ok, msg}
  defp normalize_event(%{"type" => _} = event), do: {:ok, event}
  # agy (bd-2fzwlc) speaks a top-level `"event"` discriminator instead of
  # `"type"` — without this clause every agy JSONL line fails to decode and
  # falls through to the raw-text path, silently skipping absorb_usage/2,
  # scan_split_done/2, and format_event/2 for every agy event. This is the
  # root cause of the zero-token/zero-cost agy rows, not just the missing
  # split-done safety net.
  defp normalize_event(%{"event" => _} = event), do: {:ok, event}
  defp normalize_event(_), do: :error

  # Provider-aware dispatch: Gemini's stream-json events have a different shape,
  # so they're formatted by the Gemini parser. Claude (and the nil/default
  # provider) use the clauses below.
  # agy's assistant text is buffered per-session by `buffer_gemini_display/2`
  # (called earlier in `process_line/2`) so a delta split mid-word or
  # mid-sentinel doesn't render as two broken lines. Read the lines it
  # computed instead of re-deriving from this single event.
  defp format_event(
         %{"event" => "step_update", "step_update" => %{"step_type" => "agent_response"}},
         %{provider: "gemini"} = session
       ) do
    session
    |> Map.get(:gemini_pending_lines, [])
    |> Enum.map(&{&1, true})
  end

  defp format_event(%{"event" => "result"} = event, %{provider: "gemini"} = session) do
    flushed = session |> Map.get(:gemini_pending_lines, []) |> Enum.map(&{&1, true})
    flushed ++ Arbiter.Agents.Gemini.Stream.format_event(event)
  end

  defp format_event(event, %{provider: "gemini"}),
    do: Arbiter.Agents.Gemini.Stream.format_event(event)

  defp format_event(event, %{provider: "codex"}),
    do: Arbiter.Agents.Codex.Stream.format_event(event)

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

  # Shared with `Arbiter.Workers.StepBackfill` via `StepSummary` — the step
  # row's summaries and this transcript line must be the same string, and
  # more importantly must pass through the same redaction choke-point.
  defp summarize_tool_input(input), do: StepSummary.summarize_tool_input(input)

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
    # Flush any buffered agy `text_delta` text (bd-2fzwlc round 2): agy emits
    # its whole response with no interior newlines until the terminal event,
    # so a session killed on timeout/cancel/crash before `DONE`/`result`
    # would otherwise lose the entire partial response from the transcript.
    session =
      case Map.get(session, :gemini_text_buf, "") do
        "" ->
          session

        buf ->
          {lines, _remainder} = flush_display_buffer(buf)
          session = Map.put(session, :gemini_text_buf, "")
          Enum.reduce(lines, session, &emit_line(&2, &1, true))
      end

    # Flush any buffered partial line the child left without a trailing newline.
    session =
      case Map.get(session, :line_buf, "") do
        "" -> session
        buf -> process_line(%{session | line_buf: ""}, buf)
      end

    broadcast(session, {:worker_exited, session.task_id, status})
    close_durable(session)
    %{session | exit_status: status, exited_at: DateTime.utc_now()}
  end

  # Close the durable transcript handle (if any) once the child has exited.
  # The handle is also linked to the worker, so an unclean death still flushes
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
  # bd-crqku8: always inject ARB_WORKER_BEAD_ID so any `arb restart/update/
  # start` invoked from inside the worker session can detect it and refuse,
  # preventing an worker from bouncing the live orchestrating server.
  #
  # bd-4hkzn3: prepend release-env cleanup pairs so ROOTDIR / BINDIR /
  # RELEASE_* inherited from the systemd OTP release service unit are unset in
  # every worker child shell. Without this, `mix test` (and `arb inbox`) in a
  # worktree tries to boot from the release's ERTS rather than the
  # per-worktree mise-pinned toolchain, crashing with a missing boot file and
  # forcing the ReviewGate to static-analysis-only. The cleanup pairs are a
  # no-op on a plain dev VM (ReleaseEnv.clean_pairs/0 returns [] when no
  # release vars are detected). Caller-explicit `:env` is appended after the
  # cleanup so it can always override specific vars if needed.
  #
  # bd-bzsqbu: also prepend a task-scoped DATABASE_PATH override so a worker
  # that starts its own `mix phx.server` for manual verification writes into
  # a throwaway sqlite file instead of silently inheriting the coordinator's
  # own DATABASE_PATH — the same file the live `arbiter.service` uses.
  #
  # `worker_env` is the workspace's user-defined vars (bd-62d3jh), resolved by
  # the caller so one workspace load serves both it and the session's
  # `redact_values`. They sit after the release/dev-server cleanups but before
  # caller-explicit `:env` (agent auth) and the always-last ARB_WORKER_BEAD_ID
  # guard, so a user var can never clobber the agent's auth or the
  # self-recursion guard.
  # bd-2zigo1: secret credential values carried in the caller-explicit `:env`
  # opt (`Claude.spawn_env/1`'s `CLAUDE_CODE_OAUTH_TOKEN` / `ANTHROPIC_API_KEY`
  # pairs) — these never pass through `Arbiter.Worker.WorkerEnv`, so they must
  # be added to the redaction list separately. Only known credential var names
  # are scrubbed here; non-secret pairs (`CLAUDE_CONFIG_DIR`,
  # `ANTHROPIC_BASE_URL`) are left alone.
  @credential_env_keys ~w(CLAUDE_CODE_OAUTH_TOKEN ANTHROPIC_API_KEY)

  defp credential_env_values(opts) do
    case Keyword.fetch(opts, :env) do
      {:ok, list} when is_list(list) ->
        for {key, value} <- list,
            key in @credential_env_keys,
            is_binary(value) and value != "",
            do: value

      _ ->
        []
    end
  end

  defp env_pairs(opts, task_id, worker_env) do
    base =
      case Keyword.fetch(opts, :env) do
        {:ok, list} when is_list(list) -> list
        _ -> Arbiter.Agents.Claude.ConfigDir.env()
      end

    release_clean = Arbiter.Worker.ReleaseEnv.clean_pairs()
    dev_server_clean = Arbiter.Worker.DevServerEnv.pairs(task_id)

    case task_id do
      id when is_binary(id) and id != "" ->
        release_clean ++ dev_server_clean ++ worker_env ++ base ++ [{"ARB_WORKER_BEAD_ID", id}]

      _ ->
        release_clean ++ base
    end
  end
end
