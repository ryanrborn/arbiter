defmodule ArbiterCli.Cmd.Start do
  @moduledoc """
  `arb start [--timeout SECONDS] [--json]` — boot the Arbiter stack if it's down.

  A convenience for the common "I just want to work" moment: bring the local
  development stack up without remembering the two-step dance (`docker compose
  up -d` then `mix phx.server`).

  What it does:

    1. **No-op if already running.** Detected via the doctor reachability
       check (`GET /api/workspaces` against `ARB_HOST`). If Phoenix answers,
       the stack is up — print status and exit 0 without touching anything.
    2. **Ensure Postgres.** Run `docker compose up -d` from the project root.
       Idempotent: a no-op when the container is already healthy.
    3. **Start Phoenix.** Spawn `mix phx.server` detached (via `nohup`, output
       redirected to a log file) so it outlives this short-lived CLI process.
    4. **Wait for green.** Poll `arb doctor` until every check passes (or the
       timeout elapses), then print the status report.

  ## Project root

  Postgres and Phoenix are started from the umbrella root (where `compose.yml`
  and `mix.exs` live). It's resolved, in order:

    1. `ARB_HOME` — explicit override.
    2. The umbrella inferred from the running escript's path (build-tree only).
    3. A walk up from the current directory looking for `compose.yml`.

  If none resolve, the command errors with a hint to set `ARB_HOME`.

  ## Exit codes

    * `0` — stack is up and green (or was already running).
    * `1` — the stack failed to come up within the timeout, or a prerequisite
      (Docker, project root) was missing.
  """

  alias ArbiterCli.{Client, Cmd.Doctor}
  alias ArbiterCli.Output

  @switches [json: :boolean, timeout: :integer]

  # How long to wait for the stack to go green after starting it. A cold
  # `mix phx.server` may need to compile first, so the default is generous.
  @default_timeout_s 60
  @poll_interval_ms 500

  def run(argv) do
    {opts, _rest, _invalid} = OptionParser.parse(argv, switches: @switches)
    mode = if opts[:json], do: :json, else: :text
    timeout_ms = max(1, opts[:timeout] || @default_timeout_s) * 1000

    if Doctor.reachable?() do
      already_running(mode)
    else
      cold_start(mode, timeout_ms)
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
            "could not locate the Arbiter project root (no compose.yml found)",
            "Set ARB_HOME to your Arbiter checkout, or run `arb start` from inside it."
          )
      end

    actions = []

    actions = actions ++ [ensure_postgres(root)]
    actions = actions ++ [start_phoenix(root)]

    case wait_until_green(attempts_for(timeout_ms)) do
      :ok -> emit_started(mode, actions, true, timeout_ms)
      :timeout -> emit_timeout(mode, actions, timeout_ms)
    end
  end

  # ---- postgres ----------------------------------------------------------

  # `docker compose up -d` is idempotent — a no-op when the container is
  # already up — so we run it unconditionally on the cold path.
  defp ensure_postgres(root) do
    log_text("Ensuring Postgres is up (docker compose up -d)…")

    case run_cmd("docker", ["compose", "up", "-d"], cd: root, stderr_to_stdout: true) do
      {_out, 0} ->
        {:postgres, :ok, nil}

      {out, code} ->
        Output.die(
          "docker compose up -d failed (exit #{code})",
          "Is the Docker daemon running? Output:\n" <> String.trim_trailing(out)
        )
    end
  rescue
    e in ErlangError ->
      # System.cmd raises when the executable isn't found (:enoent).
      Output.die(
        "could not run docker: #{inspect(e.original)}",
        "Install Docker and ensure `docker` is on your PATH."
      )
  end

  # ---- phoenix -----------------------------------------------------------

  @doc """
  Start Phoenix detached so it survives this escript exiting. `nohup` plus a
  redirect to a log file and a backgrounding `&` means the shell returns
  immediately while `mix phx.server` keeps running, reparented to init.

  Returns `{:phoenix, :ok, log_path}`. The spawned server inherits this
  process's environment (so `GITHUB_TOKEN` and friends carry through). Shared
  with `arb restart` so the two have one definition of "start Phoenix".
  """
  @spec start_phoenix(String.t()) :: {:phoenix, :ok, String.t()}
  def start_phoenix(root) do
    log = phoenix_log_path()
    log_text("Starting Phoenix (mix phx.server)… logging to #{log}")

    script = "nohup mix phx.server > '#{log}' 2>&1 < /dev/null &"

    case run_cmd("sh", ["-c", script], cd: root, stderr_to_stdout: true) do
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
  Resolve the umbrella root the stack is started from: `ARB_HOME`, else the
  escript-derived umbrella, else a walk up from the current directory looking
  for `compose.yml`. Returns `{:ok, dir}` or `:error`.
  """
  @spec project_root() :: {:ok, String.t()} | :error
  def project_root do
    cond do
      (home = System.get_env("ARB_HOME")) not in [nil, ""] ->
        {:ok, Path.expand(home)}

      dir = escript_umbrella() ->
        {:ok, dir}

      dir = walk_up_for_compose(File.cwd!()) ->
        {:ok, dir}

      true ->
        :error
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

  defp walk_up_for_compose(dir) do
    parent = Path.dirname(dir)

    cond do
      File.exists?(Path.join(dir, "compose.yml")) ->
        dir

      # Reached the filesystem root without finding compose.yml.
      parent == dir ->
        nil

      true ->
        walk_up_for_compose(parent)
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
