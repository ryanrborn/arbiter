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

  # Default invoker shells out to `claude --print --output-format stream-json
  # --verbose` with the prompt delivered via stdin. Using stream-json lets us
  # extract structured usage data (model, tokens, cost) from the `init` and
  # `result` events, so external reviews can be attributed in the usage ledger.
  #
  # WHY stdin and not `--print <prompt>`:
  # Linux enforces a per-argument size limit (MAX_ARG_STRLEN = 131 072 bytes).
  # When a FE repo's unified diff is large (e.g. package-lock.json churn, many
  # TS/JSX files), the built prompt routinely exceeds that limit. The kernel
  # returns errno E2BIG (= 7), which Erlang surfaces as exit-code 7 with empty
  # stdout — indistinguishable from a crashed process. Passing the prompt via a
  # temp file + stdin redirect eliminates the per-argument ceiling entirely.
  defp default_invoke(prompt, _state) do
    case System.find_executable("claude") do
      nil ->
        {:error, {:executable_not_found, "claude"}}

      path ->
        # No prompt in args — delivered via stdin below.
        args = ["--print", "--output-format", "stream-json", "--verbose"]

        # Honor the active model slot when one is seeded in the process dict.
        # ReviewPatrol seeds `:review_agent` via `Agents.prepare(ws, :review_agent)`
        # before running a re-review, so re-reviews can run on a cheaper model than
        # the first pass (bd-f3fg22); mirrors `ReviewReply.default_compose/2`.
        args =
          case Arbiter.Agents.Claude.Config.active_model() do
            model when is_binary(model) and model != "" -> args ++ ["--model", model]
            _ -> args
          end

        invoke_via_stdin(path, args, prompt)
    end
  rescue
    e -> {:error, {:exception, Exception.message(e)}}
  end

  # Write the prompt to a temporary file and invoke claude with its stdin
  # redirected from that file via `sh -c`. This sidesteps both Linux's
  # MAX_ARG_STRLEN per-argument limit AND the Erlang port's inability to
  # half-close stdin while keeping stdout open for reading.
  #
  # Env isolation mirrors ClaudeSession: CLAUDE_CONFIG_DIR is pinned to the
  # arbiter-managed acolyte config dir so the reviewer never inherits the
  # operator's personal ~/.claude persona, MCP servers, or permission posture.
  # Release-env vars (ROOTDIR/BINDIR/RELEASE_*) are stripped so a node repo's
  # .nvmrc — if picked up by a shell hook — can't switch the Node runtime out
  # from under the reviewer process.
  defp invoke_via_stdin(path, args, prompt) do
    tmp =
      Path.join(
        System.tmp_dir!(),
        "arb_review_#{System.unique_integer([:positive])}.txt"
      )

    try do
      File.write!(tmp, prompt)

      # Build the sh -c command: single-quote each component so spaces,
      # $-variables, and backticks are treated literally.
      shell =
        Enum.map_join([path | args], " ", &sh_quote/1) <> " < " <> sh_quote(tmp)

      env = build_invoke_env()
      opts = [{:stderr_to_stdout, true}] ++ if(env == [], do: [], else: [{:env, env}])

      case System.cmd("sh", ["-c", shell], opts) do
        {output, 0} -> extract_text_and_usage(output)
        {output, code} -> {:error, {:claude_failed, code, String.trim(output)}}
      end
    after
      File.rm(tmp)
    end
  end

  # Env pairs for the claude subprocess: release-var cleanup (converts false →
  # nil for System.cmd compatibility) + isolated CLAUDE_CONFIG_DIR.
  defp build_invoke_env do
    release_clean =
      Arbiter.Worker.ReleaseEnv.clean_pairs()
      |> Enum.map(fn
        {k, false} -> {k, nil}
        pair -> pair
      end)

    config_dir = Arbiter.Agents.Claude.ConfigDir.env()
    release_clean ++ config_dir
  end

  # POSIX single-quote escaping: wraps s in single quotes and escapes any
  # embedded single quote as '\''. Safe for arbitrary printable characters.
  defp sh_quote(s), do: "'" <> String.replace(s, "'", "'\\''") <> "'"

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

    consumer_section = consumer_refs_section(Map.get(state, :consumer_refs))

    """
    You are a code reviewer. Review the unified diff below for correctness,
    safety, and adherence to the task's intent. Be concise and focus on
    real problems — not style nits.

    #{task_line}#{consumer_section}Respond with a SINGLE JSON object and nothing else:

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

  # Repo-scoped reviews (bd-5xsp25) carry a deterministic cross-file consumer
  # trace in `state[:consumer_refs]` (see `ConsumerTrace`) — fold it into the
  # prompt as extra context so the reviewer can flag a call site the diff
  # itself never shows. Diff-scoped reviews have no `:consumer_refs` and get
  # no extra section, so the prompt is byte-for-byte unchanged from before.
  defp consumer_refs_section(refs) when is_list(refs) and refs != [] do
    lines =
      Enum.map(refs, fn ref ->
        "  - #{ref.file}:#{ref.line} calls `#{ref.identifier}` — #{ref.snippet}"
      end)

    """
    The diff changes an identifier with the following call sites elsewhere in \
    the repo (not shown in the diff itself). Check whether the change breaks \
    any of these callers:

    #{Enum.join(lines, "\n")}

    """
  end

  defp consumer_refs_section(_refs), do: ""

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
