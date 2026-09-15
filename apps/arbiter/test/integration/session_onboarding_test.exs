defmodule Arbiter.Integration.SessionOnboardingTest do
  @moduledoc """
  Live integration check for bd-aprlbb acceptance criterion 2: a **freshly
  provisioned** interactive `claude` reaches a working prompt without any
  wizard.

  This is the one claim in phase 3 that a green unit suite cannot make.
  `Arbiter.Agents.Claude.ConfigDir.InteractiveTest` proves we write the three
  keys RFC §9.2 names; it cannot prove those are the keys *this host's Claude
  Code build actually reads*. §8.3's spike measured that on v2.1.270 — run 2
  (fresh config dir) sat on the login wizard, run 3 (`hasCompletedOnboarding`
  seeded) reached a prompt — and this test is that measurement, re-runnable.

  ## Not part of the default suite

  Tagged `:live_claude` and excluded in `test/test_helper.exs`. Run it
  deliberately:

      mix test --include live_claude test/integration/session_onboarding_test.exs

  When `claude` / `tmux` / `systemd-run` are missing, when there is no systemd
  user manager, or when no credential is available, it **skips** — the test
  passes, prints a loud note saying which environment gap it hit, and launches
  nothing. An environment gap is not a failing assertion: a coordinator running
  AC 7 on a host without the tools should get "this host cannot run the check",
  not a red suite.

  ## Auth mode, and why mode A is preferred here

  Mode A (a workspace `CLAUDE_CODE_OAUTH_TOKEN`) is used when one is available,
  because it is exactly the configuration §8.3 run 3 measured *and* because it
  touches no credential of the operator's. Mode B is the production default
  (§8.2) but seeds a **copy** of the operator's own `.credentials.json`, and
  both copies then refresh the same grant — RFC §12 flags that, and the fallout
  is the operator being logged out. So mode B here is the fallback, and the
  message says so.

  Set `ARB_LIVE_CLAUDE_OAUTH_TOKEN` (or export `CLAUDE_CODE_OAUTH_TOKEN`) to
  take the mode-A path.

  ## Teardown discipline

  Every teardown addresses the **exact** unit name and **exact** socket path
  this test created, both derived from a fresh session id, and runs
  unconditionally via `on_exit`. This repo has a documented incident class
  around pattern-matching kills reaching the live coordinator; there is no
  `pkill` here and there must never be one.
  """
  use Arbiter.DataCase, async: false

  @moduletag :live_claude
  # A real CLI doing a real cold start.
  @moduletag timeout: 180_000

  alias Arbiter.Sessions
  alias Arbiter.Sessions.Layout
  alias Arbiter.Test.SessionEnv

  # What the three §9.2 gates look like on screen. Any of these means a gate we
  # were supposed to have pre-answered is still blocking.
  @wizard_markers [
    "Select login method",
    "Choose the text style",
    "Do you trust the files in this folder",
    "Let's get started",
    "console.anthropic.com/oauth"
  ]

  # What a working prompt looks like. Any one is enough — the banner text moves
  # between releases, the prompt affordances do not.
  @ready_markers [
    "? for shortcuts",
    "Welcome to Claude Code",
    "cwd:",
    "Try \"",
    "/help"
  ]

  setup do
    case skip_reason() do
      nil -> setup_host()
      reason -> {:ok, skip: reason}
    end
  end

  # Why this host cannot run the check, or `nil` if it can. Returning a reason
  # rather than raising is deliberate: a raise in `setup` is a test *failure*,
  # and "claude isn't installed here" is not a failure of the code under test.
  defp skip_reason do
    missing = Enum.reject(~w(claude tmux systemd-run systemctl), &System.find_executable/1)

    cond do
      missing != [] ->
        "not installed: #{Enum.join(missing, ", ")}"

      is_nil(System.get_env("XDG_RUNTIME_DIR")) or not user_manager_running?() ->
        "no systemd user manager / XDG_RUNTIME_DIR — run this on the dogfood host"

      true ->
        credential_skip_reason()
    end
  end

  defp setup_host do
    runtime_root = System.get_env("XDG_RUNTIME_DIR")
    unique = System.unique_integer([:positive])
    base = Path.join(System.tmp_dir!(), "arb-live-onboarding-#{unique}")
    runtime = Path.join(runtime_root, "arbiter-live-onboarding-#{unique}")

    SessionEnv.override(
      sessions_root: Path.join(base, "sessions"),
      sessions_runtime_dir: runtime,
      # The real CLI, with no `--print`: the interactive path is the whole point.
      sessions_agent_command: "claude",
      # Do NOT let the phase-1 shell override stand in for the agent here.
      sessions_launch_command: nil
    )

    on_exit(fn ->
      File.rm_rf(base)
      File.rm_rf(runtime)
    end)

    {:ok, auth_opts: auth_opts()}
  end

  test "a provisioned session reaches a working prompt with no onboarding wizard", ctx do
    if ctx[:skip] do
      skipped(ctx[:skip])
    else
      run_live_check(ctx[:auth_opts])
    end
  end

  defp skipped(reason) do
    IO.puts("""

      SKIPPED #{inspect(__MODULE__)}: #{reason}

      This is an environment gap, not a failure. The live AC-7 check needs the
      real `claude` CLI, a systemd user manager, and a credential.
    """)

    :ok
  end

  defp run_live_check(auth_opts) do
    {:ok, session} = Sessions.launch(auth_opts)

    on_exit(fn ->
      _ = cmd("tmux", ["-S", session.tmux_socket, "kill-server"])
      _ = cmd("systemctl", ["--user", "stop", session.scope_unit])
    end)

    assert session.status == :running

    # The scaffold really is what the CLI was pointed at.
    assert File.regular?(Path.join(session.config_dir, ".claude.json"))
    assert File.regular?(Layout.launch_script_path(session.id))

    screen =
      eventually(fn ->
        pane = capture_pane(session)
        if ready?(pane) or wizard?(pane), do: pane, else: nil
      end) || capture_pane(session)

    refute wizard?(screen),
           "a §9.2 onboarding gate is still blocking a provisioned session:\n\n#{screen}"

    assert ready?(screen),
           "the session never reached a prompt within the timeout:\n\n#{screen}"

    # And the revocation half of §9.3, end to end on a live session.
    {:ok, killed} = Sessions.kill(session.id)
    assert killed.mcp_token_revoked_at

    token = mcp_token(session)
    assert {:error, :revoked} = Arbiter.MCP.Scope.from_token(token)
  end

  # ---- helpers -------------------------------------------------------------

  defp oauth_token do
    case System.get_env("ARB_LIVE_CLAUDE_OAUTH_TOKEN") ||
           System.get_env("CLAUDE_CODE_OAUTH_TOKEN") do
      token when is_binary(token) and token != "" -> token
      _ -> nil
    end
  end

  defp credentials_source do
    source = Arbiter.Agents.Claude.ConfigDir.source_dir()
    if source && File.exists?(Path.join(source, ".credentials.json")), do: source
  end

  defp credential_skip_reason do
    if oauth_token() || credentials_source() do
      nil
    else
      "no credential available: set ARB_LIVE_CLAUDE_OAUTH_TOKEN for the mode-A path " <>
        "(preferred — it touches nothing of the operator's), or log in so " <>
        "#{inspect(Arbiter.Agents.Claude.ConfigDir.source_dir())}/.credentials.json " <>
        "exists for the mode-B fallback."
    end
  end

  defp auth_opts do
    case oauth_token() do
      token when is_binary(token) ->
        [auth_mode: :oauth_token, oauth_token: token]

      nil ->
        IO.puts(
          "\n  note: running the mode-B fallback — this seeds a COPY of the operator's " <>
            "credentials into the session config dir, and both copies then refresh the " <>
            "same grant (RFC §12). Prefer ARB_LIVE_CLAUDE_OAUTH_TOKEN.\n"
        )

        [auth_mode: :seeded_credentials, credentials_source: credentials_source()]
    end
  end

  defp mcp_token(session) do
    config = session.id |> Layout.mcp_config_path() |> File.read!() |> Jason.decode!()

    "Bearer " <> token =
      config["mcpServers"][Arbiter.MCP.server_name()]["headers"]["Authorization"]

    token
  end

  defp capture_pane(session) do
    case cmd("tmux", ["-S", session.tmux_socket, "capture-pane", "-p", "-t", "coord"]) do
      {out, 0} -> out
      _ -> ""
    end
  end

  defp wizard?(screen), do: Enum.any?(@wizard_markers, &String.contains?(screen, &1))
  defp ready?(screen), do: Enum.any?(@ready_markers, &String.contains?(screen, &1))

  # Poll rather than sleep-and-hope: a cold `claude` start is seconds, and the
  # failure we care about (a wizard) is stable once rendered.
  defp eventually(fun, attempts \\ 60) do
    Enum.reduce_while(1..attempts, nil, fn _, _ ->
      case fun.() do
        nil ->
          Process.sleep(500)
          {:cont, nil}

        false ->
          Process.sleep(500)
          {:cont, nil}

        value ->
          {:halt, value}
      end
    end)
  end

  defp user_manager_running? do
    match?({_, 0}, cmd("systemctl", ["--user", "is-system-running", "--quiet"])) or
      match?({_, _}, cmd("systemctl", ["--user", "show", "--property=Version"]))
  end

  defp cmd(command, args) do
    Arbiter.Worker.ReleaseEnv.cmd(command, args, stderr_to_stdout: true)
  rescue
    _ -> {"", 127}
  end
end
