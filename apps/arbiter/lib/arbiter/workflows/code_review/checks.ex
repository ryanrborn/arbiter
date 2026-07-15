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
        {filtered_diff, elided_paths} = filter_diff(diff, state)

        invoke_reviewer(build_prompt(filtered_diff, elided_paths, state), state)
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
  defp default_invoke(prompt, state) do
    case System.find_executable("claude") do
      nil ->
        {:error, {:executable_not_found, "claude"}}

      path ->
        # No prompt in args — delivered via stdin below.
        args =
          ["--print", "--output-format", "stream-json", "--verbose"]
          |> maybe_add_model_arg()
          |> maybe_add_agentic_args(state)

        invoke_via_stdin(path, args, prompt, review_cwd(state))
    end
  rescue
    e -> {:error, {:exception, Exception.message(e)}}
  end

  # Honor the active model slot when one is seeded in the process dict.
  # ReviewPatrol seeds `:review_agent` via `Agents.prepare(ws, :review_agent)`
  # before running a re-review, so re-reviews can run on a cheaper model than
  # the first pass (bd-f3fg22); mirrors `ReviewReply.default_compose/2`.
  defp maybe_add_model_arg(args) do
    case Arbiter.Agents.Claude.Config.active_model() do
      model when is_binary(model) and model != "" -> args ++ ["--model", model]
      _ -> args
    end
  end

  # Tier 2 (bd-6onexk): when the reviewer is running against a real PR-head
  # checkout (`state[:review_cwd]`, set by `Arbiter.Reviews.ExternalReview`),
  # grant it file/grep/bash tool access so it can explore beyond the diff —
  # the diff becomes the entry point, not the entire context. Reuses
  # `Arbiter.Agents.Claude.Security` + `Arbiter.Agents.SecurityPolicy` (the
  # same seam workers use) rather than an ad-hoc deny list, so the reviewer
  # gets the full destructive-op baseline plus `network: false` (which denies
  # `WebFetch`/`WebSearch` *and* `Bash(curl:*)`/`Bash(wget:*)`/etc — the
  # reviewer runs against untrusted external PR content and has no business
  # reaching the network at all) on top of denying the mutating tools
  # (Edit/Write/NotebookEdit) — the reviewer needs Read/Grep/Bash/Glob but not
  # write access to the checkout. Diff-only reviews (no `review_cwd`) get no
  # extra args, so the existing non-agentic invocation is byte-for-byte
  # unchanged.
  defp maybe_add_agentic_args(args, state) do
    case review_cwd(state) do
      nil ->
        args

      _cwd ->
        policy =
          Arbiter.Agents.SecurityPolicy.merge(Arbiter.Agents.SecurityPolicy.base(), %{
            "permissions" => %{"deny" => ["Edit", "Write", "NotebookEdit"]},
            "sandbox" => %{"network" => false}
          })

        args ++
          Arbiter.Agents.Claude.Security.permission_argv(policy) ++
          Arbiter.Agents.Claude.Security.settings_argv(policy)
    end
  end

  defp review_cwd(state) do
    case Map.get(state, :review_cwd) do
      cwd when is_binary(cwd) and cwd != "" -> cwd
      _ -> nil
    end
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
  defp invoke_via_stdin(path, args, prompt, cwd) do
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

      opts =
        [{:stderr_to_stdout, true}] ++
          if(env == [], do: [], else: [{:env, env}]) ++
          if(cwd, do: [{:cd, cwd}], else: [])

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

  defp build_prompt(diff, elided_paths, state) do
    task_line =
      case Map.get(state, :task) do
        %{id: id, title: title} -> "Task being reviewed: #{id} — #{title}\n\n"
        %{"id" => id, "title" => title} -> "Task being reviewed: #{id} — #{title}\n\n"
        _ -> ""
      end

    tracker_section = tracker_context_section(Map.get(state, :tracker_context))
    pr_section = pr_section(Map.get(state, :pr))
    consumer_section = consumer_refs_section(Map.get(state, :consumer_refs))
    tool_access_section = tool_access_section(review_cwd(state))
    elision_note = elision_note(elided_paths)

    """
    You are a code reviewer. Review the unified diff below for correctness,
    safety, and adherence to the task's intent. Be concise and focus on
    real problems — not style nits.

    #{task_line}#{tracker_section}#{pr_section}#{consumer_section}#{tool_access_section}Respond with a SINGLE JSON object and nothing else:

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
    #{elision_note}#{diff}
    --- END DIFF ---
    """
  end

  # Ticket body/description for the tracker item the PR implements (bd-adpwl0).
  # `state[:tracker_context]` is threaded in by the caller (e.g.
  # `Arbiter.Reviews.ExternalReview`) as `%{ref:, type:, title:, description:}`
  # fetched read-only via the workspace tracker adapter. Absent for local
  # reviews and for PRs with no linked ticket — the prompt is then unchanged.
  defp tracker_context_section(%{ref: ref} = ctx) when is_binary(ref) and ref != "" do
    body =
      [ctx[:title] && "Title: #{ctx[:title]}", ctx[:description]]
      |> Enum.filter(&non_blank?/1)
      |> Enum.join("\n\n")

    """
    --- Tracker ticket (read-only, #{ctx[:type]}:#{ref}) ---
    #{body}
    --- End tracker ticket ---

    """
  end

  defp tracker_context_section(_ctx), do: ""

  # `state.pr` is populated by `CodeReview`'s `:load_pr` step in `:adapter`
  # mode (the raw adapter `get/1` map) but was previously unused by the
  # prompt — the reviewer never saw the PR author's own description of what
  # the change is meant to do (bd-adpwl0).
  defp pr_section(pr) when is_map(pr) do
    title = pr[:title] || pr["title"]
    body = pr[:body] || pr["body"]

    if non_blank?(title) or non_blank?(body) do
      parts =
        [non_blank?(title) && "Title: #{title}", non_blank?(body) && "Body:\n#{body}"]
        |> Enum.filter(& &1)
        |> Enum.join("\n\n")

      """
      --- PR description ---
      #{parts}
      --- End PR description ---

      """
    else
      ""
    end
  end

  defp pr_section(_pr), do: ""

  defp non_blank?(s) when is_binary(s), do: String.trim(s) != ""
  defp non_blank?(_), do: false

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

  # Tier 2 (bd-6onexk): when a real PR-head checkout is available, tell the
  # reviewer it isn't limited to the diff below — it has read-only Read/Grep/
  # Bash/Glob access at `cwd` and should use it to check real call sites,
  # open neighboring modules, etc. Diff-only reviews (no checkout) get no
  # such note since there is nothing to explore.
  #
  # bd-2n3qm6: the checkout is context ONLY. GitHub's inline-comment API
  # rejects (422s) any finding whose (path, line) isn't part of the diff —
  # and that 422 previously failed the whole review, discarding every
  # finding. Findings must stay scoped to the diff; anything the checkout
  # surfaces about code outside it belongs in prose (the summary), not as a
  # `findings` entry.
  defp tool_access_section(nil), do: ""

  defp tool_access_section(cwd) when is_binary(cwd) do
    """
    You are running with read-only file tools (Read, Grep, Bash, Glob) at \
    #{cwd}, checked out at the PR's actual head commit. This checkout is \
    purely as context — to understand call sites, types, and neighboring \
    code so your review of the diff is well-informed. It is NOT a surface \
    to review: report findings ONLY on files and lines that are part of \
    the diff below. An out-of-diff observation is not a `findings` entry — \
    a finding whose file/line isn't in the diff cannot be posted inline. \
    You cannot edit or write files in this checkout.

    """
  end

  # Generated/minified/lockfile diffs (bundled `app.js`, `package-lock.json`,
  # `mix.lock`) add nothing for a reviewer to check but routinely blow past
  # the model's context window (VR-18174 #3652: ~1.5M tokens from one bundled
  # asset). Strip whole-file diff hunks matching an exclude glob before they
  # ever reach the prompt; note what was dropped so the reviewer (and anyone
  # reading its findings) knows the diff was incomplete on purpose.
  @default_diff_excludes ["priv/static/**", "*-lock.json", "mix.lock"]

  defp filter_diff(diff, state) do
    excludes = diff_exclude_globs(state)

    diff
    |> split_diff_by_file()
    |> Enum.reduce({[], []}, fn {path, chunk}, {kept, elided} ->
      if excluded_path?(path, excludes) do
        {kept, [path | elided]}
      else
        {[chunk | kept], elided}
      end
    end)
    |> then(fn {kept, elided} ->
      {kept |> Enum.reverse() |> Enum.join(), Enum.reverse(elided)}
    end)
  end

  defp diff_exclude_globs(state) do
    case Map.get(state, :diff_exclude_globs) do
      globs when is_list(globs) -> globs
      _ -> @default_diff_excludes
    end
  end

  defp excluded_path?(path, excludes) when is_binary(path) do
    Enum.any?(excludes, &Arbiter.Worker.ReviewScope.glob_match?(&1, path))
  end

  defp excluded_path?(_path, _excludes), do: false

  # Split a unified diff into one chunk per file, each starting at its
  # `diff --git a/<path> b/<path>` header. A diff with no such headers (e.g.
  # a test fixture, or an adapter that returns a bare hunk) is returned as a
  # single unmatched chunk — nothing to filter, so it always passes through.
  defp split_diff_by_file(diff) do
    diff
    |> String.split(~r/(?=^diff --git )/m)
    |> Enum.reject(&(&1 == ""))
    |> Enum.map(fn chunk -> {diff_chunk_path(chunk), chunk} end)
  end

  defp diff_chunk_path(chunk) do
    case Regex.run(~r/^diff --git a\/(.+?) b\/.+$/m, chunk) do
      [_, path] -> path
      _ -> nil
    end
  end

  defp elision_note([]), do: ""

  defp elision_note(paths) do
    "[#{length(paths)} generated/lockfile path(s) elided from this diff: " <>
      "#{Enum.join(paths, ", ")}]\n\n"
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
