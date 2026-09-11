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
  `fun` is a `(prompt, state) -> result` function. This bypasses Claude
  entirely. The default invoker shells out to
  `claude --print ... --output-format stream-json`. Tests should always set
  an override to avoid hitting the real CLI.

  `result` is one of:

      {:ok, text}
      {:ok, text, usage}
      {:ok, text, usage, raw_output}
      {:error, reason}
      {:error, reason, raw_output}

  where `raw_output` is the reviewer's unparsed stdout. When present — and
  the state carries a `:review_record_id` — it is persisted as the review's
  durable transcript (`Arbiter.Reviews.Transcript`, bd-7efini) before being
  stripped from the return value, so `run/2`'s callers only ever see the
  3-element shapes.

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

  alias Arbiter.Agents.Claude.Config, as: ClaudeConfig
  alias Arbiter.Agents.Claude.ConfigDir
  alias Arbiter.Agents.Claude.Security
  alias Arbiter.Workflows.ReviewPatrol.ThreadMemory

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
    if String.trim(diff) == "" do
      {:ok, []}
    else
      {filtered_diff, elided_paths} = filter_diff(diff, state)

      invoke_reviewer(build_prompt(filtered_diff, elided_paths, state), state)
      |> case do
        {:ok, raw} -> {:ok, parse_findings(raw, state)}
        {:ok, raw, usage} -> {:ok, parse_findings(raw, state), usage}
        {:error, _} = err -> err
      end
    end
  end

  # ---- internals --------------------------------------------------------

  # The invoker contract has two shapes. The 3-element ones
  # (`{:ok, text}` / `{:ok, text, usage}` / `{:error, reason}`) are what a
  # non-Claude runner or a test stub returns. The default invoker additionally
  # hands back the reviewer's RAW stdout as a trailing element
  # (`{:ok, text, usage, raw}` / `{:error, reason, raw}`); that raw corpus is
  # persisted here as the review's durable transcript (bd-7efini) and then
  # dropped from the return value, so `run/2` and the workflow see exactly the
  # shapes they always did.
  defp invoke_reviewer(prompt, state) do
    persist_review_prompt(prompt, state)
    invoker = Application.get_env(:arbiter, :code_review_invoker) || (&default_invoke/2)

    case invoker.(prompt, state) do
      {:ok, text, usage, raw} ->
        persist_review_transcript(raw, state)
        {:ok, text, usage}

      {:error, reason, raw} ->
        persist_review_transcript(raw, state)
        {:error, reason}

      other ->
        other
    end
  end

  # bd-9rdwe4 (#1017 gap G5): this is the shared invoker for BOTH
  # `Arbiter.Reviews.ExternalReview` and `Arbiter.Workflows.ReviewPatrol`'s
  # re-review — neither spawns through `Arbiter.Worker`/`ClaudeSession`, so
  # neither gets prompt persistence for free from that choke-point. Callers
  # that want their prompt recorded set `state[:review_record_id]` (an
  # `Arbiter.Reviews.Record` id for an external review, an engagement
  # `Issue` id for a ReviewPatrol re-review) — anything without one (the
  # legacy diff-only `CodeReview` workflow, most existing tests) is
  # unaffected. Redacted with the SAME `Arbiter.Redaction.redact/2` used by
  # the worker transcript/prompt choke-point, using the workspace's
  # secret-flagged worker env values when a workspace is in state.
  defp persist_review_prompt(prompt, state) do
    case Map.get(state, :review_record_id) do
      id when is_binary(id) and id != "" ->
        redacted = Arbiter.Redaction.redact(prompt, review_redact_values(state))
        Arbiter.Worker.PromptLog.write(id, redacted)

      _ ->
        :ok
    end
  rescue
    e ->
      Logger.warning("CodeReview.Checks: persist_review_prompt/2 failed: #{Exception.message(e)}")
      :ok
  end

  # bd-7efini (#1425): an external review is not task-linked, so it has no
  # `Arbiter.Workers.Run` row and gets none of the `OutputLog`/`ClaudeSession`
  # transcript capture a regular worker run does — the raw `stream-json` corpus
  # (every model turn, every tool call and its result) used to be parsed for
  # text + usage here and then discarded. `Arbiter.Reviews.Transcript` keys the
  # same corpus on the review record id, beside the prompt file above. Written
  # on the failure path too: a reviewer that exited non-zero is exactly when
  # someone needs to read what it actually did. Callers with no
  # `review_record_id` (the diff-only `CodeReview` workflow, most tests) are
  # unaffected. Redacted with the same values as the prompt.
  defp persist_review_transcript(raw, state) when is_binary(raw) do
    case Map.get(state, :review_record_id) do
      id when is_binary(id) and id != "" ->
        Arbiter.Reviews.Transcript.write(id, raw, review_redact_values(state))

      _ ->
        :ok
    end
  rescue
    e ->
      Logger.warning(
        "CodeReview.Checks: persist_review_transcript/2 failed: #{Exception.message(e)}"
      )

      :ok
  end

  defp persist_review_transcript(_raw, _state), do: :ok

  defp review_redact_values(%{workspace: %Arbiter.Tasks.Workspace{} = ws}) do
    Arbiter.Tasks.Workspace.worker_env_secret_values(ws)
  end

  defp review_redact_values(_state), do: []

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

        invoke_via_stdin(path, args, prompt, review_cwd(state), review_workspace(state))
    end
  rescue
    e -> {:error, {:exception, Exception.message(e)}}
  end

  # Honor the active model slot when one is seeded in the process dict.
  # ReviewPatrol seeds `:review_agent` via `Agents.prepare(ws, :review_agent)`
  # before running a re-review, so re-reviews can run on a cheaper model than
  # the first pass (bd-f3fg22); mirrors `ReviewReply.default_compose/2`.
  defp maybe_add_model_arg(args) do
    case ClaudeConfig.active_model() do
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
          Security.permission_argv(policy) ++
          Security.settings_argv(policy)
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
  # arbiter-managed worker config dir so the reviewer never inherits the
  # operator's personal ~/.claude persona, MCP servers, or permission posture.
  # Release-env vars (ROOTDIR/BINDIR/RELEASE_*) are stripped so a node repo's
  # .nvmrc — if picked up by a shell hook — can't switch the Node runtime out
  # from under the reviewer process.
  defp invoke_via_stdin(path, args, prompt, cwd, workspace) do
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

      env = build_invoke_env(workspace)

      opts =
        [{:stderr_to_stdout, true}] ++
          if(env == [], do: [], else: [{:env, env}]) ++
          if(cwd, do: [{:cd, cwd}], else: [])

      # The raw `output` rides back to `invoke_reviewer/2` as a trailing
      # element on both branches so it can be persisted as the review's
      # durable transcript (bd-7efini) before being reduced to text + usage.
      case System.cmd("sh", ["-c", shell], opts) do
        {output, 0} ->
          {:ok, text, usage} = extract_text_and_usage(output)
          {:ok, text, usage, output}

        {output, code} ->
          {:error, {:claude_failed, code, String.trim(output)}, output}
      end
    after
      File.rm(tmp)
    end
  end

  # The workspace this review is running under, when the caller put one in
  # state (`ReviewPatrol` / `ExternalReview` do). `nil` for an ad-hoc,
  # workspace-less review — `ConfigDir.env/1` then falls back to the server
  # environment for the worker OAuth token (bd-bw3466).
  defp review_workspace(%{workspace: %Arbiter.Tasks.Workspace{} = ws}), do: ws
  defp review_workspace(_state), do: nil

  # Env pairs for the claude subprocess: release-var cleanup (converts false →
  # nil for System.cmd compatibility) + isolated CLAUDE_CONFIG_DIR.
  defp build_invoke_env(workspace) do
    release_clean =
      Arbiter.Worker.ReleaseEnv.clean_pairs()
      |> Enum.map(fn
        {k, false} -> {k, nil}
        pair -> pair
      end)

    config_dir = ConfigDir.env(workspace)
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
    ci_section = ci_status_section(pipeline_status(state))
    incremental_note = incremental_review_note(Map.get(state, :incremental_review))
    settled_section = ThreadMemory.prompt_section(Map.get(state, :settled_threads))
    consumer_section = consumer_refs_section(Map.get(state, :consumer_refs))
    tool_access_section = tool_access_section(review_cwd(state))
    elision_note = elision_note(elided_paths)

    """
    You are a code reviewer. Review the unified diff below for correctness,
    safety, and adherence to the task's intent. Be concise and focus on
    real problems — not style nits.

    #{task_line}#{tracker_section}#{pr_section}#{ci_section}#{incremental_note}#{settled_section}#{consumer_section}#{tool_access_section}Respond with a SINGLE JSON object and nothing else:

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

    "error" is blocking — it fails the PR. Only use "error" for something you
    directly observed in the diff (or, when you have tool access, in a file
    you actually opened). If your claim depends on code outside the diff that
    you have not read — "unless X has a Y clause…", "if Z has no…", "verify
    that…", "this is unverified…" — it is not a finding you have checked, so
    it must never be "error". Either open the file to check (when you have
    tool access) or report it at "info" phrased as a question to the author,
    not as a defect.

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

  # bd-a16rgk: the PR head SHA's CI status (from the same `adapter.get/1` call
  # that populated `pr_section` above) is ground truth the reviewer would
  # otherwise have no way to check from a diff alone — surfacing it up front
  # heads off a finding like "every bearer-authenticated test 401s" before it
  # gets written, rather than only catching it after the fact in
  # `cap_ci_contradicted_severity/3`.
  defp ci_status_section(:success) do
    """
    --- CI status ---
    CI is GREEN on this PR's head commit. Do not report a finding that \
    predicts a broad test/request failure ("every test fails", "all calls \
    401", etc.) for code covered by that passing CI — it is directly \
    contradicted by the passing run. If you still believe a path is broken, \
    say why CI wouldn't catch it (untested path, flaky/skipped check).
    --- End CI status ---

    """
  end

  defp ci_status_section(_status), do: ""

  # ReviewPatrol re-review (bd-8vwgws): a follow-up pass hands `Checks.run/2`
  # only the diff of commits since the last review, not the full PR diff —
  # `state.pr` above still carries the PR's CURRENT (full) title/body, so a
  # description claim about a file the new commit didn't touch (e.g. "bumped
  # in three places") reads as unsubstantiated against this partial diff even
  # though it's true of the PR as a whole. Without this note the reviewer has
  # no way to tell the diff below is partial and reports the claim as missing.
  defp incremental_review_note(true) do
    """
    --- NOTE ---
    The diff below covers only the commits pushed since the last review of \
    this PR, not the full PR diff. Do not report anything in the PR \
    description as missing, not implemented, or not included in the PR on \
    the basis of this diff alone — it may already exist in an earlier commit \
    not shown here. Only flag issues actually introduced or left unresolved \
    in this diff.
    --- End NOTE ---

    """
  end

  defp incremental_review_note(_), do: ""

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
  defp parse_findings(raw, state) when is_binary(raw) do
    case extract_json_object(raw) do
      nil ->
        Logger.debug("CodeReview.Checks: no JSON object in reviewer output; treating as empty")
        []

      json ->
        case Jason.decode(json) do
          {:ok, %{"findings" => findings}} when is_list(findings) ->
            findings
            |> Enum.map(&normalize_finding(&1, state))
            |> Enum.reject(&is_nil/1)

          _ ->
            Logger.debug("CodeReview.Checks: reviewer output failed to decode as findings JSON")
            []
        end
    end
  end

  defp parse_findings(_, _state), do: []

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

  defp normalize_finding(%{} = entry, state) do
    with {:ok, severity} <- normalize_severity(Map.get(entry, "severity")),
         file when is_binary(file) and file != "" <- Map.get(entry, "file"),
         line when is_integer(line) and line > 0 <- normalize_line(Map.get(entry, "line")),
         message when is_binary(message) and message != "" <- Map.get(entry, "message") do
      severity =
        severity
        |> cap_hedged_severity(message)
        |> cap_ci_contradicted_severity(message, pipeline_status(state))
        |> verify_with_github(message, state)

      %{
        severity: severity,
        file: file,
        line: line,
        message: message
      }
    else
      _ -> nil
    end
  end

  defp normalize_finding(_entry, _state), do: nil

  # bd-a16rgk: an ERROR finding is blocking (`compute_verdict/1` turns any
  # `:error` severity into `:request_changes`). The diff-only reviewer can't
  # check conditions outside the diff, so it sometimes hedges ("unless X has a
  # Y clause…", "verify that…", "is unverified…") and still tags the claim
  # `error` — a claim the reviewer never actually checked should never block a
  # PR. Downgrade any `:error` finding whose message reads as hedged/
  # conditional to `:info` regardless of what the model asserted; this is a
  # deterministic net independent of the prompt instructions (see
  # `build_prompt/3`) asking the reviewer not to do this in the first place.
  @hedge_patterns [
    ~r/\bunless\b/i,
    ~r/\bif\b[^.!?]{0,80}\bhas no\b/i,
    ~r/\bverify (that|whether)\b/i,
    ~r/\b(is|looks|seems) unverified\b/i,
    ~r/\bnothing (has )?exercis/i,
    ~r/\bunclear (whether|if)\b/i,
    ~r/\bcan(?:no|')t confirm\b/i,
    ~r/\bassuming (that|the)\b/i
  ]

  defp cap_hedged_severity(:error, message) do
    if hedged?(message), do: :info, else: :error
  end

  defp cap_hedged_severity(severity, _message), do: severity

  defp hedged?(message) when is_binary(message) do
    Enum.any?(@hedge_patterns, &Regex.match?(&1, message))
  end

  # bd-a16rgk: "Green CI is evidence." `state[:pr]` (set by `:load_pr` for
  # `mode: :adapter` — both the first-pass review and every ReviewPatrol
  # re-review go through the same step) carries the adapter's `pipeline`
  # status for the exact SHA under review. A finding that predicts a *broad*
  # test/request failure ("every test 401s", "raises ... for every call")
  # is directly contradicted when that same SHA's CI is green — the claim was
  # never checked against the one signal that was checkable for free, no repo
  # access required. Downgrade to :info rather than drop it outright: the
  # reviewer may be right that CI doesn't cover the path it's worried about,
  # so it's still worth a non-blocking question to the author.
  @broad_failure_patterns [
    ~r/\bevery\b[^.!?]{0,80}\b(test|call|request)\b[^.!?]{0,60}\b(fail|401|403|404|500|error|crash|raise)/i,
    ~r/\ball\b[^.!?]{0,80}\btests?\b[^.!?]{0,60}\b(fail|break|error|crash)/i
  ]

  defp cap_ci_contradicted_severity(:error, message, :success) do
    if broad_failure_claim?(message), do: :info, else: :error
  end

  defp cap_ci_contradicted_severity(severity, _message, _pipeline), do: severity

  defp broad_failure_claim?(message) when is_binary(message) do
    Enum.any?(@broad_failure_patterns, &Regex.match?(&1, message))
  end

  defp pipeline_status(state) when is_map(state) do
    case Map.get(state, :pr) do
      %{} = pr -> Map.get(pr, :pipeline) || Map.get(pr, "pipeline")
      _ -> nil
    end
  end

  defp pipeline_status(_state), do: nil

  # bd-a16rgk: "give the reviewer a way to check." The deterministic caps
  # above (`cap_hedged_severity/2`, `cap_ci_contradicted_severity/3`) only
  # catch a finding that HEDGES its own uncertainty, or that predicts a
  # broad failure CI already contradicts. They miss a finding stated
  # confidently but still wrong — e.g. "string-keyed claims raise
  # FunctionClauseError for every app-switch call" — where one file read
  # would have shown otherwise. For `strategy: github` (an adapter exposing
  # `file_content/3`) with no Tier-2 checkout already granting file access
  # (`review_cwd/1` nil — see `maybe_add_agentic_args/2`), fetch the specific
  # out-of-diff file the finding names at the PR's head SHA and ask the
  # reviewer to confirm or retract the finding against that evidence, before
  # letting the ERROR stand. Every step here is best-effort and fails open —
  # no adapter capability, no extractable file reference, a 404, or a
  # network error all leave the severity exactly as the earlier caps decided
  # (i.e. unchanged from today's behavior). This only ever downgrades a
  # finding the fetched file actually refutes; it never invents a reason to
  # keep one.
  defp verify_with_github(:error, message, state) do
    do_verify_with_github(message, state)
  rescue
    e ->
      Logger.debug("CodeReview.Checks: verify_with_github/3 failed: #{Exception.message(e)}")
      :error
  end

  defp verify_with_github(severity, _message, _state), do: severity

  defp do_verify_with_github(message, state) do
    with nil <- review_cwd(state),
         {adapter, mr_ref, sha} <- github_context(state),
         true <- Code.ensure_loaded?(adapter),
         true <- function_exported?(adapter, :file_content, 3),
         {:ok, path} <- referenced_out_of_diff_path(message, adapter, mr_ref),
         {:ok, content} <- adapter.file_content(mr_ref, path, sha) do
      case ask_reviewer_to_verify(message, path, content, state) do
        :refuted -> :info
        _ -> :error
      end
    else
      _ -> :error
    end
  end

  defp github_context(state) do
    case {Map.get(state, :adapter), Map.get(state, :mr_ref), pr_head_sha(state)} do
      {adapter, mr_ref, sha}
      when is_atom(adapter) and not is_nil(adapter) and is_binary(mr_ref) and is_binary(sha) ->
        {adapter, mr_ref, sha}

      _ ->
        nil
    end
  end

  defp pr_head_sha(state) do
    case Map.get(state, :pr) do
      %{} = pr -> Map.get(pr, :head_sha) || Map.get(pr, "head_sha")
      _ -> nil
    end
  end

  # A message that already cites a real relative path ("deps/verus_auth/
  # lib/.../authorize_jwt.ex:223-226") is fetched directly. Otherwise, look
  # for a CamelCase module-ish reference ("FallbackController",
  # "AuthorizeJwt") and, when the adapter also exposes `search_path/2`,
  # resolve it to a path via code search. `deps/` paths belong to a vendored
  # dependency's own upstream repo, not this one — a fetch there 404s and
  # falls back to the existing caps rather than resolving the pin, which is
  # out of scope here.
  @path_ref_pattern ~r{\b([\w.-]+/[\w.-]+\.\w+)\b}
  @module_ref_pattern ~r/\b([A-Z][a-zA-Z0-9]*(?:[A-Z][a-zA-Z0-9]*)+)\b/

  defp referenced_out_of_diff_path(message, adapter, mr_ref) do
    case Regex.run(@path_ref_pattern, message) do
      [_, path] ->
        {:ok, path}

      nil ->
        with [_, name] <- Regex.run(@module_ref_pattern, message),
             true <- function_exported?(adapter, :search_path, 2),
             {:ok, path} <- adapter.search_path(mr_ref, snake_filename(name)) do
          {:ok, path}
        else
          _ -> :error
        end
    end
  end

  defp snake_filename(name) do
    name
    |> String.replace(~r/([a-z0-9])([A-Z])/, "\\1_\\2")
    |> String.downcase()
    |> Kernel.<>(".ex")
  end

  # A short, focused follow-up call to the same invoker (bypassing the full
  # review prompt) asking a yes/no question against real evidence. Reuses
  # `invoke_reviewer/2` so it gets the same test-override seam
  # (`Application.put_env(:arbiter, :code_review_invoker, ...)`) as the main
  # review call — tests can distinguish the two by prompt content.
  defp ask_reviewer_to_verify(message, path, content, state) do
    prompt = """
    You previously flagged this as an ERROR-severity code review finding,
    but it depends on code outside the diff you reviewed:

    "#{message}"

    Here is the actual content of #{path} at the PR's head commit:

    --- BEGIN FILE ---
    #{String.slice(content, 0, 4000)}
    --- END FILE ---

    Does this file content REFUTE the finding above (i.e. show the claimed
    problem does not actually happen)? Respond with a SINGLE JSON object and
    nothing else: {"refuted": true | false}
    """

    case invoke_reviewer(prompt, state) do
      {:ok, raw} -> parse_refuted(raw)
      {:ok, raw, _usage} -> parse_refuted(raw)
      _ -> :unknown
    end
  end

  defp parse_refuted(raw) when is_binary(raw) do
    case extract_json_object(raw) do
      nil ->
        :unknown

      json ->
        case Jason.decode(json) do
          {:ok, %{"refuted" => true}} -> :refuted
          {:ok, %{"refuted" => false}} -> :confirmed
          _ -> :unknown
        end
    end
  end

  defp parse_refuted(_raw), do: :unknown

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
