defmodule Arbiter.Sessions.NoPtyHandleTest do
  @moduledoc """
  Acceptance criterion 3 (bd-bpt0ag): **no Elixir process holds the PTY.**

  This is the property the whole design rests on (RFC §4.1/§4.3/§4.4). A
  BEAM-owned PTY master — `Port.open`, `:erlexec`, a NIF — closes when the BEAM
  exits, the slave gets `SIGHUP`, and the session dies: a coordinator that
  restarts arbiter would kill itself mid-restart. Restart survival is supposed
  to be true *by construction* here, because there is no supervision link to
  sever at all.

  "By construction" is only true as long as nobody adds a port later, so it is
  asserted rather than trusted: the session path may spawn **only** through the
  synchronous, injectable command runner, which returns before it hands control
  back.

  This is the grep AC 3 asks for, expressed as a test so it runs in CI.
  """
  use ExUnit.Case, async: true

  @repo_root Path.expand("../../../../..", __DIR__)

  # Every source file in the session lifecycle path.
  @session_path [
    "apps/arbiter/lib/arbiter/sessions.ex",
    "apps/arbiter/lib/arbiter/sessions/**/*.ex"
  ]

  # Primitives that hand the BEAM a long-lived handle on a child process.
  @pty_owning_primitives [
    "Port.open",
    ":erlang.open_port",
    "open_port(",
    ":erlexec",
    "spawn_executable",
    "ExPTY",
    "MuonTrap"
  ]

  defp session_sources do
    @session_path
    |> Enum.flat_map(&Path.wildcard(Path.join(@repo_root, &1)))
    |> Enum.uniq()
    |> Enum.map(fn abs ->
      {Path.relative_to(abs, @repo_root), File.read!(abs)}
    end)
  end

  # Code only: whole-line `#` comments and heredoc bodies (`@moduledoc`,
  # `@doc`) are prose. The session path's own docs discuss `Port.open` at
  # length — explaining why it is *not* used is the opposite of using it.
  defp code_lines(source) do
    source
    |> String.split("\n")
    |> Enum.with_index(1)
    |> Enum.reject(fn {line, _n} -> String.starts_with?(String.trim_leading(line), "#") end)
    |> Enum.reduce({[], false}, fn {line, n}, {kept, in_heredoc?} ->
      delimiters = length(String.split(line, ~s("""))) - 1
      now_in? = if rem(delimiters, 2) == 1, do: not in_heredoc?, else: in_heredoc?
      keep? = not in_heredoc? and delimiters == 0

      {if(keep?, do: [{line, n} | kept], else: kept), now_in?}
    end)
    |> elem(0)
    |> Enum.reverse()
  end

  test "the session path exists and is being scanned" do
    files = Enum.map(session_sources(), &elem(&1, 0))

    assert "apps/arbiter/lib/arbiter/sessions.ex" in files
    assert "apps/arbiter/lib/arbiter/sessions/runner/host.ex" in files
    assert "apps/arbiter/lib/arbiter/sessions/adoption.ex" in files
  end

  test "nothing in the session path opens a port on tmux or the agent" do
    offenders =
      for {rel, source} <- session_sources(),
          {line, n} <- code_lines(source),
          primitive <- @pty_owning_primitives,
          String.contains?(line, primitive),
          do: "#{rel}:#{n}: #{primitive}"

    assert offenders == [],
           """
           The session path must hold NO long-lived handle on the PTY (RFC
           §4.1/§4.4, AC 3). A BEAM-owned port dies with the BEAM, takes the
           tmux server's stdio with it, and defeats restart survival — which is
           the entire reason sessions live in a sibling systemd scope.

           Shell out through `Arbiter.Sessions.Runner` instead: it runs the
           command, collects its output, and returns.

           #{Enum.join(offenders, "\n")}
           """
  end

  test "the only spawn in the session path is the synchronous runner" do
    spawns =
      for {rel, source} <- session_sources(),
          {line, n} <- code_lines(source),
          String.contains?(line, "System.cmd(") or String.contains?(line, "System.shell(") or
            String.contains?(line, "ReleaseEnv.cmd(") or String.contains?(line, ":os.cmd("),
          do: {rel, n, String.trim(line)}

    # One site, in the runner, and it is the release-env-scrubbed helper
    # (bd-2oelme) rather than a raw `System.cmd/3`.
    assert Enum.map(spawns, &elem(&1, 0)) |> Enum.uniq() ==
             ["apps/arbiter/lib/arbiter/sessions/runner/host.ex"],
           "session-path spawn sites outside the runner: #{inspect(spawns)}"

    assert Enum.all?(spawns, fn {_rel, _n, line} -> String.contains?(line, "ReleaseEnv.cmd(") end),
           "every session spawn must go through ReleaseEnv (AC 6): #{inspect(spawns)}"
  end

  test "the runner is documented as synchronous and returns the exit status" do
    assert {:ok, source} =
             File.read(Path.join(@repo_root, "apps/arbiter/lib/arbiter/sessions/runner.ex"))

    # The behaviour's contract is a returned {output, status} tuple — i.e. the
    # call has already finished when it returns, so nothing is retained.
    assert source =~ "@callback run("
    assert source =~ "non_neg_integer()"
  end
end
