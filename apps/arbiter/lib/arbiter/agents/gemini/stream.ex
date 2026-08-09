defmodule Arbiter.Agents.Gemini.Stream do
  @moduledoc """
  Parses the gemini CLI's `--output-format stream-json` event stream.

  The gemini CLI's JSONL events have a *different* shape from Claude's
  stream-json, so the worker hot path (`Arbiter.Worker.ClaudeSession`)
  delegates here when a session's provider is `"gemini"`. This keeps Gemini's
  schema knowledge in the Gemini namespace rather than polluting the Claude
  parser.

  ## Event shapes (confirmed against `@google/gemini-cli` v0.45.0)

      {"type":"init","timestamp":..,"session_id":..,"model":"gemini-2.5-pro"}
      {"type":"message","timestamp":..,"role":"user"|"assistant","content":..,"delta":true}
      {"type":"tool_use","timestamp":..,"tool_name":..,"tool_id":..,"parameters":{..}}
      {"type":"tool_result","timestamp":..,"tool_id":..,"status":"success"|"error","output":..,"error":{..}}
      {"type":"error","timestamp":..,..}
      {"type":"result","timestamp":..,"status":"success"|"error","error"?:{..},"stats":{..}}

  The terminal `result` event carries `stats` with per-model token breakdowns
  (snake_case): `total_tokens`, `input_tokens` (prompt, incl. cached), `cached`,
  `input` (non-cached prompt), `output_tokens` (candidates), `duration_ms`,
  `tool_calls`, and `models` (a per-model map of the same buckets).

  > Note: the gemini CLI emits no per-session dollar cost, so cost is *derived*
  > from the token counts via `Arbiter.Agents.Gemini.Pricing`.

  Only **assistant message text** opts into completion (`arb done`) detection —
  the user prompt echo, tool calls, and tool results are displayed but never
  trip the sentinel.

  ## `agy` wire schema (bd-2fzwlc)

  `Arbiter.Agents.Gemini.resolve_executable/0` prefers the `agy` fork over the
  upstream `gemini` CLI when both are on `PATH`, and `agy` speaks a
  *completely different* stream-json schema — a top-level `"event"`
  discriminator (not `"type"`) with the payload nested under a same-named key,
  and a flat (non-per-model) `usage` object. Every clause above only matches
  `"type"`-keyed events, so every `agy` event fell through to the `%{}`
  catch-all — this is why every Gemini `usage_events` row carried zero tokens
  even though 150 sessions completed successfully. Confirmed live against
  installed `agy` v1.1.11:

      {"event":"init","conversation_id":..,"init":{"cwd":..,"tools":[..],"permission_mode":..}}
      {"event":"step_update","step_update":{"conversation_id":..,"step_index":..,"state":"DONE","step_type":"user_input"|"unknown"|"agent_response"|"checkpoint",..}}
      {"event":"result","result":{"conversation_id":..,"status":"SUCCESS"|..,"response":..,"duration_seconds":..,"num_turns":..,"usage":{"input_tokens":..,"output_tokens":..,"thinking_tokens":..,"cache_read_tokens":..,"total_tokens":..}}}

  `agy`'s terminal `result.usage` has no per-model breakdown, so cost is
  derived off the session's pre-resolved `fallback_model` via
  `Arbiter.Agents.Gemini.Pricing.model_cost/2` directly (skipping
  `Pricing.cost_usd/1`'s `stats["models"]` shape). When cost can't be derived
  — no model resolved, or the model isn't in the price table — `:cost_note`
  records *why*, so a null `cost_usd` reads as "known limitation" rather than
  "parse failure".
  """

  alias Arbiter.Agents.Gemini.Pricing

  @doc """
  Reduce one decoded stream-json event to a map of usage fields to merge onto
  the session's `:usage`. Returns `%{}` for events that carry no usage.

  `fallback_model` is the pre-resolved model id threaded onto the session at
  spawn time (the gemini stream's `init` event does carry a model, but we keep
  the fallback for robustness).
  """
  @spec usage_fields(map(), String.t() | nil) :: map()
  def usage_fields(%{"type" => "init"} = event, _fallback_model) do
    drop_nil(%{
      model: event["model"],
      session_id: event["session_id"]
    })
  end

  def usage_fields(%{"type" => "result"} = event, fallback_model) do
    stats = event["stats"] || %{}

    drop_nil(%{
      tokens_in: number(stats["input_tokens"]),
      tokens_out: number(stats["output_tokens"]),
      # Gemini exposes only cache *reads* (cachedContentTokenCount); it has no
      # analogue to Claude's cache-creation tokens, so that slot stays nil.
      cache_read_tokens: number(stats["cached"]),
      duration_ms: number(stats["duration_ms"]),
      cost_usd: Pricing.cost_usd(stats),
      model: result_model(stats, fallback_model),
      result_status: event["status"],
      is_error: event["status"] == "error",
      raw: event
    })
  end

  def usage_fields(%{"event" => "init"} = event, _fallback_model) do
    session_id = event["conversation_id"] || get_in(event, ["init", "conversation_id"])
    drop_nil(%{session_id: session_id})
  end

  def usage_fields(%{"event" => "result", "result" => result} = event, fallback_model)
      when is_map(result) do
    usage = result["usage"] || %{}
    status = result["status"]
    {cost, cost_note} = agy_cost(usage, fallback_model)

    drop_nil(%{
      tokens_in: number(usage["input_tokens"]),
      tokens_out: number(usage["output_tokens"]),
      cache_read_tokens: number(usage["cache_read_tokens"]),
      duration_ms: agy_duration_ms(result["duration_seconds"]),
      cost_usd: cost,
      cost_note: cost_note,
      model: fallback_model,
      result_status: status,
      is_error: status not in [nil, "SUCCESS"],
      raw: event
    })
  end

  def usage_fields(_event, _fallback_model), do: %{}

  @doc """
  Expand a decoded stream-json event into `{display_line, detect_done?}` tuples
  for the live tail. Mirrors `Arbiter.Worker.ClaudeSession`'s formatting.
  """
  @spec format_event(map()) :: [{String.t(), boolean()}]
  def format_event(%{"type" => "init"} = event) do
    [{"⚙ gemini session started (model #{event["model"] || "?"})", false}]
  end

  # Assistant text is the worker's own output — the only event class that may
  # trip the `arb done` sentinel. (Deltas may split the marker across chunks;
  # the literal-line case — `arb done` on its own delta — is the common one.)
  def format_event(%{"type" => "message", "role" => "assistant", "content" => content})
      when is_binary(content) do
    content |> lines() |> Enum.map(&{&1, true})
  end

  # The user message is the prompt we sent — display nothing and never arm
  # completion (it could legitimately contain the literal "arb done").
  def format_event(%{"type" => "message", "role" => "user"}), do: []

  def format_event(%{"type" => "tool_use"} = event) do
    name = event["tool_name"] || "tool"
    [{"⏵ #{name}(#{summarize_params(event["parameters"])})", false}]
  end

  def format_event(%{"type" => "tool_result"} = event) do
    label = if event["status"] == "error", do: "⏴ tool error", else: "⏴ tool result"

    body =
      event
      |> Map.get("output")
      |> output_text()
      |> lines()
      |> Enum.reject(&(&1 == ""))
      |> truncate_lines(40)

    Enum.map([label | body], &{&1, false})
  end

  def format_event(%{"type" => "error"} = event) do
    msg = error_message(event["error"]) || event["message"] || "error"
    [{"⚠ gemini: #{truncate(to_string(msg), 200)}", false}]
  end

  def format_event(%{"type" => "result"} = event), do: [{result_summary(event), false}]

  def format_event(%{"event" => "init"}) do
    [{"⚙ gemini session started", false}]
  end

  # agy's terminal assistant text is delivered as an `agent_response` step —
  # the only step class that may trip the `arb done` sentinel.
  def format_event(%{
        "event" => "step_update",
        "step_update" => %{"step_type" => "agent_response", "text_delta" => text}
      })
      when is_binary(text) do
    text |> lines() |> Enum.map(&{&1, true})
  end

  # Other step types (user_input echo, checkpoint, unknown bookkeeping steps)
  # are not worker output — display nothing and never arm completion.
  def format_event(%{"event" => "step_update"}), do: []

  def format_event(%{"event" => "result", "result" => result}) when is_map(result),
    do: [{agy_result_summary(result), false}]

  # Mirrors Codex's bd-80kdgy "schema drift is loud" pattern: an unrecognized
  # top-level `agy` event surfaces a visible warning instead of silently
  # vanishing, so the next wire-schema break announces itself.
  def format_event(%{"event" => ev}) when is_binary(ev) do
    [{"⚠ gemini: unrecognized stream event #{ev} (schema drift?)", false}]
  end

  def format_event(_event), do: []

  @doc """
  Reduce an event to a coarse live-activity phrase, or `nil` to keep the prior
  activity. Mirrors the Claude activity derivation.
  """
  @spec activity_for_event(map()) :: String.t() | nil
  def activity_for_event(%{"type" => "init"}), do: "starting"
  def activity_for_event(%{"type" => "result"}), do: "wrapping up"

  def activity_for_event(%{"type" => "message", "role" => "assistant", "content" => content})
      when is_binary(content) do
    if String.trim(content) == "", do: nil, else: "responding"
  end

  def activity_for_event(%{"type" => "tool_use"} = event),
    do: tool_activity(event["tool_name"], event["parameters"])

  def activity_for_event(%{"event" => "init"}), do: "starting"
  def activity_for_event(%{"event" => "result"}), do: "wrapping up"

  def activity_for_event(%{
        "event" => "step_update",
        "step_update" => %{"step_type" => "agent_response", "text_delta" => text}
      })
      when is_binary(text) do
    if String.trim(text) == "", do: nil, else: "responding"
  end

  def activity_for_event(_event), do: nil

  # ---- internals ---------------------------------------------------------

  defp result_model(stats, fallback_model) do
    case stats["models"] do
      models when is_map(models) and map_size(models) > 0 ->
        # The model that did the most total work, so the ledger's single model
        # slot reflects the dominant one in a (rare) multi-model session.
        models
        |> Enum.max_by(fn {_m, e} -> number(e["total_tokens"]) || 0 end, fn -> nil end)
        |> case do
          {model, _entry} -> model
          nil -> fallback_model
        end

      _ ->
        fallback_model
    end
  end

  defp tool_activity(edit, params) when edit in ~w(edit write_file replace),
    do: "editing " <> file_label(params)

  defp tool_activity(read, params) when read in ~w(read_file read_many_files),
    do: "reading " <> file_label(params)

  defp tool_activity("run_shell_command", params), do: shell_activity(params)

  defp tool_activity(search, _params) when search in ~w(glob search_file_content grep),
    do: "searching"

  defp tool_activity(web, _params) when web in ~w(web_fetch google_web_search),
    do: "researching"

  defp tool_activity(name, _params) when is_binary(name) and name != "", do: name
  defp tool_activity(_name, _params), do: nil

  defp file_label(params) when is_map(params) do
    case params["file_path"] || params["path"] || params["absolute_path"] do
      p when is_binary(p) and p != "" -> Path.basename(p)
      _ -> "a file"
    end
  end

  defp file_label(_params), do: "a file"

  defp shell_activity(params) when is_map(params) do
    cmd = params["command"]

    cond do
      is_binary(cmd) and test_command?(cmd) -> "running tests"
      is_binary(cmd) and cmd != "" -> "running: " <> truncate(cmd, 60)
      true -> "running a command"
    end
  end

  defp shell_activity(_params), do: "running a command"

  defp test_command?(cmd),
    do: Regex.match?(~r/\b(mix test|npm test|pytest|go test|cargo test|rspec|jest)\b/, cmd)

  defp summarize_params(params) when is_map(params) do
    cond do
      is_binary(params["command"]) -> truncate(params["command"], 200)
      is_binary(params["file_path"]) -> params["file_path"]
      is_binary(params["path"]) -> params["path"]
      is_binary(params["absolute_path"]) -> params["absolute_path"]
      is_binary(params["pattern"]) -> truncate(params["pattern"], 200)
      params == %{} -> ""
      true -> truncate(Jason.encode!(params), 200)
    end
  end

  defp summarize_params(_params), do: ""

  defp result_summary(event) do
    status = event["status"] || "done"
    stats = event["stats"] || %{}
    parts = ["⚙ gemini session #{status}"]

    parts =
      case number(stats["duration_ms"]) do
        ms when is_number(ms) -> parts ++ ["#{Float.round(ms / 1000, 1)}s"]
        _ -> parts
      end

    parts =
      case number(stats["total_tokens"]) do
        t when is_number(t) and t > 0 -> parts ++ ["#{t} tok"]
        _ -> parts
      end

    parts =
      case Pricing.cost_usd(stats) do
        cost when is_number(cost) -> parts ++ ["~$#{Float.round(cost, 4)}"]
        _ -> parts
      end

    Enum.join(parts, " · ")
  end

  # agy's `result.usage` has no per-model breakdown, so cost is derived off
  # the session's spawn-time `fallback_model` directly via
  # `Pricing.model_cost/2` rather than `Pricing.cost_usd/1`. When cost can't
  # be derived, `cost_note` records why (no model resolved, or an unpriced
  # model) so the row's null cost_usd is legible instead of looking like a
  # parse failure.
  defp agy_cost(_usage, nil) do
    {nil, "cost unavailable: no model resolved for this session"}
  end

  defp agy_cost(usage, model) do
    entry = %{
      "cached" => usage["cache_read_tokens"],
      "input_tokens" => usage["input_tokens"],
      "output_tokens" => usage["output_tokens"],
      "total_tokens" => usage["total_tokens"]
    }

    case Pricing.model_cost(model, entry) do
      nil -> {nil, "cost unavailable: #{model} is not in the Gemini price table"}
      cost -> {cost, nil}
    end
  end

  defp agy_duration_ms(seconds) when is_number(seconds), do: round(seconds * 1000)
  defp agy_duration_ms(_), do: nil

  defp agy_result_summary(result) do
    status = result["status"] || "done"
    usage = result["usage"] || %{}
    parts = ["⚙ gemini session #{status}"]

    parts =
      case number(result["duration_seconds"]) do
        s when is_number(s) -> parts ++ ["#{Float.round(s * 1.0, 1)}s"]
        _ -> parts
      end

    parts =
      case number(usage["total_tokens"]) do
        t when is_number(t) and t > 0 -> parts ++ ["#{t} tok"]
        _ -> parts
      end

    Enum.join(parts, " · ")
  end

  defp error_message(%{"message" => m}) when is_binary(m), do: m
  defp error_message(_), do: nil

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

  defp number(n) when is_integer(n), do: n
  defp number(n) when is_float(n), do: n
  defp number(_), do: nil
end
