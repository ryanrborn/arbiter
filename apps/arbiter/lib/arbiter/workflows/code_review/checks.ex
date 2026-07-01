defmodule Arbiter.Workflows.CodeReview.Checks do
  @moduledoc """
  Default check runner for `Arbiter.Workflows.CodeReview`.

  Hands the diff to a Claude session and parses structured findings from
  its JSON output. A finding has the shape:

      %{
        severity: :info | :warning | :error,
        file: String.t(),
        line: pos_integer(),
        message: String.t()
      }

  Any finding with `severity: :error` causes the workflow's `:verdict`
  step to return `:request_changes`; otherwise `:approve`.

  ## Indirection — why a runner function, not a hard call

  The workflow looks up the runner indirectly via `state[:check_runner]`
  (defaulting to `&__MODULE__.run/2`), which lets tests inject a stub
  without monkey-patching modules **and** lets callers swap the reviewer
  (`gpt-codex`, `local-static-analyzer`, …) without rewriting the
  workflow.

  ## Test override

  Set `Application.put_env(:arbiter, :code_review_invoker, fun)` where
  `fun` is a `(prompt, state) -> {:ok, raw_output} | {:error, term()}`
  function. This bypasses Claude entirely. The default invoker shells out
  to `claude --print ... --output-format text`. Tests should always set
  an override to avoid hitting the real CLI.

  ## Output contract from Claude

  Claude is asked to respond with a single JSON object:

      {
        "findings": [
          {"severity": "error|warning|info",
           "file": "path/to/file.ex",
           "line": 42,
           "message": "the issue"}
        ]
      }

  The parser is forgiving: it scans the raw text for the first `{...}`
  JSON object, tolerates surrounding prose, and discards entries that
  don't match the expected shape. If no findings parse, `{:ok, []}` is
  returned (a clean approval).
  """

  require Logger

  @type severity :: :info | :warning | :error
  @type finding :: %{
          required(:severity) => severity(),
          required(:file) => String.t(),
          required(:line) => pos_integer(),
          required(:message) => String.t()
        }

  @doc """
  Run checks against a diff and a state context.

  Sends the diff to a Claude session and parses structured findings from
  its response. Returns `{:ok, []}` when the reviewer found nothing or
  when the diff is empty.
  """
  @spec run(String.t(), map()) :: {:ok, [finding()]} | {:error, term()}
  def run(diff, state) when is_binary(diff) do
    cond do
      String.trim(diff) == "" ->
        {:ok, []}

      true ->
        invoke_reviewer(build_prompt(diff, state), state)
        |> case do
          {:ok, raw} -> {:ok, parse_findings(raw)}
          {:ok, raw, usage} -> {:ok, parse_findings(raw), usage}
          {:error, _} = err -> err
        end
    end
  end

  # ---- internals --------------------------------------------------------

  defp invoke_reviewer(prompt, state) do
    invoker = Application.get_env(:arbiter, :code_review_invoker) || (&default_invoke/2)
    invoker.(prompt, state)
  end

  # Default invoker shells out to `claude --print <prompt> --output-format
  # stream-json --verbose`. Using stream-json lets us extract structured usage
  # data (model, tokens, cost) from the `init` and `result` events, so external
  # reviews can be attributed in the usage ledger.
  defp default_invoke(prompt, _state) do
    case System.find_executable("claude") do
      nil ->
        {:error, {:executable_not_found, "claude"}}

      path ->
        args = ["--print", prompt, "--output-format", "stream-json", "--verbose"]

        # Honor the active model slot when one is seeded in the process dict.
        # ReviewPatrol seeds `:review_agent` via `Agents.prepare(ws, :review_agent)`
        # before running a re-review, so re-reviews can run on a cheaper model than
        # the first pass (bd-f3fg22); mirrors `ReviewReply.default_compose/2`.
        args =
          case Arbiter.Agents.Claude.Config.active_model() do
            model when is_binary(model) and model != "" -> args ++ ["--model", model]
            _ -> args
          end

        case System.cmd(path, args, stderr_to_stdout: true) do
          {output, 0} -> extract_text_and_usage(output)
          {output, code} -> {:error, {:claude_failed, code, String.trim(output)}}
        end
    end
  rescue
    e -> {:error, {:exception, Exception.message(e)}}
  end

  # Parse a stream-json JSONL output into a text result + structured usage map.
  # The `system/init` event carries model + session_id; the terminal `result`
  # event carries the full text reply plus token counts, cost, and duration.
  # Any line that doesn't parse as JSON (non-Claude output, test scripts) is
  # skipped — graceful degradation applies: we always return {:ok, text, usage}.
  defp extract_text_and_usage(output) do
    {text, usage} =
      output
      |> String.split("\n", trim: true)
      |> Enum.reduce({"", %{}}, fn line, {txt, usg} ->
        case Jason.decode(line) do
          {:ok, %{"type" => "system", "subtype" => "init"} = e} ->
            usg = if e["model"], do: Map.put(usg, :model, e["model"]), else: usg
            usg = if e["session_id"], do: Map.put(usg, :session_id, e["session_id"]), else: usg
            {txt, usg}

          {:ok, %{"type" => "result"} = e} ->
            raw = e["usage"] || %{}
            txt = e["result"] || txt
            usg = absorb_number(usg, :tokens_in, raw["input_tokens"])
            usg = absorb_number(usg, :tokens_out, raw["output_tokens"])
            usg = absorb_number(usg, :cost_usd, e["total_cost_usd"])
            usg = absorb_number(usg, :duration_ms, e["duration_ms"])
            {txt, usg}

          _ ->
            {txt, usg}
        end
      end)

    {:ok, text, usage}
  end

  defp absorb_number(map, _key, n) when not is_number(n), do: map
  defp absorb_number(map, key, n), do: Map.put(map, key, n)

  defp build_prompt(diff, state) do
    task_line =
      case Map.get(state, :task) do
        %{id: id, title: title} -> "Task being reviewed: #{id} — #{title}\n\n"
        %{"id" => id, "title" => title} -> "Task being reviewed: #{id} — #{title}\n\n"
        _ -> ""
      end

    """
    You are a code reviewer. Review the unified diff below for correctness,
    safety, and adherence to the task's intent. Be concise and focus on
    real problems — not style nits.

    #{task_line}Respond with a SINGLE JSON object and nothing else:

    {
      "findings": [
        {"severity": "error" | "warning" | "info",
         "file": "<path/relative/to/repo>",
         "line": <integer, the new-file line number>,
         "message": "<one-line description of the issue>"}
      ]
    }

    Severities:
      - "error":   a correctness, security, or contract violation that must be fixed.
      - "warning": a likely issue or risk that deserves attention.
      - "info":    a non-blocking suggestion.

    If you find nothing to flag, respond with: {"findings": []}

    --- BEGIN DIFF ---
    #{diff}
    --- END DIFF ---
    """
  end

  # The model occasionally surrounds its JSON with prose ("Here's the
  # review:") despite the prompt. Be permissive: pull the first balanced
  # `{...}` block out of the response and parse that.
  defp parse_findings(raw) when is_binary(raw) do
    case extract_json_object(raw) do
      nil ->
        Logger.debug("CodeReview.Checks: no JSON object in reviewer output; treating as empty")
        []

      json ->
        case Jason.decode(json) do
          {:ok, %{"findings" => findings}} when is_list(findings) ->
            findings
            |> Enum.map(&normalize_finding/1)
            |> Enum.reject(&is_nil/1)

          _ ->
            Logger.debug("CodeReview.Checks: reviewer output failed to decode as findings JSON")
            []
        end
    end
  end

  defp parse_findings(_), do: []

  # Walk the string and grab the first balanced `{...}` substring. The
  # reviewer's prompt asks for a single JSON object, so the first `{` is
  # the start of the object and we count nesting until depth == 0.
  defp extract_json_object(text) do
    start = :binary.match(text, "{")

    case start do
      :nomatch -> nil
      {idx, _} -> scan(text, idx, byte_size(text), 0, idx)
    end
  end

  defp scan(_text, i, max, _depth, _start) when i >= max, do: nil

  defp scan(text, i, max, depth, start) do
    case :binary.part(text, i, 1) do
      "{" -> scan(text, i + 1, max, depth + 1, start)
      "}" when depth - 1 == 0 -> :binary.part(text, start, i - start + 1)
      "}" -> scan(text, i + 1, max, depth - 1, start)
      _ -> scan(text, i + 1, max, depth, start)
    end
  end

  defp normalize_finding(%{} = entry) do
    with {:ok, severity} <- normalize_severity(Map.get(entry, "severity")),
         file when is_binary(file) and file != "" <- Map.get(entry, "file"),
         line when is_integer(line) and line > 0 <- normalize_line(Map.get(entry, "line")),
         message when is_binary(message) and message != "" <- Map.get(entry, "message") do
      %{severity: severity, file: file, line: line, message: message}
    else
      _ -> nil
    end
  end

  defp normalize_finding(_), do: nil

  defp normalize_severity("error"), do: {:ok, :error}
  defp normalize_severity("warning"), do: {:ok, :warning}
  defp normalize_severity("info"), do: {:ok, :info}
  defp normalize_severity(_), do: :error

  defp normalize_line(n) when is_integer(n) and n > 0, do: n

  defp normalize_line(n) when is_binary(n) do
    case Integer.parse(n) do
      {i, _} when i > 0 -> i
      _ -> 0
    end
  end

  defp normalize_line(_), do: 0
end
