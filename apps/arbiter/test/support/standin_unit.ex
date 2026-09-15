defmodule Arbiter.Test.StandinUnit do
  @moduledoc """
  A throwaway systemd **user service** that stands in for `arbiter.service`,
  and an `Arbiter.Sessions.Runner` that launches sessions *from inside it*
  (bd-b95w36; RFC §4.2's spike, turned into a harness).

  ## Why a stand-in unit at all

  Restart survival is a **cgroup** property (§4.1): `systemctl --user restart`
  signals every process in the restarted unit's cgroup, so whether a session
  survives depends entirely on which cgroup its tmux server landed in — and
  *that* is decided by the cgroup of the process that spawned it. A test that
  calls `Arbiter.Sessions.launch/1` straight from the ExUnit BEAM spawns from
  the *test's* cgroup, which nobody is ever going to restart. It can prove
  sibling placement (`Arbiter.Integration.SessionScopeTest` does), but it
  cannot prove survival, because there is nothing to restart.

  So the spawn has to happen inside a unit that can be restarted with no blast
  radius on the live coordinator. This module is that unit:

      unit = StandinUnit.start!()
      {:ok, session} = Sessions.launch(cwd: unit.work, runner: StandinUnit)
      StandinUnit.restart!(unit)          # the §4.2 event
      # session's scope is still active; the unit's own children are not

  ## How the launch gets inside the unit

  `Arbiter.Sessions.Runner` is a plain synchronous `run(cmd, args, opts)`
  behaviour, which makes this cheap. The unit's `ExecStart` is a small POSIX
  `sh` agent that watches a spool directory; `run/3` writes a request script
  into the spool and blocks until the agent has run it and written back the
  output and exit status. The agent is a faithful stand-in for the coordinator
  BEAM: a long-lived process inside the unit's cgroup that spawns sessions on
  demand. Everything `Arbiter.Sessions` does — the argv, the env, the ordering
  — is the real code path; only the *process* that executes the argv moves.

  ## Same `KillMode` as `arbiter.service`

  Set by **omission**, which is exactly how `arbiter.service` gets it: neither
  unit specifies `KillMode`, so systemd's default `control-group` applies and
  a restart signals the whole cgroup. `kill_mode/1` reads it back, and the
  test asserts it against `arbiter.service`'s own value where that unit is
  loaded, so "same `KillMode`" is measured rather than assumed.

  ## Teardown discipline

  This repo has an incident class around pattern-based kills. Every teardown
  here names the **exact** transient unit (derived from a fresh unique integer)
  and the **exact** tmux socket path it created; nothing in this file matches
  a process by name or command line.
  """

  @behaviour Arbiter.Sessions.Runner

  alias Arbiter.Test.SystemdUser

  @enforce_keys [:unit, :work, :plain_socket, :spool]
  defstruct [:unit, :work, :plain_socket, :spool]

  @type t :: %__MODULE__{
          unit: String.t(),
          work: String.t(),
          plain_socket: String.t(),
          spool: String.t()
        }

  @current :"$arbiter_standin_unit"

  # A sequenced tick every 100 ms: fast enough that a restart is crossed within
  # a second of wall clock, slow enough that a few hundred lines of tmux pane
  # history covers the whole run. The sequence number is the whole point —
  # "no gap" is `1..N` contiguous, exactly as §4.2 measured it.
  @tick_command ~S|i=0; while :; do i=$((i+1)); echo "tick $i"; sleep 0.1; done|

  @doc "The sequenced payload both the session pane and the negative control run."
  @spec tick_command() :: String.t()
  def tick_command, do: @tick_command

  @doc """
  Start the stand-in unit and register its teardown with the calling test.

  Blocks until the unit's agent is ready to accept commands. The returned
  struct is also stashed in the process dictionary, so `run/3` (which the
  `Runner` behaviour gives no state) knows which unit to dispatch to.

  On first start — and **only** on first start, which is what makes it a
  measurement rather than a coincidence — the agent also starts the §4.2
  negative control: a tmux server as a plain child of this unit, in this
  unit's own cgroup. After a restart it is not re-created, so the correct
  observation afterwards is "gone".
  """
  @spec start!(keyword()) :: t()
  def start!(opts \\ []) do
    :ok = require_systemd_user!()

    # Short on purpose: the session's tmux socket is created under this
    # directory, and an AF_UNIX path is capped at 108 bytes.
    tag = "arbrs#{System.unique_integer([:positive])}"
    work = Path.join(runtime_root(), tag)
    unit = "#{tag}-host.service"

    File.mkdir_p!(Path.join(work, "req"))
    File.mkdir_p!(Path.join(work, "res"))
    File.mkdir_p!(Path.join(work, "done"))

    agent = Path.join(work, "agent.sh")
    File.write!(agent, agent_script())

    standin = %__MODULE__{
      unit: unit,
      work: work,
      plain_socket: Path.join(work, "plain.sock"),
      spool: work
    }

    # Registered BEFORE the unit exists, so a failure inside `systemd-run`
    # itself still gets cleaned up. Every argument is an exact name.
    ExUnit.Callbacks.on_exit(fn -> teardown(standin) end)

    {out, status} =
      systemctl_family("systemd-run", [
        "--user",
        "--quiet",
        "--unit=#{unit}",
        "--description=arbiter restart-survival stand-in (bd-b95w36)",
        "--setenv=ARB_STANDIN_WORK=#{work}",
        "--setenv=ARB_STANDIN_TICK=#{Keyword.get(opts, :tick_command, @tick_command)}",
        "/bin/sh",
        agent
      ])

    if status != 0 do
      raise "could not start stand-in unit #{unit} (systemd-run exited #{status}):\n#{out}"
    end

    unless await(fn -> File.exists?(Path.join(work, "ready")) end) do
      raise "stand-in unit #{unit} never became ready:\n#{journal(standin)}"
    end

    Process.put(@current, standin)
    standin
  end

  @doc """
  Restart the stand-in unit — the §4.2 event — and return `{before, after}`
  `MainPID`s.

  Waits for the agent to come back up, and asserts the pid actually changed,
  because a `restart` that silently no-opped would make every survival
  assertion after it vacuous.
  """
  @spec restart!(t()) :: {String.t(), String.t()}
  def restart!(%__MODULE__{} = standin) do
    before_pid = main_pid(standin)
    File.rm(Path.join(standin.work, "ready"))

    {out, status} = systemctl(["--user", "restart", standin.unit])

    if status != 0 do
      raise "systemctl --user restart #{standin.unit} exited #{status}:\n#{out}"
    end

    unless await(fn -> File.exists?(Path.join(standin.work, "ready")) end) do
      raise "stand-in unit #{standin.unit} did not come back after restart:\n#{journal(standin)}"
    end

    after_pid = main_pid(standin)

    if before_pid == after_pid or before_pid == "" do
      raise "#{standin.unit} MainPID did not change across restart " <>
              "(before=#{inspect(before_pid)} after=#{inspect(after_pid)}) — " <>
              "the restart did not happen, so nothing below is a measurement"
    end

    {before_pid, after_pid}
  end

  @doc "Stop the unit by exact name (the §4.6 \"arbiter never comes back\" case)."
  @spec stop!(t()) :: :ok
  def stop!(%__MODULE__{} = standin) do
    {_out, _status} = systemctl(["--user", "stop", standin.unit])
    :ok
  end

  @doc "The unit's `MainPID`, as a string (`\"0\"` when it is not running)."
  @spec main_pid(t()) :: String.t()
  def main_pid(%__MODULE__{unit: unit}), do: show(unit, "MainPID")

  @doc "The unit's effective `KillMode` — set by omission, read back here."
  @spec kill_mode(t() | String.t()) :: String.t()
  def kill_mode(%__MODULE__{unit: unit}), do: kill_mode(unit)
  def kill_mode(unit) when is_binary(unit), do: show(unit, "KillMode")

  @doc "`systemctl --user is-active <unit>`, trimmed (`\"active\"`, `\"inactive\"`, …)."
  @spec active_state(t() | String.t()) :: String.t()
  def active_state(%__MODULE__{unit: unit}), do: active_state(unit)

  def active_state(unit) when is_binary(unit) do
    {out, _status} = systemctl(["--user", "is-active", unit])
    String.trim(out)
  end

  @doc """
  The pid of the negative control's tmux server — the one started as a plain
  child of the unit, in the unit's own cgroup. `nil` before it has registered.
  """
  @spec plain_child_pid(t()) :: String.t() | nil
  def plain_child_pid(%__MODULE__{work: work}) do
    case File.read(Path.join(work, "plain.pid")) do
      {:ok, body} ->
        case String.trim(body) do
          "" -> nil
          pid -> pid
        end

      {:error, _} ->
        nil
    end
  end

  @doc "Whether a pid is still a live process, by exact pid — never by name."
  @spec alive?(String.t() | nil) :: boolean()
  def alive?(nil), do: false
  def alive?(pid) when is_binary(pid), do: File.dir?("/proc/#{pid}")

  @doc "The cgroup line for a pid, or `nil` when the process is gone."
  @spec cgroup(String.t() | nil) :: String.t() | nil
  def cgroup(nil), do: nil

  def cgroup(pid) when is_binary(pid) do
    case File.read("/proc/#{pid}/cgroup") do
      {:ok, body} -> String.trim(body)
      {:error, _} -> nil
    end
  end

  @doc "Recent journal lines for the unit, for failure messages."
  @spec journal(t()) :: String.t()
  def journal(%__MODULE__{unit: unit}) do
    {out, _status} =
      systemctl_family("journalctl", ["--user", "-u", unit, "-n", "40", "--no-pager"])

    out
  end

  @doc """
  Stop the unit and remove its scratch directory, by exact name and exact path.

  Idempotent, and safe to call when the unit never started. Also resets a
  failed transient unit, so a leftover `failed` entry cannot make the *next*
  run's `systemd-run --unit=` collide.
  """
  @spec teardown(t()) :: :ok
  def teardown(%__MODULE__{} = standin) do
    if File.exists?(standin.plain_socket) do
      _ = systemctl_family("tmux", ["-S", standin.plain_socket, "kill-server"])
    end

    _ = systemctl(["--user", "stop", standin.unit])
    _ = systemctl(["--user", "reset-failed", standin.unit])
    File.rm_rf(standin.work)
    :ok
  end

  # -- Arbiter.Sessions.Runner ------------------------------------------------

  @doc """
  Run a session control command **inside** the stand-in unit.

  Same contract as `Arbiter.Sessions.Runner.Host`: synchronous, returns
  `{output, exit_status}`, retains nothing. `opts[:env]` is exported by the
  request script, which is what `tmux -e` needs and what the real runner gets
  from `System.cmd`'s `:env`.
  """
  @impl Arbiter.Sessions.Runner
  def run(command, args, opts) do
    standin = Process.get(@current) || raise "no stand-in unit started in this process"

    id = "req-#{System.unique_integer([:positive])}"
    script = request_script(command, args, Keyword.get(opts, :env, []))

    # Written elsewhere and renamed in, so the agent can never read a
    # half-written script out of the spool.
    staging = Path.join([standin.work, "res", id <> ".staging"])
    File.write!(staging, script)
    File.rename!(staging, Path.join([standin.work, "req", id <> ".sh"]))

    done = Path.join([standin.work, "res", id <> ".done"])

    unless await(fn -> File.exists?(done) end, 600) do
      raise "stand-in unit #{standin.unit} never ran #{command} (#{id}):\n#{journal(standin)}"
    end

    status = done |> File.read!() |> String.trim() |> String.to_integer()
    out = Path.join([standin.work, "res", id <> ".out"]) |> File.read() |> elem(1)

    {to_string(out), status}
  end

  # -- internals --------------------------------------------------------------

  defp request_script(command, args, env) do
    exports =
      Enum.map_join(env, "\n", fn {name, value} ->
        "export #{name}=#{shell_quote(to_string(value))}"
      end)

    argv = Enum.map_join([command | args], " ", &shell_quote/1)

    """
    #!/bin/sh
    #{exports}
    exec #{argv}
    """
  end

  # POSIX single-quote escaping: everything is literal inside '…', and a
  # literal quote is spelled by closing, escaping, and reopening. The session
  # payload is a whole shell program, so this has to be right.
  defp shell_quote(value) do
    "'" <> String.replace(value, "'", "'\\''") <> "'"
  end

  # The stand-in coordinator. POSIX sh, no bashisms, so it runs under whatever
  # /bin/sh the host has.
  defp agent_script do
    ~S"""
    #!/bin/sh
    # Stand-in for arbiter.service (bd-b95w36). Two jobs:
    #   1. start the §4.2 negative control ONCE — a tmux server as a plain
    #      child of this unit, so it shares this unit's cgroup and a restart
    #      is expected to kill it;
    #   2. serve a command spool, so Arbiter.Sessions.launch/1 can spawn a
    #      session scope from inside this cgroup.
    set -u
    WORK="$ARB_STANDIN_WORK"
    mkdir -p "$WORK/req" "$WORK/res" "$WORK/done"

    if [ ! -e "$WORK/plain.started" ]; then
      : > "$WORK/plain.started"
      tmux -S "$WORK/plain.sock" new-session -d -s coord "$ARB_STANDIN_TICK"
      tmux -S "$WORK/plain.sock" display-message -p -t coord '#{pid}' > "$WORK/plain.pid"
    fi

    echo "$$" >> "$WORK/starts"
    : > "$WORK/ready"

    while :; do
      for req in "$WORK"/req/*.sh; do
        [ -e "$req" ] || continue
        id=`basename "$req" .sh`
        mv "$req" "$WORK/done/$id.sh" || continue
        sh "$WORK/done/$id.sh" > "$WORK/res/$id.out" 2>&1
        echo $? > "$WORK/res/$id.done"
      done
      sleep 0.05
    done
    """
  end

  defp show(unit, property) do
    {out, _status} = systemctl(["--user", "show", "-p", property, "--value", unit])
    String.trim(out)
  end

  defp systemctl(args), do: systemctl_family("systemctl", args)

  # Direct, exact-argument spawns of pure tools — `systemctl`, `systemd-run`,
  # `journalctl` and `tmux` never read ROOTDIR/BINDIR, and no BEAM starts
  # underneath them (the payload is a `while` loop).
  defp systemctl_family(command, args)
       when command in ~w(systemctl systemd-run journalctl tmux) do
    System.cmd(command, args, stderr_to_stdout: true)
  catch
    :error, _ -> {"", 127}
  end

  defp require_systemd_user! do
    case SystemdUser.status() do
      :ok -> :ok
      {:unavailable, reason} -> raise "no systemd user instance: #{reason}"
    end
  end

  # The unit's scratch dir lives in the runtime tmpfs, beside where a real
  # session's socket would be: short paths (the 108-byte AF_UNIX limit is real)
  # and wiped on logout.
  defp runtime_root, do: System.get_env("XDG_RUNTIME_DIR") || System.tmp_dir!()

  # Poll rather than sleep blind: systemd round-trips are milliseconds, but a
  # loaded host can take a while.
  defp await(fun, attempts \\ 200) do
    Enum.reduce_while(1..attempts, false, fn _, _ ->
      if fun.() do
        {:halt, true}
      else
        Process.sleep(50)
        {:cont, false}
      end
    end)
  end
end
