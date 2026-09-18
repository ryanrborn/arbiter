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

  ## `agy` tool telemetry (bd-7y3mm9)

  A `step_type: "tool"` step arrives twice per call — `state: "ACTIVE"` with
  `tool_name` + `tool_info.parameters`, then `state: "DONE"` with
  `duration_seconds` + `tool_info.output` — and was previously dropped
  entirely by the `step_update` catch-all, which is why an agy transcript
  used to be a handful of lines regardless of how much work the run did:

      {"event":"step_update","step_update":{"step_index":2,"state":"ACTIVE","step_type":"tool","tool_name":"run_command","tool_info":{"name":"run_command","parameters":{"CommandLine":"echo hello-from-agy"}}}}
      {"event":"step_update","step_update":{"step_index":2,"state":"DONE","step_type":"tool","tool_name":"run_command","duration_seconds":0.027,"tool_info":{"name":"run_command","parameters":{"CommandLine":"echo hello-from-agy"},"output":"hello-from-agy\r\n"}}}

  agy's shell tool is `run_command` (not upstream-gemini's
  `run_shell_command`) and its command parameter is `CommandLine`
  (PascalCase, not `command`) — `agy_tool_params/2` renames it before handing
  off to the shared `summarize_params/1`/`shell_activity/1` helpers so
  `mix test` still resolves to the `running tests` activity phrase.

  A third state, `"ERROR"`, shows up when headless `:strict` auto-denies a
  tool call not named in `permissions.allow` (bd-25ivqe) — before this fix it
  fell into the generic "unrecognized tool step state" schema-drift warning,
  which is how a `:strict` agy worker's very first denied `arb` call rendered
  as a confusing drift notice instead of a legible denial. It's now a
  dedicated `format_event/1` clause and a `worker_run_steps` row with
  `is_error: true` (`ClaudeSession.capture_steps/2`).

  `agy`'s terminal `result.usage` has no per-model breakdown, and — confirmed
  live (bd-2fzwlc round 2) — no `result` or `init` event names which model
  actually ran, so `usage_fields/2` here never stamps a guessed `:model` onto
  the row (that would pollute `usage_summarize --by model` with a model agy
  didn't run); `Arbiter.Worker`'s `record_usage_event/3` fills it in from the
  session's pre-resolved model instead (bd-2fzwlc / bd-d2yut8, T1).

  Operator decision (2026-09-17, bd-481sz7): agy/Antigravity reports no
  per-call dollar cost for *any* model — it's a subscription metered by
  quota percentage, not a priced API, and agy's own catalogue doesn't overlap
  the Gemini price table anyway (Gemini 3.x tiers, Claude models, GPT-OSS, no
  2.5 model). So every agy row carries `cost_usd: nil` permanently, with a
  `:cost_note` saying so.
  """

  alias Arbiter.Agents.Gemini.Pricing

  # agy reports no model in any event (confirmed live, bd-2fzwlc round 2 —
  # `init` carries only cwd/tools/permission_mode, and `result` carries no
  # model field either), and its v1.1.11 catalogue does not overlap the
  # Gemini price table at all (Gemini 3.x tiers, Claude models, GPT-OSS —
  # no 2.5 model). Pricing an agy row against the session's pre-resolved
  # `fallback_model` — which defaults to the hardcoded `gemini-2.5-pro` when
  # nothing is configured — would stamp a confident, wrong dollar figure on
  # a model agy never ran. So agy cost is always unavailable; the row must
  # say why rather than guess.
  # Operator decision (2026-09-17, bd-481sz7): agy/Antigravity is a
  # subscription with a quota-percentage meter, not a per-call priced API — it
  # reports no dollar cost for *any* model, not just an unresolved one. After
  # T1 (bd-2fzwlc) the model is known (threaded onto the session at spawn
  # time and stamped by `Arbiter.Worker.record_usage_event/3`'s `session.model`
  # fallback), so this note must not blame an "unknown model" that isn't true
  # anymore — it explains the real, permanent reason cost_usd stays nil.
  @agy_cost_unavailable_note "agy/Antigravity reports no cost: it's a subscription metered by Antigravity quota percentage, not a per-call priced API"

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

  def usage_fields(%{"event" => "result", "result" => result} = event, _fallback_model)
      when is_map(result) do
    usage = result["usage"] || %{}
    status = result["status"]

    drop_nil(%{
      tokens_in: number(usage["input_tokens"]),
      tokens_out: number(usage["output_tokens"]),
      cache_read_tokens: number(usage["cache_read_tokens"]),
      # Confirmed live (bd-481sz7): `input_tokens + output_tokens ==
      # total_tokens`, with no separate thinking bucket added on top — agy's
      # thinking tokens are a subset already counted inside `output_tokens`,
      # not additional spend. Recorded here for visibility only; never add
      # this to `tokens_out` or the ledger double-counts it.
      thinking_tokens: number(usage["thinking_tokens"]),
      duration_ms: agy_duration_ms(result["duration_seconds"]),
      cost_usd: nil,
      cost_note: @agy_cost_unavailable_note,
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

  # agy's tool telemetry (bd-7y3mm9): a `step_type: "tool"` step carries
  # `tool_name` + `tool_info.parameters` on ACTIVE and `tool_info.output` on
  # DONE — reuse the exact same `summarize_params/1`/`truncate_lines/2`
  # helpers the upstream-gemini `tool_use`/`tool_result` clauses already use,
  # so the rendering is byte-compatible.
  def format_event(%{
        "event" => "step_update",
        "step_update" => %{"step_type" => "tool", "state" => "ACTIVE"} = step
      }) do
    name = step["tool_name"] || "tool"
    params = agy_tool_params(name, get_in(step, ["tool_info", "parameters"]))
    [{"⏵ #{name}(#{summarize_params(params)})", false}]
  end

  def format_event(%{
        "event" => "step_update",
        "step_update" => %{"step_type" => "tool", "state" => "DONE"} = step
      }) do
    body =
      step
      |> get_in(["tool_info", "output"])
      |> output_text()
      |> lines()
      |> Enum.reject(&(&1 == ""))
      |> truncate_lines(40)

    Enum.map(["⏴ tool result" | body], &{&1, false})
  end

  # agy's headless-denial state (bd-25ivqe): under `:strict`, a tool call not
  # matched by `permissions.allow` comes back on this same
  # ACTIVE/DONE-shaped step as `state: "ERROR"` — headless mode can't prompt,
  # so an unallowed command is auto-denied rather than hanging. This is a
  # known, meaningful outcome (a denied/failed tool call), not a schema-drift
  # surprise, so it gets its own line rather than falling into the generic
  # "unrecognized tool step state" warning below.
  def format_event(%{
        "event" => "step_update",
        "step_update" => %{"step_type" => "tool", "state" => "ERROR"} = step
      }) do
    name = step["tool_name"] || "tool"
    reason = tool_step_error_reason(step)

    body =
      reason
      |> output_text()
      |> lines()
      |> Enum.reject(&(&1 == ""))
      |> truncate_lines(40)

    Enum.map(["⏴ #{name} denied/failed" | body], &{&1, false})
  end

  # A `step_type: "tool"` step in a state other than ACTIVE/DONE/ERROR (agy's
  # wire carries at least a `CANCELLED` enum value) — that shape was never
  # captured live (bd-7y3mm9), so route it through the same "schema drift is
  # loud" warning the unrecognized-top-level-event clause below uses, rather
  # than silently dropping it like the generic step_update fallback would.
  def format_event(%{
        "event" => "step_update",
        "step_update" => %{"step_type" => "tool", "state" => state} = step
      })
      when is_binary(state) do
    name = step["tool_name"] || "tool"
    [{"⚠ gemini: unrecognized tool step state #{state} for #{name} (schema drift?)", false}]
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

  def activity_for_event(%{
        "event" => "step_update",
        "step_update" => %{"step_type" => "tool", "state" => "ACTIVE"} = step
      }) do
    name = step["tool_name"]
    tool_activity(name, agy_tool_params(name, get_in(step, ["tool_info", "parameters"])))
  end

  def activity_for_event(%{
        "event" => "step_update",
        "step_update" => %{"step_type" => "tool", "state" => "ERROR"} = step
      }) do
    "#{step["tool_name"] || "a command"} denied"
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

  # agy's own shell tool is named "run_command", not upstream-gemini's
  # "run_shell_command" — `agy_tool_params/2` has already renamed its
  # `CommandLine` parameter to `command` by the time this clause runs, so it
  # reuses `shell_activity/1` unmodified.
  defp tool_activity("run_command", params), do: shell_activity(params)

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

  # Pre-existing complexity 10 — baselined when bd-4x2yhq first
  # wired Credo up. Thresholds stay at the tool's own default so new
  # code is held to it; see the note in .credo.exs.
  # credo:disable-for-next-line Credo.Check.Refactor.CyclomaticComplexity
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

  defp agy_duration_ms(seconds) when is_number(seconds), do: round(seconds * 1000)
  defp agy_duration_ms(_), do: nil

  # agy's `run_command` tool parameter is `CommandLine` (PascalCase, verified
  # live — bd-7y3mm9), not the `command` key `summarize_params/1` and
  # `shell_activity/1` already know from Claude/upstream-gemini's shell
  # tools. Normalize it onto the shared key so both helpers stay untouched.
  #
  # Public (not `defp`) so `ClaudeSession.capture_steps/2` can normalize the
  # same params before handing them to `StepSummary.input_summary/2` — the
  # step row's `input_summary` must read the same string as the `⏵
  # run_command(...)` transcript line this module renders for the identical
  # call, not the raw `CommandLine` wire key.
  @doc false
  def agy_tool_params("run_command", %{"CommandLine" => cmd}), do: %{"command" => cmd}
  def agy_tool_params(_name, params) when is_map(params), do: params
  def agy_tool_params(_name, _params), do: %{}

  # The denial/failure detail on an ERROR-state tool step. The exact key agy
  # uses for this was never captured live (like the ERROR state itself,
  # bd-25ivqe) — `tool_info.error` mirrors the shape its DONE sibling uses for
  # `tool_info.output`, so it's tried first; falling back to `output` covers
  # a build that reuses the same key for both outcomes.
  defp tool_step_error_reason(step) do
    get_in(step, ["tool_info", "error"]) || get_in(step, ["tool_info", "output"])
  end

  @doc """
  The base command token a denied `run_command` ERROR step named — `"arb"`
  out of `"arb inbox bd-ci0y74"` — for surfacing a concrete "strict policy
  denied required command `<x>`" failure reason
  (`Arbiter.Worker.ClaudeSession.capture_steps/2`) instead of a generic
  blank-notes failure. `nil` for a non-command tool or an unparseable one.
  """
  @spec agy_denied_command_token(String.t() | nil, map()) :: String.t() | nil
  def agy_denied_command_token(name, params) do
    case agy_tool_params(name, params) do
      %{"command" => cmd} when is_binary(cmd) ->
        cmd |> String.trim() |> String.split(" ", parts: 2) |> List.first()

      _ ->
        name
    end
  end

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
