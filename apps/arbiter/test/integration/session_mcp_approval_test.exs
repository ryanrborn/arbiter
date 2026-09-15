defmodule Arbiter.Integration.SessionMcpApprovalTest do
  @moduledoc """
  Live check for bd-5xlkkj acceptance criterion 1: the `.mcp.json` server a
  session is provisioned with is **already approved** as far as the installed
  Claude Code is concerned, so first launch does not stop on "New MCP server
  found in this project: arbiter".

  `Arbiter.Agents.Claude.ConfigDir.InteractiveTest` proves we write
  `enabledMcpjsonServers`. It cannot prove that is a key *this host's CLI
  reads* — which is exactly the assumption phase 3 got wrong about the
  onboarding gates and phase 5's live check caught. So this asks the CLI.

  ## Why this one is cheap

  `Arbiter.Integration.SessionOnboardingTest` needs tmux, a systemd user
  manager and a credential, because it drives a real TUI. This does not:
  `claude mcp list` is non-interactive, prints each `.mcp.json` server's
  approval state, and needs no login. The only requirement is `claude` on
  PATH, so this runs anywhere the CLI is installed.

  It is still tagged `:live_claude` and excluded from the default suite — it
  spawns the real binary, and its answer is about *this host*, not about the
  code:

      mix test --include live_claude test/integration/session_mcp_approval_test.exs

  ## The control matters

  Asserting only "not pending" would pass just as happily if the CLI had
  stopped reporting approval state at all. So the test first provisions a
  config dir with the pre-approval **suppressed** (`mcp_servers: []`) and
  requires the CLI to call that one pending. A run where neither is pending is
  a run that proves nothing, and fails.
  """
  use ExUnit.Case, async: false

  @moduletag :live_claude
  @moduletag timeout: 180_000

  alias Arbiter.Agents.Claude.ConfigDir.Interactive

  # `claude mcp list` renders this for a `.mcp.json` server that has not been
  # approved (the CLI's own `He` constant, minus the leading glyph).
  @pending "Pending approval"

  @server "arbiter"

  setup do
    if System.find_executable("claude") do
      tmp =
        Path.join(System.tmp_dir!(), "bd-5xlkkj-mcp-#{System.unique_integer([:positive])}")

      on_exit(fn -> File.rm_rf(tmp) end)
      {:ok, tmp: tmp}
    else
      {:ok, skip: "the `claude` CLI is not installed on this host"}
    end
  end

  test "a provisioned session's MCP server needs no approval click", ctx do
    if reason = ctx[:skip] do
      IO.puts("\n  SKIPPED #{inspect(__MODULE__)}: #{reason}\n")
      :ok
    else
      # Control: the same scaffold with the pre-approval suppressed. If this is
      # not pending, the probe is not measuring anything.
      assert mcp_list(ctx[:tmp], "control", mcp_servers: []) =~ @pending

      approved = mcp_list(ctx[:tmp], "approved", mcp_servers: [@server])

      refute approved =~ @pending,
             "the provisioned pre-approval did not take on this CLI build:\n\n#{approved}"
    end
  end

  # Build a session-shaped scaffold — the real generator, not a hand-written
  # settings file — and ask the CLI what it makes of it.
  defp mcp_list(tmp, name, opts) do
    config = Path.join([tmp, name, "config"])
    cwd = Path.join([tmp, name, "workspace"])
    File.mkdir_p!(cwd)

    # A loopback URL nothing is listening on: the health probe fails, which is
    # fine — "failed to connect" is what an *approved* server reports, and the
    # approval state is decided before any connection is attempted.
    File.write!(
      Path.join(cwd, ".mcp.json"),
      Jason.encode!(%{
        "mcpServers" => %{
          @server => %{"type" => "http", "url" => "http://127.0.0.1:1/mcp"}
        }
      })
    )

    # `source_dir: nil` so no credential of the operator's is ever copied here.
    assert :ok = Interactive.ensure(config, [cwd: cwd, source_dir: nil] ++ opts)

    {out, _status} =
      System.cmd("claude", ["mcp", "list"],
        cd: cwd,
        env: [{"CLAUDE_CONFIG_DIR", config}],
        stderr_to_stdout: true
      )

    out
  end
end
