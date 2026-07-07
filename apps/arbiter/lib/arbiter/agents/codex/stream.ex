defmodule Arbiter.Agents.Codex.Stream do
  @moduledoc """
  Parses the OpenAI Codex CLI's `codex exec --json` event stream.

  Codex emits one JSON event per line (JSONL) with a *different* shape from
  Claude's and Gemini's stream-json, so the worker hot path
  (`Arbiter.Worker.ClaudeSession`) delegates here when a session's provider is
  `"codex"`. This keeps Codex's schema knowledge in the Codex namespace.

  ## Event shapes (confirmed against `codex` 0.142.3)

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
  """

  @doc """
  Reduce one decoded event to a map of usage fields to merge onto the session's
  `:usage`. Returns `%{}` for events that carry no usage.

  `fallback_model` is the pre-resolved model id threaded onto the session at
  spawn time (Codex's `exec --json` stream may not carry a model, so the
  fallback keeps the ledger's model slot populated).
  """
  @spec usage_fields(map(), String.t() | nil) :: map()
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

  # The prompt echo and everything else are absorbed silently.
  def format_event(_event), do: []

  @doc """
  Reduce an event to a coarse live-activity phrase, or `nil` to keep the prior
  activity. Mirrors the Claude / Gemini activity derivation.
  """
  @spec activity_for_event(map()) :: String.t() | nil
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
