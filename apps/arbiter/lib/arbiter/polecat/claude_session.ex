defmodule Arbiter.Polecat.ClaudeSession do
  @moduledoc """
  Port wrapper that runs a child process (eventually Claude Code CLI) inside a
  worktree and streams its stdout into a parent `Arbiter.Polecat` GenServer.

  This is Phase 2's I/O surface for the polecat. **No tmux** — we drive Claude
  Code (or any echo-script spike) directly through an Erlang `Port` so the
  parent process sees output line-by-line and can react to completion signals
  without polling a tty.

  ## Architecture

      caller (the polecat)
        │
        ▼
      ClaudeSession.start(opts)
        │   (synchronous GenServer.call to the owner polecat)
        ▼
      polecat handle_call(:__start_session__)
        │   Port.open/2 — polecat becomes the port owner
        ▼
      polecat handle_info({port, ...})
        │   • append line to meta[:output_lines]   (cap @line_cap)
        │   • Phoenix.PubSub.broadcast {:polecat_output, bead_id, line}
        │   • on "gt done" → Polecat.complete(self())
        │   • on {:exit_status, n} → meta[:exit_status], broadcast :polecat_exited
        ▼

  We deliberately open the `Port` *from inside* the polecat's process (via a
  GenServer.call hop) so the polecat itself owns the port. Port messages only
  flow to the port owner; if `ClaudeSession.start/1` opened the port in the
  caller process and then tried to hand it over, we'd race ownership transfer
  against early child output. The GenServer.call hop is synchronous from the
  caller's perspective and avoids that footgun.

  ## Completion detection

  Any output line matching `~r/\\bgt done\\b/` triggers `Polecat.complete/2`.
  The regex is intentionally word-bounded so the substring "gt doneness" or a
  prose mention "running gt done-style flows" doesn't trip it — but a literal
  marker line like `gt done` (or `>> gt done <<`) does. Reviewers: this is the
  detection surface for false positives in real Claude output; tighten if
  needed (e.g. anchor to start-of-line) once we see real transcripts.

  ## Output buffering

  We keep at most `#{1000}` recent lines in `meta[:output_lines]` to avoid
  unbounded memory growth on chatty children. The list is stored newest-first
  for O(1) prepend; flip with `Enum.reverse/1` for display. The cap is
  arbitrary; reviewers should weigh it against expected Claude session length.
  No back-pressure to the child — we never block on slow consumers.

  ## PubSub topic

  Default topic is `"polecat:" <> bead_id`. Subscribers (LiveView, CLI
  followers, tests) must know the bead_id to subscribe. The `:topic` opt
  overrides this.
  """

  alias Arbiter.Polecat

  @line_cap 1000
  @done_regex ~r/\bgt done\b/

  @typedoc "Accepted options for `start/1`."
  @type opt ::
          {:worktree_path, String.t()}
          | {:prompt, String.t()}
          | {:command, [String.t()] | nil}
          | {:topic, String.t() | nil}
          | {:owner, pid()}

  @type opts :: [opt()]

  @doc false
  def line_cap, do: @line_cap

  @doc false
  def done_regex, do: @done_regex

  @doc """
  Start a Claude (or echo-spike) session in `worktree_path`, streaming output
  into the `:owner` polecat.

  ## Required opts

    * `:worktree_path` — absolute path, must exist. The child runs with this
      as cwd.
    * `:owner` — pid of the parent polecat GenServer. Becomes the port owner
      and receives all port messages.

  ## Optional opts

    * `:prompt` — passed to Claude as the prompt. Required when `:command`
      is `nil` (real Claude invocation).
    * `:command` — full argv list as `[exec, arg1, arg2, ...]`. When set,
      overrides the default `["claude", "--print", prompt]`. Tests **must**
      pass this so we don't shell out to real Claude.
    * `:topic` — PubSub topic to broadcast output on. Defaults to
      `"polecat:" <> bead_id`.

  ## Returns

    * `{:ok, port}` on success. The port is owned by the `:owner` polecat.
    * `{:error, reason}` if the executable can't be resolved or the worktree
      path is invalid.
  """
  @spec start(opts()) :: {:ok, port()} | {:error, term()}
  def start(opts) when is_list(opts) do
    with {:ok, owner} <- fetch_owner(opts),
         {:ok, worktree_path} <- fetch_worktree(opts),
         {:ok, argv, env} <- resolve_argv(opts),
         {:ok, exec} <- resolve_executable(argv) do
      bead_id = bead_id_for(owner)
      topic = Keyword.get(opts, :topic) || default_topic(bead_id)

      session_config = %{
        bead_id: bead_id,
        topic: topic,
        line_cap: @line_cap,
        done_regex: @done_regex
      }

      port_args = %{
        exec: exec,
        argv: argv,
        cd: worktree_path,
        env: env
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
            # Wrap claude in `sh -c` with stdin redirected from /dev/null so the
            # CLI doesn't spend its first 3s waiting for stdin input (printing a
            # "Warning: no stdin data received" line). `exec` replaces the shell
            # so no extra process sits between the port and claude. Prompt
            # arrives via env to dodge shell-escaping a long, quote-laden value.
            argv = ["sh", "-c", ~S(exec claude --print "$_ARB_PROMPT" </dev/null)]
            env = [{~c"_ARB_PROMPT", String.to_charlist(prompt)}]
            {:ok, argv, env}

          _ ->
            {:error, :missing_prompt}
        end

      [exec | _rest] = argv when is_binary(exec) ->
        {:ok, argv, []}

      _ ->
        {:error, :invalid_command}
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

  defp bead_id_for(owner) do
    case Polecat.state(owner) do
      %{bead_id: id} -> id
      _ -> nil
    end
  end

  defp default_topic(nil), do: "polecat:unknown"
  defp default_topic(bead_id), do: "polecat:" <> bead_id

  # ---- helpers called from Polecat's handle_info -------------------------
  #
  # These live here (rather than inlined into polecat.ex) so the port message
  # routing logic stays colocated with the rest of the session module. The
  # polecat just shuttles messages to us.

  @doc false
  @spec handle_data(map(), binary()) :: map()
  def handle_data(%{} = session, line) when is_binary(line) do
    broadcast(session, {:polecat_output, session.bead_id, line})

    if Regex.match?(session.done_regex, line) do
      send(self(), {:__claude_session_done__, line})
    end

    %{session | output_lines: prepend_capped(session.output_lines, line, session.line_cap)}
  end

  @doc false
  @spec handle_exit(map(), integer()) :: map()
  def handle_exit(%{} = session, status) when is_integer(status) do
    broadcast(session, {:polecat_exited, session.bead_id, status})
    %{session | exit_status: status, exited_at: DateTime.utc_now()}
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
  def open_port(%{exec: exec, argv: [_ | rest], cd: cd} = args) do
    env = Map.get(args, :env, [])

    port_opts = [
      {:args, rest},
      {:cd, cd},
      {:line, 65_536},
      :binary,
      :exit_status,
      :stderr_to_stdout
    ]

    # Only set :env when non-empty — Port.open's :env *replaces* the child's
    # environment with exactly the given list, so [] would wipe PATH and friends.
    port_opts = if env == [], do: port_opts, else: port_opts ++ [{:env, env}]

    Port.open({:spawn_executable, exec}, port_opts)
  end
end
