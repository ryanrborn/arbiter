defmodule Arbiter.Agents.Codex.Stream do
  @moduledoc """
  Parses the OpenAI Codex CLI's `codex exec --json` event stream.

  Codex emits one JSON event per line (JSONL) with a *different* shape from
  Claude's and Gemini's stream-json, so the worker hot path
  (`Arbiter.Worker.ClaudeSession`) delegates here when a session's provider is
  `"codex"`. This keeps Codex's schema knowledge in the Codex namespace.

  ## Two wire schemas

  Codex has changed `exec --json`'s vocabulary under us once already, so this
  module speaks **both**.

  ### Current: the thread/turn/item protocol (`codex` 0.142.5+)

      {"type":"thread.started","thread_id":"019f95ae-.."}
      {"type":"turn.started"}
      {"type":"item.started"  ,"item":{"id":"item_1","type":"command_execution",..}}
      {"type":"item.updated"  ,"item":{..}}
      {"type":"item.completed","item":{"id":"item_0","type":"agent_message","text":".."}}
      {"type":"turn.completed","usage":{"input_tokens":..,"cached_input_tokens":..,
                                        "output_tokens":..,"reasoning_output_tokens":..}}
      {"type":"turn.failed","error":{"message":".."}}

  `item.type` is one of `agent_message`, `reasoning`, `command_execution`,
  `file_change`, `mcp_tool_call`, `web_search`, `todo_list`. Note the item
  carries the *cumulative* state for its id: `item.completed` for an
  `agent_message` holds the whole message, so only the terminal phase is
  rendered and `item.updated` is absorbed — otherwise streamed text would be
  printed two or three times.

  ### Legacy: the `event_msg` vocabulary (`codex` ≤ 0.142.3)

  Still parsed so an operator pinned to an older CLI keeps a live transcript.
  Each line is an `event_msg` payload discriminated by `"type"`:

      {"type":"task_started","turn_id":..,"model_context_window":..}
      {"type":"agent_message","message":"..","phase":"final_answer"}
      {"type":"agent_message_delta","delta":".."}
      {"type":"agent_reasoning","text":".."} / {"type":"agent_reasoning_delta","delta":".."}
      {"type":"exec_command_begin","command":["mix","test"],"cwd":".."}
      {"type":"exec_command_end","exit_code":0,"aggregated_output":".."}
      {"type":"token_count","info":{"total_token_usage":{..},"last_token_usage":{..}},"rate_limits":{..}}
      {"type":"turn_context","model":"gpt-5-codex","effort":".."}
      {"type":"task_complete","last_agent_message":"..","duration_ms":..}
      {"type":"error","message":".."}

  `token_count.info.total_token_usage` carries the cumulative buckets
  (snake_case): `input_tokens` (incl. cached), `cached_input_tokens`,
  `output_tokens` (incl. reasoning), `reasoning_output_tokens`, `total_tokens`.

  > Codex plan users have no per-session dollar cost (usage is metered against
  > the ChatGPT plan, tracked separately by `Arbiter.Quota.Codex`), so
  > `cost_usd` is left `nil` — graceful degradation the usage ledger already
  > tolerates.

  Only **agent_message text** opts into completion (`arb done`) detection — the
  prompt echo, reasoning, tool calls, and command output are displayed but
  never trip the sentinel.

  ## Schema drift is loud, not silent (bd-80kdgy)

  This module used to end in a silent `_event -> []` catch-all. When 0.142.5
  swapped the wire schema, *every* event fell into it: the run produced a
  zero-line transcript, a null model, an all-zero `Usage.Event`, and never saw
  `arb done` — while the subprocess still exited 0 and looked like a clean
  no-diff completion. An event type this module does not know is now rendered
  as a visible `⚠ codex: unrecognized stream event …` line, so the next
  vocabulary change shows up in the transcript on the first run instead of
  masquerading as a successful no-op. Types we deliberately drop are listed in
  `@absorbed_events` / handled by an explicit clause, so the warning only fires
  on genuinely unknown input.
  """

  # Event types with no display value that we drop on purpose. Anything not in
  # here and not matched by a clause below is treated as schema drift.
  @absorbed_events ~w(
    turn.started
    item.updated
    session_configured
    token_count
    turn_context
    user_message
    agent_message_content
    agent_message_content_delta
    agent_reasoning_section_break
    agent_reasoning_raw_content
    agent_reasoning_raw_content_delta
    exec_command_output_delta
    mcp_tool_call_begin
    mcp_tool_call_end
    patch_apply_begin
    patch_apply_end
    web_search_begin
    web_search_end
    plan_update
    context_compacted
    entered_review_mode
    exited_review_mode
    background_event
    notification
    shutdown_complete
  )

  @doc """
  Reduce one decoded event to a map of usage fields to merge onto the session's
  `:usage`. Returns `%{}` for events that carry no usage.

  `fallback_model` is the pre-resolved model id threaded onto the session at
  spawn time (Codex's `exec --json` stream may not carry a model, so the
  fallback keeps the ledger's model slot populated).
  """
  @spec usage_fields(map(), String.t() | nil) :: map()

  # ---- thread/turn/item protocol (0.142.5+) ------------------------------

  # The 0.142.5 schema dropped `turn_context`, so nothing on the wire names the
  # model the CLI settled on. `fallback_model` (what Arbiter resolved at spawn
  # time) is the only honest value available — when the workspace pins no codex
  # model it stays nil rather than being invented.
  def usage_fields(%{"type" => "thread.started"} = event, fallback) do
    drop_nil(%{session_id: stringy(event["thread_id"]), model: stringy(fallback)})
  end

  # `usage` is the whole turn's cumulative count (it already includes the
  # cached/reasoning sub-buckets). `codex exec` runs exactly one turn per
  # spawn, so last-write-wins on the session's :usage map is the total; a
  # `codex exec resume` spawn opens its own port and its own usage row.
  def usage_fields(%{"type" => "turn.completed", "usage" => usage}, _fallback)
      when is_map(usage) do
    drop_nil(%{
      tokens_in: number(usage["input_tokens"]),
      tokens_out: number(usage["output_tokens"]),
      # Codex reports cache *reads* only; it has no cache-creation analogue.
      cache_read_tokens: number(usage["cached_input_tokens"]),
      result_status: "success",
      is_error: false,
      raw: usage
    })
  end

  def usage_fields(%{"type" => "turn.failed"} = event, _fallback) do
    drop_nil(%{is_error: true, result_status: "error", raw: event})
  end

  # ---- legacy event_msg vocabulary (<= 0.142.3) --------------------------

  def usage_fields(%{"type" => "token_count", "info" => info}, _fallback) when is_map(info) do
    totals = info["total_token_usage"] || info["last_token_usage"] || %{}

    drop_nil(%{
      tokens_in: number(totals["input_tokens"]),
      tokens_out: number(totals["output_tokens"]),
      # Codex reports cache *reads* (cached_input_tokens); it has no analogue to
      # Claude's cache-creation tokens, so that slot stays nil.
      cache_read_tokens: number(totals["cached_input_tokens"]),
      raw: info
    })
  end

  def usage_fields(%{"type" => "turn_context"} = event, _fallback) do
    drop_nil(%{model: stringy(event["model"])})
  end

  def usage_fields(%{"type" => "session_configured"} = event, _fallback) do
    drop_nil(%{session_id: stringy(event["session_id"]), model: stringy(event["model"])})
  end

  def usage_fields(%{"type" => "task_complete"} = event, _fallback) do
    drop_nil(%{
      duration_ms: number(event["duration_ms"]),
      result_status: "success",
      is_error: false,
      raw: event
    })
  end

  def usage_fields(%{"type" => "error"} = event, _fallback) do
    drop_nil(%{
      is_error: true,
      result_status: "error",
      raw: event
    })
  end

  def usage_fields(_event, _fallback), do: %{}

  @doc """
  Expand a decoded event into `{display_line, detect_done?}` tuples for the
  live tail. Mirrors `Arbiter.Worker.ClaudeSession`'s formatting.
  """
  @spec format_event(map()) :: [{String.t(), boolean()}]

  # ---- thread/turn/item protocol (0.142.5+) ------------------------------

  def format_event(%{"type" => "thread.started"} = event) do
    suffix =
      case stringy(event["thread_id"]) do
        nil -> ""
        id -> " (thread #{id})"
      end

    [{"⚙ codex session started" <> suffix, false}]
  end

  def format_event(%{"type" => "turn.completed"} = event), do: [{turn_summary(event), false}]

  def format_event(%{"type" => "turn.failed"} = event) do
    [{"⚠ codex turn failed: #{truncate(error_message(event["error"]), 200)}", false}]
  end

  def format_event(%{"type" => phase, "item" => item})
      when phase in ["item.started", "item.completed"] and is_map(item),
      do: format_item(phase, item)

  # ---- legacy event_msg vocabulary (<= 0.142.3) --------------------------

  def format_event(%{"type" => "task_started"} = event) do
    ctx = number(event["model_context_window"])
    suffix = if ctx, do: " (context #{ctx})", else: ""
    [{"⚙ codex session started" <> suffix, false}]
  end

  # Agent message text is the worker's own output — the only event class that
  # may trip the `arb done` sentinel.
  def format_event(%{"type" => "agent_message", "message" => message}) when is_binary(message) do
    message |> lines() |> Enum.map(&{&1, true})
  end

  # Streaming deltas of the same message. Displayed but each partial chunk is
  # arm-eligible too (the split-done rolling buffer in ClaudeSession stitches a
  # sentinel that straddles two deltas).
  def format_event(%{"type" => "agent_message_delta", "delta" => delta}) when is_binary(delta) do
    delta |> lines() |> Enum.reject(&(&1 == "")) |> Enum.map(&{&1, true})
  end

  def format_event(%{"type" => "agent_reasoning", "text" => text}) when is_binary(text) do
    text |> lines() |> Enum.reject(&(&1 == "")) |> Enum.map(&{"· #{&1}", false})
  end

  def format_event(%{"type" => "agent_reasoning_delta"}), do: []

  def format_event(%{"type" => "exec_command_begin"} = event) do
    [{"⏵ $ #{command_string(event["command"])}", false}]
  end

  def format_event(%{"type" => "exec_command_end"} = event) do
    code = number(event["exit_code"])
    label = if code in [0, nil], do: "⏴ command done", else: "⏴ command exited #{code}"

    body =
      event
      |> Map.get("aggregated_output")
      |> output_text()
      |> lines()
      |> Enum.reject(&(&1 == ""))
      |> truncate_lines(40)

    Enum.map([label | body], &{&1, false})
  end

  def format_event(%{"type" => "error"} = event) do
    [{"⚠ codex: #{truncate(to_string(event["message"] || "error"), 200)}", false}]
  end

  def format_event(%{"type" => "task_complete"} = event), do: [{result_summary(event), false}]

  # The prompt echo and the other known-but-uninteresting types are dropped.
  def format_event(%{"type" => type}) when type in @absorbed_events, do: []

  # bd-80kdgy: anything else is schema drift — surface it rather than swallow
  # the session whole.
  def format_event(%{"type" => type}) when is_binary(type), do: [{drift_line(type), false}]

  def format_event(_event), do: []

  # ---- item rendering (0.142.5+) -----------------------------------------
  #
  # An item's payload is cumulative for its id, so only the phase that carries
  # the finished value renders; the other phase is dropped to avoid printing
  # the same text twice.

  defp format_item("item.completed", %{"type" => "agent_message"} = item),
    do: item["text"] |> lines() |> Enum.map(&{&1, true})

  defp format_item("item.started", %{"type" => "agent_message"}), do: []

  defp format_item("item.completed", %{"type" => "reasoning"} = item),
    do: item["text"] |> lines() |> Enum.reject(&(&1 == "")) |> Enum.map(&{"· #{&1}", false})

  defp format_item("item.started", %{"type" => "reasoning"}), do: []

  defp format_item("item.started", %{"type" => "command_execution"} = item),
    do: [{"⏵ $ #{command_string(item["command"])}", false}]

  defp format_item("item.completed", %{"type" => "command_execution"} = item) do
    code = number(item["exit_code"])
    label = if code in [0, nil], do: "⏴ command done", else: "⏴ command exited #{code}"

    body =
      item
      |> Map.get("aggregated_output")
      |> output_text()
      |> lines()
      |> Enum.reject(&(&1 == ""))
      |> truncate_lines(40)

    Enum.map([label | body], &{&1, false})
  end

  defp format_item("item.completed", %{"type" => "file_change"} = item) do
    case change_lines(item["changes"]) do
      [] -> [{"⏴ applied a patch", false}]
      lines -> Enum.map(lines, &{&1, false})
    end
  end

  defp format_item("item.started", %{"type" => "file_change"}), do: []

  defp format_item("item.started", %{"type" => "mcp_tool_call"} = item),
    do: [{"⏵ #{mcp_label(item)}", false}]

  defp format_item("item.completed", %{"type" => "mcp_tool_call"} = item),
    do: [{"⏴ #{mcp_label(item)} done", false}]

  defp format_item("item.completed", %{"type" => "web_search"} = item),
    do: [{"⏵ web search: #{truncate(to_string(item["query"] || ""), 120)}", false}]

  defp format_item("item.started", %{"type" => "web_search"}), do: []

  # The todo list is re-sent in full on every update; too noisy for a transcript.
  defp format_item(_phase, %{"type" => "todo_list"}), do: []

  defp format_item(phase, %{"type" => type}) when is_binary(type),
    do: [{drift_line("#{phase} item #{type}"), false}]

  defp format_item(phase, _item), do: [{drift_line(phase), false}]

  @doc """
  Reduce an event to a coarse live-activity phrase, or `nil` to keep the prior
  activity. Mirrors the Claude / Gemini activity derivation.
  """
  @spec activity_for_event(map()) :: String.t() | nil
  def activity_for_event(%{"type" => "thread.started"}), do: "starting"
  def activity_for_event(%{"type" => "turn.completed"}), do: "wrapping up"

  def activity_for_event(%{"type" => phase, "item" => item})
      when phase in ["item.started", "item.completed"] and is_map(item),
      do: item_activity(item)

  def activity_for_event(%{"type" => "task_started"}), do: "starting"
  def activity_for_event(%{"type" => "task_complete"}), do: "wrapping up"
  def activity_for_event(%{"type" => "agent_reasoning"}), do: "thinking"
  def activity_for_event(%{"type" => "agent_reasoning_delta"}), do: "thinking"

  def activity_for_event(%{"type" => "agent_message", "message" => m}) when is_binary(m) do
    if String.trim(m) == "", do: nil, else: "responding"
  end

  def activity_for_event(%{"type" => "exec_command_begin"} = event),
    do: shell_activity(event["command"])

  def activity_for_event(_event), do: nil

  # ---- internals ---------------------------------------------------------

  defp item_activity(%{"type" => "agent_message"} = item) do
    case item["text"] do
      t when is_binary(t) -> if String.trim(t) == "", do: nil, else: "responding"
      _ -> nil
    end
  end

  defp item_activity(%{"type" => "reasoning"}), do: "thinking"
  defp item_activity(%{"type" => "command_execution"} = item), do: shell_activity(item["command"])
  defp item_activity(%{"type" => "web_search"}), do: "researching"
  defp item_activity(%{"type" => "todo_list"}), do: "planning"

  defp item_activity(%{"type" => "file_change"} = item) do
    case first_change_path(item["changes"]) do
      nil -> "editing files"
      path -> "editing " <> Path.basename(path)
    end
  end

  defp item_activity(%{"type" => "mcp_tool_call"} = item), do: stringy(item["tool"])
  defp item_activity(_item), do: nil

  defp first_change_path(changes) when is_list(changes) do
    Enum.find_value(changes, fn
      %{"path" => p} when is_binary(p) and p != "" -> p
      _ -> nil
    end)
  end

  defp first_change_path(_changes), do: nil

  # `changes` is a list of `%{"path" => .., "kind" => "add"|"delete"|"update"}`.
  defp change_lines(changes) when is_list(changes) do
    Enum.flat_map(changes, fn
      %{"path" => path} = change when is_binary(path) and path != "" ->
        ["⏴ #{change_verb(change["kind"])} #{path}"]

      _ ->
        []
    end)
  end

  defp change_lines(_changes), do: []

  defp change_verb("add"), do: "created"
  defp change_verb("delete"), do: "deleted"
  defp change_verb(_kind), do: "edited"

  defp mcp_label(item) do
    server = stringy(item["server"])
    tool = stringy(item["tool"]) || "tool"
    if server, do: "mcp #{server}.#{tool}", else: "mcp #{tool}"
  end

  defp turn_summary(event) do
    usage = event["usage"] || %{}
    parts = ["⚙ codex session complete"]

    parts =
      case {number(usage["input_tokens"]), number(usage["output_tokens"])} do
        {nil, nil} -> parts
        {in_t, out_t} -> parts ++ ["#{in_t || 0} in / #{out_t || 0} out"]
      end

    Enum.join(parts, " · ")
  end

  defp error_message(%{"message" => m}) when is_binary(m) and m != "", do: m
  defp error_message(m) when is_binary(m) and m != "", do: m
  defp error_message(other), do: inspect(other)

  # bd-80kdgy: the transcript line that turns a silent schema change into an
  # obvious one. Non-arming, so it can never trip `arb done`.
  defp drift_line(what) do
    "⚠ codex: unrecognized stream event #{inspect(what)} — this Arbiter build does not " <>
      "understand your codex CLI's --json schema, so this event was not transcribed " <>
      "(see bd-80kdgy)"
  end

  defp shell_activity(command) do
    cmd = command_string(command)

    cond do
      cmd == "" -> "running a command"
      test_command?(cmd) -> "running tests"
      true -> "running: " <> truncate(cmd, 60)
    end
  end

  defp test_command?(cmd),
    do: Regex.match?(~r/\b(mix test|npm test|pytest|go test|cargo test|rspec|jest)\b/, cmd)

  # Codex renders a command as an argv list; join to a display string.
  defp command_string(argv) when is_list(argv),
    do: argv |> Enum.filter(&is_binary/1) |> Enum.join(" ")

  defp command_string(cmd) when is_binary(cmd), do: cmd
  defp command_string(_), do: ""

  defp result_summary(event) do
    parts = ["⚙ codex session complete"]

    parts =
      case number(event["duration_ms"]) do
        ms when is_number(ms) -> parts ++ ["#{Float.round(ms / 1000, 1)}s"]
        _ -> parts
      end

    Enum.join(parts, " · ")
  end

  defp output_text(text) when is_binary(text), do: text
  defp output_text(_), do: ""

  defp lines(text) when is_binary(text), do: String.split(text, "\n")
  defp lines(_), do: []

  defp truncate_lines(lines, max) do
    case Enum.split(lines, max) do
      {kept, []} -> kept
      {kept, dropped} -> kept ++ ["… (#{length(dropped)} more lines)"]
    end
  end

  defp truncate(str, max) when is_binary(str) do
    if String.length(str) > max, do: String.slice(str, 0, max) <> "…", else: str
  end

  defp drop_nil(map) do
    map |> Enum.reject(fn {_k, v} -> is_nil(v) end) |> Map.new()
  end

  defp stringy(v) when is_binary(v) and v != "", do: v
  defp stringy(_), do: nil

  defp number(n) when is_integer(n), do: n
  defp number(n) when is_float(n), do: n
  defp number(_), do: nil
end
