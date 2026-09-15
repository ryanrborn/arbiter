defmodule Arbiter.Test.SystemdUser do
  @moduledoc """
  Is there a systemd **user** instance on this host, and if not, why not
  (bd-b95w36).

  The restart-survival test (`Arbiter.Integration.SessionRestartSurvivalTest`)
  cannot be faked: it needs a real user manager to create a real transient
  unit and restart it. GitHub Actions runners generally have no user manager
  at all — `systemctl --user` fails with "Failed to connect to bus" — so the
  test has to be skippable *and* the skip has to be loud. A restart-survival
  test that quietly does not run is worse than no test, because the suite
  still reports green and the one property everything else in
  `docs/browser-hosted-coordinator-sessions.md` assumes goes unchecked.

  So this module answers the question once, with a **reason string**, and both
  the skip and the banner are built from that same answer:

    * `test/test_helper.exs` prints `banner/0` whenever the tag is excluded, so
      the reason is in CI output rather than buried in ExUnit's
      "Excluding tags:" line.
    * The test module tags itself `skip: reason` when `status/0` is
      `{:unavailable, _}`, so an explicit `--include systemd_user` on an
      unsuitable host reports a *skipped* test with the reason attached rather
      than a confusing assertion failure ten lines into a `setup`.

  The probe is deliberately cheap (three `systemctl` / `find_executable`
  calls) and is memoised per process by the callers that care.
  """

  @tag :systemd_user

  @required_tools ~w(systemd-run systemctl tmux)

  @doc "The tag that gates every test needing a systemd user instance."
  @spec tag() :: atom()
  def tag, do: @tag

  @doc """
  `:ok`, or `{:unavailable, reason}` with an operator-readable reason.

  Checks, in order: the three tools the test shells out to, `XDG_RUNTIME_DIR`
  (systemd user sessions always set it, and the tmux socket lives under it),
  and finally a live round-trip to the user manager's bus.
  """
  @spec status() :: :ok | {:unavailable, String.t()}
  def status do
    missing = Enum.reject(@required_tools, &System.find_executable/1)

    cond do
      missing != [] ->
        {:unavailable, "not installed: #{Enum.join(missing, ", ")}"}

      is_nil(System.get_env("XDG_RUNTIME_DIR")) ->
        {:unavailable, "XDG_RUNTIME_DIR is unset (no systemd user session)"}

      true ->
        user_manager_status()
    end
  end

  @doc "Whether `status/0` says the host can run these tests."
  @spec available?() :: boolean()
  def available?, do: status() == :ok

  @doc """
  The loud CI-visible explanation of what a green suite did **not** cover.

  `reason` is the string from `status/0`, or `nil` when the tag was excluded
  by policy on a host that could in fact have run it.
  """
  @spec banner(String.t() | nil) :: String.t()
  def banner(reason) do
    why =
      case reason do
        nil -> "opt-in tag, not included in this run"
        reason -> reason
      end

    """

    ============================================================================
    NOT RUN: restart survival (bd-b95w36, tag :#{@tag}) — #{why}

    `mix test` passing does NOT mean a coordinator session survives
    `systemctl --user restart arbiter`. That property is proven only by
    apps/arbiter/test/integration/session_restart_survival_test.exs, which
    needs a systemd user instance and is excluded from the default suite.

    Run it on a host that has one (the arbiter host does):

        scripts/session-restart-survival.sh

    ============================================================================
    """
  end

  # `is-system-running` returns a non-zero status for perfectly usable managers
  # (`degraded`, `starting`), so the status code alone is not the signal — the
  # signal is whether we reached the bus at all. When we did not, systemctl
  # says so on stderr, and that sentence is the most useful reason we can give
  # an operator staring at CI output.
  defp user_manager_status do
    {out, _status} =
      System.cmd("systemctl", ["--user", "is-system-running"], stderr_to_stdout: true)

    if String.contains?(out, "Failed to connect") or String.contains?(out, "Failed to get") do
      {:unavailable, "systemctl --user: #{first_line(out)}"}
    else
      :ok
    end
  catch
    :error, reason -> {:unavailable, "systemctl --user could not be run: #{inspect(reason)}"}
  end

  defp first_line(out) do
    out |> String.trim() |> String.split("\n") |> List.first() |> to_string()
  end
end
