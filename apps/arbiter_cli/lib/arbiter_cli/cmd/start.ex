defmodule ArbiterCli.Cmd.Start do
  @moduledoc """
  `arb start [--timeout SECONDS] [--json]` — boot the Arbiter stack if it's down.

  A convenience for the common "I just want to work" moment: start Phoenix
  without remembering the exact invocation.

  What it does:

    1. **No-op if already running.** Detected via the doctor reachability
       check (`GET /api/workspaces` against `ARB_HOST`). If Phoenix answers,
       the stack is up — print status and exit 0 without touching anything.
    2. **Start Phoenix.** Spawn `mix phx.server` detached (via `nohup`, output
       redirected to a log file) so it outlives this short-lived CLI process.
    3. **Wait for green.** Poll `arb doctor` until every check passes (or the
       timeout elapses), then print the status report.

  ## Project root

  Phoenix is started from the umbrella root (where `mix.exs` lives). It's
  resolved, in order:

    1. `ARB_HOME` — explicit override.
    2. The umbrella inferred from the running escript's path (build-tree only).
    3. The path recorded by `arb install-service` at `~/.config/arbiter/home`.
    4. A walk up from the current directory looking for `mix.exs`.

  If none resolve, the command errors with a hint to set `ARB_HOME`.

  ## Exit codes

    * `0` — stack is up and green (or was already running).
    * `1` — the stack failed to come up within the timeout, or a prerequisite
      (Docker, project root) was missing.
  """

  alias ArbiterCli.{Client, Cmd.Doctor, Cmd.Restart}
  alias ArbiterCli.Output

  @switches [json: :boolean, timeout: :integer]

  # How long to wait for the stack to go green after starting it. A cold
  # `mix phx.server` may need to compile first, so the default is generous.
  @default_timeout_s 60
  @poll_interval_ms 500

  def run(argv) do
    if "--help" in argv or "-h" in argv do
      IO.puts(@moduledoc)
    else
      {opts, _rest, _invalid} = OptionParser.parse(argv, switches: @switches)
      mode = if opts[:json], do: :json, else: :text
      timeout_ms = max(1, opts[:timeout] || @default_timeout_s) * 1000

      Restart.guard_acolyte_session!()

      if Doctor.reachable?() do
        already_running(mode)
      else
        cold_start(mode, timeout_ms)
      end
    end
  end

  # ---- already running ---------------------------------------------------

  defp already_running(:json) do
    IO.puts(
      Jason.encode!(%{
        already_running: true,
        actions: [],
        base_url: Client.base_url(),
        checks: Enum.map(Doctor.checks(), &Map.from_struct/1),
        ok: Doctor.green?()
      })
    )
  end

  defp already_running(:text) do
    IO.puts("Arbiter stack already running at #{Client.base_url()}")
    IO.puts("")
    Doctor.report()
  end

  # ---- cold start --------------------------------------------------------

  defp cold_start(mode, timeout_ms) do
    root =
      case project_root() do
        {:ok, dir} ->
          dir

        :error ->
          Output.die(
            "could not locate the Arbiter project root (no mix.exs found walking up from cwd)",
            "Set ARB_HOME to your Arbiter checkout, or run `arb start` from inside it."
          )
      end

    actions = [start_phoenix(root)]

    case wait_until_green(attempts_for(timeout_ms)) do
      :ok -> emit_started(mode, actions, true, timeout_ms)
      :timeout -> emit_timeout(mode, actions, timeout_ms)
    end
  end

  # ---- phoenix -----------------------------------------------------------

  @doc """
  Start Phoenix detached so it survives this escript exiting. `nohup` plus a
  redirect to a log file and a backgrounding `&` means the shell returns
  immediately while the server keeps running, reparented to init.

  Returns `{:phoenix, :ok, log_path}`. Shared with `arb restart` so the two
  have one definition of "start Phoenix".

  Launch strategy (in priority order):

  1. **`.run-server.sh`** — if `root/.run-server.sh` exists, delegate to it.
     That script `cd`s to the project root itself and re-exports the full
     runtime environment (`PATH` with mise shims, `GITHUB_TOKEN`, `JIRA_TOKEN`,
     `PORT=4848`), guaranteeing identical behaviour whether Phoenix was started
     by hand or by `arb start`/`arb restart`. This is the preferred path on a
     properly-set-up dev machine.

  2. **Inline fallback** — when `.run-server.sh` is absent, run
     `mix phx.server` directly from `root` (via `cd: root`). If `.arbiter.env`
     exists in `root` it is sourced first (via `set -a` so every assignment is
     automatically exported) to carry secrets into Phoenix's environment.
  """
  @spec start_phoenix(String.t()) :: {:phoenix, :ok, String.t()}
  def start_phoenix(root) do
    log = phoenix_log_path()
    run_server_sh = Path.join(root, ".run-server.sh")

    {script, run_opts} =
      if File.exists?(run_server_sh) do
        log_text("Starting Phoenix (#{run_server_sh})… logging to #{log}")
        # Run via `sh script` so no executable bit is required on the file.
        {"nohup sh '#{run_server_sh}' > '#{log}' 2>&1 < /dev/null &", [stderr_to_stdout: true]}
      else
        log_text("Starting Phoenix (mix phx.server)… logging to #{log}")
        # Source .arbiter.env if present so secrets reach Phoenix's env.
        script =
          "if [ -f .arbiter.env ]; then set -a; . ./.arbiter.env; set +a; fi; " <>
            "nohup mix phx.server > '#{log}' 2>&1 < /dev/null &"

        {script, [cd: root, stderr_to_stdout: true]}
      end

    case run_cmd("sh", ["-c", script], run_opts) do
      {_out, 0} ->
        {:phoenix, :ok, log}

      {out, code} ->
        Output.die(
          "failed to start Phoenix (exit #{code})",
          "Output:\n" <> String.trim_trailing(out)
        )
    end
  rescue
    e in ErlangError ->
      Output.die(
        "could not run mix: #{inspect(e.original)}",
        "Ensure Elixir/`mix` is installed and on your PATH."
      )
  end

  @doc "Path of the log file Phoenix's stdout/stderr is redirected to. Shared with `arb restart`."
  @spec phoenix_log_path() :: String.t()
  def phoenix_log_path do
    Path.join(System.tmp_dir!(), "arbiter-phoenix.log")
  end

  # ---- wait loop ---------------------------------------------------------

  @doc """
  Number of poll attempts that fit in `timeout_ms`. Count-based rather than
  wall-clock so tests can inject a no-op sleep and still terminate
  deterministically. Shared with `arb restart`.
  """
  @spec attempts_for(non_neg_integer()) :: pos_integer()
  def attempts_for(timeout_ms), do: div(timeout_ms, @poll_interval_ms) + 1

  @doc "Poll `arb doctor` until green or `attempts_left` is exhausted. Shared with `arb restart`."
  @spec wait_until_green(integer()) :: :ok | :timeout
  def wait_until_green(attempts_left) do
    cond do
      Doctor.green?() ->
        :ok

      attempts_left <= 0 ->
        :timeout

      true ->
        sleep(@poll_interval_ms)
        wait_until_green(attempts_left - 1)
    end
  end

  # ---- output ------------------------------------------------------------

  defp emit_started(:json, actions, ok, _timeout_ms) do
    IO.puts(
      Jason.encode!(%{
        already_running: false,
        actions: action_payload(actions),
        base_url: Client.base_url(),
        checks: Enum.map(Doctor.checks(), &Map.from_struct/1),
        ok: ok
      })
    )
  end

  defp emit_started(:text, _actions, _ok, _timeout_ms) do
    IO.puts("")
    IO.puts("Arbiter stack is up at #{Client.base_url()}")
    IO.puts("")
    Doctor.report()
  end

  defp emit_timeout(:json, actions, timeout_ms) do
    IO.puts(
      Jason.encode!(%{
        already_running: false,
        actions: action_payload(actions),
        base_url: Client.base_url(),
        checks: Enum.map(Doctor.checks(), &Map.from_struct/1),
        ok: false,
        timed_out_after_s: div(timeout_ms, 1000)
      })
    )

    Output.halt(1)
  end

  defp emit_timeout(:text, _actions, timeout_ms) do
    IO.puts("")
    IO.puts("Arbiter stack did not come up within #{div(timeout_ms, 1000)}s.")
    IO.puts("Last status:")
    IO.puts("")
    Doctor.report()
    IO.puts("")
    IO.puts("hint: tail #{phoenix_log_path()} for Phoenix startup output.")
    Output.halt(1)
  end

  defp action_payload(actions) do
    Enum.map(actions, fn {component, status, _detail} ->
      %{component: to_string(component), status: to_string(status)}
    end)
  end

  # ---- project root ------------------------------------------------------

  @doc """
  Resolve the umbrella root the stack is started from.

  Resolution order:

    1. `ARB_HOME` — explicit override; set this to your Arbiter checkout path
       if the other heuristics can't find it (e.g. when running from `$HOME`
       with an on-PATH escript install).
    2. The umbrella inferred from the running escript's path (build-tree only:
       path ends with `/apps/arbiter_cli/arb`).
    3. The path recorded by `arb install-service` at `~/.config/arbiter/home`
       (written on first install so commands work from any cwd after that).
    4. A walk up from the current directory looking for `mix.exs`.

  Returns `{:ok, dir}` or `:error`.
  """
  @spec project_root() :: {:ok, String.t()} | :error
  def project_root do
    cond do
      (home = System.get_env("ARB_HOME")) not in [nil, ""] ->
        {:ok, Path.expand(home)}

      dir = escript_umbrella() ->
        {:ok, dir}

      dir = recorded_home() ->
        {:ok, dir}

      dir = walk_up_for_mix(File.cwd!()) ->
        {:ok, dir}

      true ->
        :error
    end
  end

  @doc """
  Record `root` as the Arbiter home path so future invocations from any
  working directory can resolve it without `ARB_HOME`. Called by
  `arb install-service` after it has resolved the project root.
  """
  @spec record_home(String.t()) :: :ok
  def record_home(root) do
    path = recorded_home_path()
    path |> Path.dirname() |> File.mkdir_p!()
    File.write!(path, root)
  rescue
    _ -> :ok
  end

  @doc false
  @spec recorded_home_path() :: String.t()
  def recorded_home_path do
    Path.join([System.user_home!(), ".config", "arbiter", "home"])
  end

  # Read back the home path written by `record_home/1`. Returns the expanded
  # path when the file exists and is non-empty, nil otherwise.
  defp recorded_home do
    path = recorded_home_path()

    case File.read(path) do
      {:ok, home} when home not in ["", "\n"] ->
        expanded = home |> String.trim() |> Path.expand()
        if File.dir?(expanded), do: expanded, else: nil

      _ ->
        nil
    end
  end

  # The escript is built as `<umbrella>/apps/arbiter_cli/arb`; recover the
  # umbrella root when run from the build tree. An installed-on-PATH copy tells
  # us nothing useful, so decline. (Mirrors `Cmd.Init`.)
  defp escript_umbrella do
    :escript.script_name()
    |> to_string()
    |> Path.expand()
    |> derive_umbrella()
  rescue
    _ -> nil
  catch
    _, _ -> nil
  end

  defp derive_umbrella(path) do
    if String.ends_with?(path, "/apps/arbiter_cli/arb") do
      path |> Path.dirname() |> Path.dirname() |> Path.dirname()
    end
  end

  defp walk_up_for_mix(dir) do
    parent = Path.dirname(dir)

    cond do
      File.exists?(Path.join(dir, "mix.exs")) ->
        dir

      # Reached the filesystem root without finding mix.exs.
      parent == dir ->
        nil

      true ->
        walk_up_for_mix(parent)
    end
  end

  # ---- injectable seams (overridable in tests via the process dict) ------
  #
  # `@doc false` keeps these out of the generated docs while letting sibling
  # commands (notably `arb restart`) route through the same `:bd2_cmd_runner`
  # / `:bd2_sleep` seams, so one test stub covers both commands.

  @doc false
  # External command execution. Defaults to System.cmd/3; tests stub it to
  # record invocations and flip a fake "now reachable" signal without shelling
  # out. Returns `{output_binary, exit_status}`.
  def run_cmd(cmd, args, opts) do
    case Process.get(:bd2_cmd_runner) do
      fun when is_function(fun, 3) -> fun.(cmd, args, opts)
      _ -> System.cmd(cmd, args, opts)
    end
  end

  @doc false
  def sleep(ms) do
    case Process.get(:bd2_sleep) do
      fun when is_function(fun, 1) -> fun.(ms)
      _ -> Process.sleep(ms)
    end
  end

  @doc false
  # Progress chatter goes to stderr so `--json` stdout stays a single clean
  # object. Suppressed in tests via the same seam to keep captures tidy.
  def log_text(msg) do
    case Process.get(:bd2_sleep) do
      # In tests (sleep stubbed) stay quiet; otherwise narrate progress.
      fun when is_function(fun, 1) -> :ok
      _ -> IO.puts(:stderr, msg)
    end
  end
end
