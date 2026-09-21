defmodule Arbiter.TestSandbox do
  @moduledoc """
  Provision a throwaway repo sandbox for tests that drive real dispatch.

  Written for bd-b6noq9 / #1930. Four ephemeral tasks (`fp-7zn1p7`,
  `fp-6u0wu1`, `cr-ag13cz`, `fp-ry8klj`) were lost to one fixture shape:

      tmp = Path.join(System.tmp_dir!(), "rev-provider-\#{unique}")
      ...                       # repo/, origin.git, worktrees/, bin/
      on_exit(fn -> File.rm_rf!(tmp) end)

  Three separate hazards, each of which this module removes:

    1. **Under `/tmp`.** On the dogfood host that is a `tmpfs` swept daily by
       `systemd-tmpfiles`. Sandboxes go under
       `Arbiter.Config.Paths.scratch_root/0` instead — disk-backed, and no
       janitor's business.

    2. **Bare origin co-located with the worktree.** One `rm_rf` took the
       worktree, the `origin.git` and therefore the only copy of the branch,
       which is what made the loss unrecoverable rather than merely
       disruptive. `provision!/2` puts the origin under a *separate* root, so
       losing the disposable side still leaves something to re-clone from.

    3. **Teardown racing a live run.** `on_exit` fired while agent sessions
       spawned into the sandbox were still working. `teardown/2` stops the
       processes that own the sandbox and waits for them to be gone before it
       deletes anything — and if an owner will not stop, it leaves the
       sandbox on disk rather than destroying a live run's only checkout.
       "Stops" means through `terminate/2` (`Arbiter.ProcessTeardown.stop/2`),
       because that callback is where a worker reaps its agent's OS process:
       an owner that died without running it leaves the agent alive in a
       directory about to be deleted, which is the same race by another route.

  A fourth hazard was what turned a fixture bug into a live incident: the
  original fixture stubbed `agy` but not `claude`, so a dispatch that resolved
  to Claude executed the operator's **real** CLI inside the sandbox — which is
  why prose written by a live agent, escalating over `arb` to the live
  coordinator, showed up for tasks that exist in no database. `provision!/2`
  stubs every binary in `agent_binaries/0` and puts that directory first on
  `PATH`, so no spawn can reach a real agent CLI.
  """

  import ExUnit.Callbacks, only: [on_exit: 1]

  require Logger

  # Every executable an `Arbiter.Agents` adapter can spawn. `gemini` and `agy`
  # are both here because `Arbiter.Agents.Gemini.resolve_executable/0` accepts
  # either. Kept as a literal rather than derived from the adapter modules on
  # purpose: this list existing and being complete is the safety property, so
  # it should fail loudly in review when an adapter is added, not silently
  # resolve to an empty list.
  @agent_binaries ~w(claude agy gemini codex)

  @default_owner_timeout 2_000

  @type t :: %{
          root: String.t(),
          repo: String.t(),
          origin: String.t(),
          worktree_root: String.t(),
          bin: String.t(),
          log: String.t(),
          owners: pid()
        }

  @doc "Executables a dispatch could spawn, all of which are stubbed."
  @spec agent_binaries() :: [String.t()]
  def agent_binaries, do: @agent_binaries

  @doc """
  Provision a sandbox tagged `tag`.

  Returns a map of paths plus an `:owners` agent holding the pids whose
  lifetime the sandbox belongs to (see `own!/2`). Registers an `on_exit`
  teardown, so callers that finish cleanly need not call `teardown/2`
  themselves.

  ## Options

    * `:stub` — body (a `sh` script, without the shebang) written for every
      agent binary. Defaults to a stub that logs its argv to `log` and prints
      `arb done`. Pass a map to vary the body per binary; any binary the map
      omits still gets the default, so no binary is ever left unstubbed.
  """
  @spec provision!(String.t(), keyword()) :: t()
  def provision!(tag, opts \\ []) do
    unique = "#{tag}-#{System.unique_integer([:positive])}"
    scratch = Arbiter.Config.Paths.scratch_root()

    # The disposable half and the durable half are siblings, not parent and
    # child: `rm_rf(root)` must not be able to reach the origin.
    root = Path.join([scratch, "sandboxes", unique])
    origin = Path.join([scratch, "origins", unique <> ".git"])

    repo = Path.join(root, "repo")
    worktree_root = Path.join(root, "worktrees")
    bin = Path.join(root, "bin")
    log = Path.join(root, "cli-calls.log")

    Enum.each([repo, worktree_root, bin, Path.dirname(origin)], &File.mkdir_p!/1)

    init_repo!(repo, origin)
    write_stubs!(bin, log, Keyword.get(opts, :stub, %{}))
    prepend_path!(bin)

    # Unlinked: the registry of owners has to outlive the test process so the
    # `on_exit` teardown below can still see who owns the sandbox.
    {:ok, owners} = Agent.start(fn -> [] end)

    sandbox = %{
      root: root,
      repo: repo,
      origin: origin,
      worktree_root: worktree_root,
      bin: bin,
      log: log,
      owners: owners
    }

    on_exit(fn -> teardown(sandbox) end)

    sandbox
  end

  @doc """
  Declare that `pid` owns `sandbox` — a worker, a driver, anything holding a
  checkout inside it. `teardown/2` will not delete the sandbox until every
  owner is gone.
  """
  @spec own!(t(), pid()) :: :ok
  def own!(%{owners: owners}, pid) when is_pid(pid) do
    Agent.update(owners, &[pid | &1])
  end

  @doc """
  Adopt every worker the registry currently reports as an owner of `sandbox`.

  The escape hatch for tests that dispatch workers without ever holding their
  pids. Register it with `on_exit/1` **after** `provision!/2` so it runs
  *before* the teardown that call registered (`on_exit` is LIFO): the live
  workers are adopted, then stopped, then the sandbox is deleted.
  """
  @spec own_live_workers!(t()) :: :ok
  def own_live_workers!(sandbox) do
    Enum.each(Arbiter.Worker.Registry.all(), fn {_key, pid} -> own!(sandbox, pid) end)
  end

  @doc """
  Create `branch` in the sandbox repo with one commit and push it to the
  origin, the way a worker's first commit would.
  """
  @spec seed_branch!(t(), String.t()) :: :ok
  def seed_branch!(%{repo: repo}, branch) do
    {_, 0} = git!(repo, ["checkout", "-q", "-b", branch])
    File.write!(Path.join(repo, "feature.txt"), "work\n")
    {_, 0} = git!(repo, ["add", "feature.txt"])
    {_, 0} = git!(repo, ["commit", "-q", "-m", "feature work"])
    {_, 0} = git!(repo, ["push", "-q", "origin", branch])
    {_, 0} = git!(repo, ["checkout", "-q", "main"])
    :ok
  end

  @doc "Lines the stubbed CLIs logged, in call order."
  @spec calls(t()) :: [String.t()]
  def calls(%{log: log}) do
    case File.read(log) do
      {:ok, body} -> String.split(body, "\n", trim: true)
      _ -> []
    end
  end

  @doc """
  Stop everything that owns `sandbox`, then delete it.

  Returns `:ok` once the sandbox is gone, or `{:error, {:owners_alive, pids}}`
  when an owner refused to stop within `timeout` — in which case **nothing is
  deleted**. That refusal is the whole point: a sandbox may hold the only copy
  of a branch, and a live run losing it mid-session is #1930.

  Idempotent, so the `on_exit` registered by `provision!/2` is harmless after
  an explicit call.
  """
  @spec teardown(t(), timeout()) :: :ok | {:error, {:owners_alive, [pid()]}}
  def teardown(sandbox, timeout \\ @default_owner_timeout)

  def teardown(%{root: root, origin: origin, owners: owners} = _sandbox, timeout) do
    case stop_owners(owners, timeout) do
      [] ->
        File.rm_rf(root)
        File.rm_rf(origin)
        if Process.alive?(owners), do: Agent.stop(owners)
        :ok

      alive ->
        Logger.error(
          "TestSandbox: refusing to delete #{root} — #{length(alive)} owner(s) still " <>
            "alive after #{timeout}ms (#{inspect(alive)}). Deleting a sandbox out from " <>
            "under a live run is bd-b6noq9."
        )

        {:error, {:owners_alive, alive}}
    end
  end

  # Stop each owner and wait for it to be gone; returns the ones still alive.
  defp stop_owners(owners, timeout) do
    pids =
      if Process.alive?(owners) do
        Agent.get(owners, & &1)
      else
        []
      end

    pids
    |> Enum.filter(&Process.alive?/1)
    |> Enum.map(fn pid ->
      ref = Process.monitor(pid)
      # `ProcessTeardown.stop/2`, never a bare `Process.exit(pid, :shutdown)`:
      # it quiesces first, so a worker parked in a DB callback is not killed
      # mid-query, and it stops through the `sys` terminate path, so the
      # owner's `terminate/2` actually runs. That matters here more than
      # anywhere: `Arbiter.Worker` does not trap exits, and its `terminate/2`
      # is the only thing that SIGKILLs the agent's OS process and its
      # descendants (bd-bmmj4w). An exit signal skips the callback, so the
      # owner would go down while its agent kept running — cwd inside the root
      # this function is about to delete. That is hazard 3 again, and the
      # shape of #1930 itself.
      Arbiter.ProcessTeardown.stop(pid, timeout)
      {pid, ref}
    end)
    |> Enum.reduce([], fn {pid, ref}, alive ->
      receive do
        {:DOWN, ^ref, :process, ^pid, _} -> alive
      after
        timeout ->
          Process.demonitor(ref, [:flush])
          [pid | alive]
      end
    end)
    |> Enum.reverse()
  end

  defp init_repo!(repo, origin) do
    {_, 0} = System.cmd("git", ["init", "-q", "-b", "main", repo])
    {_, 0} = git!(repo, ["config", "user.email", "repo@example.com"])
    {_, 0} = git!(repo, ["config", "user.name", "Repo"])
    {_, 0} = git!(repo, ["config", "commit.gpgsign", "false"])
    File.write!(Path.join(repo, "README.md"), "seed\n")
    {_, 0} = git!(repo, ["add", "README.md"])
    {_, 0} = git!(repo, ["commit", "-q", "-m", "seed"])
    {_, 0} = System.cmd("git", ["clone", "--bare", "-q", repo, origin])
    {_, 0} = git!(repo, ["remote", "add", "origin", origin])
    {_, 0} = git!(repo, ["fetch", "-q", "origin"])
    :ok
  end

  defp git!(repo, args), do: System.cmd("git", ["-C", repo | args], stderr_to_stdout: true)

  defp write_stubs!(bin, log, override) when is_binary(override),
    do: write_stubs!(bin, log, Map.new(@agent_binaries, &{&1, override}))

  defp write_stubs!(bin, log, %{} = override) do
    Enum.each(@agent_binaries, fn name ->
      body = Map.get(override, name) || default_stub(name, log)
      path = Path.join(bin, name)
      File.write!(path, "#!/bin/sh\n" <> body)
      File.chmod!(path, 0o755)
    end)
  end

  defp default_stub(name, log) do
    """
    echo "#{name} $@" >> #{log}
    echo "arb done"
    exit 0
    """
  end

  # VM-global, so sandboxes are only safe in `async: false` tests — the same
  # constraint the fixture this replaces already had.
  defp prepend_path!(bin) do
    old = System.get_env("PATH") || ""
    System.put_env("PATH", bin <> ":" <> old)
    on_exit(fn -> System.put_env("PATH", old) end)
    :ok
  end
end
