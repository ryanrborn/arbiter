defmodule Arbiter.Agents.Codex do
  @moduledoc """
  OpenAI Codex CLI adapter implementing `Arbiter.Agents.Agent`.

  Drives `codex exec --json` — Codex's non-interactive mode — inside the
  worker's worktree, streaming its JSONL event feed back through the shared
  `Arbiter.Worker.ClaudeSession` port pipeline (which routes codex events to
  `Arbiter.Agents.Codex.Stream`). The scaffolding this adapter completes was
  landed ahead of it: MCP config injection (`Arbiter.MCP.AgentConfig.Codex`,
  a `.codex/config.toml`), quota tracking (`Arbiter.Quota.Codex`), and the
  `.codex/` worktree-artifact handling all already exist; this module is the
  final dispatch seam that makes `agent.type = "codex"` runnable.

  ## Invocation

  `codex exec --json --skip-git-repo-check <sandbox> [-m model] -- <prompt>`,
  wrapped in `sh -c 'exec "$@" < /dev/null'` so the child's stdin is closed
  (mirrors the Claude/Gemini spawn shape). The prompt is a literal positional
  parameter — never interpolated into the command string — so there is no
  shell-injection surface. Oversize prompts (> `MAX_ARG_STRLEN`) are written to
  a temp file and piped via stdin with a `-` positional, mirroring the E2BIG
  fix in `Arbiter.Agents.Claude.build_argv/3`.

  ## Authentication

  Codex normally authenticates via the operator's ChatGPT login under
  `$CODEX_HOME` (`~/.codex/auth.json`). An API key is optional: when a
  workspace configures one (or `OPENAI_API_KEY` is ambient) the adapter exports
  `OPENAI_API_KEY`; otherwise the CLI uses the on-disk ChatGPT auth.

  ## Security posture

  The normalized `Arbiter.Agents.SecurityPolicy` maps to Codex's OS-level
  sandbox (`-s`) + approval bypass:

    * `:bypass` (the headless-safe default) →
      `--dangerously-bypass-approvals-and-sandbox` — full access, no approval
      prompt to freeze a headless run. Mirrors Claude's
      `--dangerously-skip-permissions` default.
    * `:auto`   → `-s workspace-write` (writes scoped to the worktree; network
      re-enabled so workers can `git push` / install packages).
    * `:strict` → `-s read-only`.

  Codex has no per-tool deny-list analogue to Claude's `--settings`
  (`safe_defaults` categories like `no_force_push` / `no_pr_create`), so
  `security_enforced?/0` returns `false` — the REST posture surface shows the
  gap rather than over-claiming enforcement. The sandbox it *does* apply is a
  real kernel jail (Landlock/seccomp on Linux), stronger than Claude's
  permission-level guard, but the category-level deny contract is not
  expressible, hence the honest `false`.
  """

  @behaviour Arbiter.Agents.Agent

  alias Arbiter.Agents.Codex.Config
  alias Arbiter.Agents.Codex.Stream
  alias Arbiter.Agents.SecurityPolicy

  @done_regex ~r/\barb done\b/

  # See Arbiter.Agents.Claude for the MAX_ARG_STRLEN rationale. Codex reads its
  # prompt from stdin when the positional is `-`, so an oversize prompt goes to
  # a temp file piped in via the sh wrapper instead of into argv.
  @max_prompt_argv_bytes 131_072
  @prompt_tmp_prefix "arb_codex_prompt_"

  @impl true
  def provider, do: "codex"

  @impl true
  def security_enforced?, do: false

  @impl true
  def done_sentinel, do: @done_regex

  @impl true
  def default_argv(prompt, opts \\ []) when is_binary(prompt) do
    case resolve_executable() do
      {:ok, codex} ->
        flags =
          sandbox_argv(security_policy(opts)) ++ model_flag(opts)

        build_argv(codex, prompt, flags)

      {:error, _} = err ->
        err
    end
  end

  # Base `codex exec` flags shared by every spawn: JSON event stream + tolerate
  # linked worktrees (whose `.git` is a file, which Codex's repo check can trip
  # on). Callers append sandbox + model flags, then the `--`/prompt tail.
  @base_exec_flags ["--json", "--skip-git-repo-check"]
  @inline_prompt_script ~s(exec "$@" < /dev/null)
  @stdin_prompt_script ~s(f="$1"; shift; exec "$@" < "$f")

  @doc false
  def build_argv(codex, prompt, flags)
      when is_binary(codex) and is_binary(prompt) and is_list(flags) do
    head = [codex, "exec"] ++ @base_exec_flags ++ flags

    if byte_size(prompt) > @max_prompt_argv_bytes do
      case write_prompt_tmpfile(prompt) do
        {:ok, tmp} ->
          # `-` positional → codex reads the prompt from stdin (the temp file).
          {:ok, ["sh", "-c", @stdin_prompt_script, "sh", tmp] ++ head ++ ["--", "-"]}

        {:error, reason} ->
          {:error, {:prompt_tmpfile_failed, reason}}
      end
    else
      {:ok, ["sh", "-c", @inline_prompt_script, "sh"] ++ head ++ ["--", prompt]}
    end
  end

  defp write_prompt_tmpfile(prompt) do
    tmp =
      Path.join(
        System.tmp_dir!(),
        @prompt_tmp_prefix <> Integer.to_string(System.unique_integer([:positive])) <> ".txt"
      )

    case File.write(tmp, prompt) do
      :ok -> {:ok, tmp}
      {:error, _} = err -> err
    end
  end

  # Extract the stdin-delivery temp file path from an argv built by
  # `build_argv/3`, or `nil` when this argv used inline delivery. Lets the
  # worker unlink the file once the spawned port exits.
  @doc false
  def prompt_tmpfile(argv) when is_list(argv) do
    case Enum.at(argv, 4) do
      path when is_binary(path) -> if tmpfile_path?(path), do: path, else: nil
      _ -> nil
    end
  end

  defp tmpfile_path?(path), do: Path.basename(path) |> String.starts_with?(@prompt_tmp_prefix)

  @impl true
  def auth_probe_argv(_opts \\ []) do
    # Cheapest auth check: a one-word `codex exec` round-trip under a read-only
    # sandbox. A missing/expired ChatGPT login or bad key exits non-zero, which
    # Arbiter.Worker.StopReason classifies.
    case resolve_executable() do
      {:ok, codex} ->
        argv =
          ["sh", "-c", @inline_prompt_script, "sh", codex, "exec"] ++
            @base_exec_flags ++ ["-s", "read-only", "--", "ping"]

        {:ok, argv}

      {:error, _} = err ->
        err
    end
  end

  @impl true
  def spawn_env(opts \\ []) do
    case Keyword.get(opts, :api_key) || Config.resolve_api_key() do
      key when is_binary(key) and key != "" -> [{"OPENAI_API_KEY", key}]
      _ -> []
    end
  end

  @impl true
  def async_tool_instruction do
    "*** TOOLS: Run tools and wait inline for each result before proceeding.\n" <>
      "    Codex `exec` executes commands synchronously; do not attempt to background\n" <>
      "    long-running commands, and do not print your VERDICT or `arb done` until\n" <>
      "    every command you started has finished and you have read its output."
  end

  @impl true
  def init_session(opts \\ []) do
    %{
      line_buf: "",
      output_lines: [],
      usage: %{},
      activity: nil,
      activity_at: nil,
      model: Keyword.get(opts, :model)
    }
  end

  @impl true
  def parse_line(session, line) when is_binary(line) do
    case decode_event(line) do
      {:ok, event} ->
        session = absorb_usage(session, event)
        tuples = Stream.format_event(event)
        session = Enum.reduce(tuples, session, fn {text, _arm?}, acc -> accumulate(acc, text) end)
        {tuples, session}

      :error ->
        {[{line, true}], accumulate(session, line)}
    end
  end

  @impl true
  def usage_attrs(session) do
    Map.get(session, :usage, %{}) |> Map.put(:provider, provider())
  end

  @impl true
  def resolved_model(opts \\ []) do
    case Keyword.get(opts, :model) do
      m when is_binary(m) and m != "" ->
        m

      _ ->
        case Keyword.get(opts, :model_tier) do
          tier when is_binary(tier) and tier != "" ->
            Config.model_for_tier(tier) || Config.active_model()

          _ ->
            Config.active_model()
        end
    end
  end

  # ---- Internals ---------------------------------------------------------

  defp accumulate(session, text),
    do: Map.update(session, :output_lines, [text], &[text | &1])

  defp absorb_usage(session, event) do
    fields = Stream.usage_fields(event, Map.get(session, :model))

    usage =
      Enum.reduce(fields, Map.get(session, :usage, %{}), fn {k, v}, acc ->
        if is_nil(v), do: acc, else: Map.put(acc, k, v)
      end)

    Map.put(session, :usage, usage)
  end

  # Decode a JSONL line into a normalized codex event (top-level `"type"`).
  # Handles both the flat payload shape and an `{id, msg}` envelope some codex
  # builds wrap events in.
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
  defp normalize_event(%{"type" => _} = e), do: {:ok, e}
  defp normalize_event(_), do: :error

  # :bypass — no sandbox, no approval prompt (headless-safe default).
  defp sandbox_argv(%SecurityPolicy{permissions: %{mode: :bypass}}),
    do: ["--dangerously-bypass-approvals-and-sandbox"]

  # :strict — read-only sandbox; the agent can inspect but not mutate.
  defp sandbox_argv(%SecurityPolicy{permissions: %{mode: :strict}}), do: ["-s", "read-only"]

  # :auto — workspace-write; re-enable network so the worker can push / install.
  defp sandbox_argv(%SecurityPolicy{permissions: %{mode: :auto}} = policy) do
    ["-s", "workspace-write"] ++ network_config(policy)
  end

  defp sandbox_argv(_policy), do: ["--dangerously-bypass-approvals-and-sandbox"]

  # workspace-write disables network by default; opt back in when the policy's
  # sandbox allows it (workers need it for git push / package installs).
  defp network_config(%SecurityPolicy{sandbox: %{network: true}}),
    do: ["-c", "sandbox_workspace_write.network_access=true"]

  defp network_config(_policy), do: []

  # The resolved SecurityPolicy for this spawn; falls back to the install-wide
  # hardened default so a bare adapter call is still safe.
  defp security_policy(opts) do
    case Keyword.get(opts, :security) do
      %SecurityPolicy{} = policy -> policy
      _ -> SecurityPolicy.default()
    end
  end

  defp model_flag(opts) do
    case resolved_model(opts) do
      nil -> []
      model when is_binary(model) -> ["-m", model]
    end
  end

  defp resolve_executable do
    case System.find_executable("codex") do
      nil -> {:error, {:executable_not_found, "codex"}}
      path -> {:ok, path}
    end
  end
end
