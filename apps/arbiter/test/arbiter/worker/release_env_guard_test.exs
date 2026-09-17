defmodule Arbiter.Worker.ReleaseEnvGuardTest do
  @moduledoc """
  bd-2oelme: a missed subprocess spawn only fails in release mode, which dev CI
  never exercises — so the inventory is asserted in a test instead.

  Four rules, all evaluated against the source of `apps/*/lib`:

    1. **Every spawned command is a literal drawn from the pure-tool
       allowlist.** `System.cmd/3`, `System.shell/1` and `:os.cmd/1` may only
       run a command that is spelled out as a literal string *and* appears in
       `@pure_tool_commands` (`git`, `gh`, `kill`, `diff`, …). Anything else —
       a BEAM/agent CLI (`mix`, `elixir`, `claude`, `arb`, …), a shell, or a
       command held in a variable — must go through
       `Arbiter.Worker.ReleaseEnv.cmd/3`, which is the only place an arbitrary
       command may be spawned. This is deliberately per-*occurrence*, not
       per-file, so a new bypass added to an already-classified file is caught
       too.
    2. **`Port.open/2` is allowlisted per occurrence.** A file that opens a
       port must be declared here *with its exact number of ports*, and must
       call `ReleaseEnv.port_env/1`, so a second port added to an
       already-listed file has to be classified too.
    3. **Every spawn site is classified.** A file containing any spawn
       primitive must appear in `@inventory`, so a new one can't land
       unclassified.
    4. **`:scrubbed` files really do reference `ReleaseEnv`.**

  When you add a spawn site, add its file to `@inventory` with the right
  classification — that is the whole maintenance cost.
  """
  use ExUnit.Case, async: true

  @repo_root Path.expand("../../../../..", __DIR__)

  @release_env_source "apps/arbiter_release_env/lib/arbiter/worker/release_env.ex"

  # Commands that boot a BEAM or an agent CLI, plus the shells that may invoke
  # one. Spawning any of these outside `ReleaseEnv.cmd/3` is a bug. `arb` is on
  # the list because it is an escript — i.e. a BEAM start (see the ReleaseEnv
  # moduledoc). This list exists to give rule 1 a *specific* error message; the
  # rule itself rejects anything not in @pure_tool_commands, so a BEAM command
  # missing from this list is still caught.
  @beam_or_agent_commands ~w(
    mix elixir elixirc iex erl erlc escript arb
    claude agy codex gemini
    sh bash zsh /bin/sh /bin/bash env
  )

  # Commands that never read ROOTDIR/BINDIR/RELEASE_* and so may be spawned
  # directly. This is the allowlist rule 1 enforces: adding a command here is
  # the explicit act of classifying it as release-env-safe.
  @pure_tool_commands ~w(
    git gh glab
    cp diff kill pgrep lsof ss
    systemctl loginctl
    dolt kubectl
  )

  # Files that may call `Port.open/2`, and how many times. A port child
  # inherits the release env, so every one of these occurrences must merge
  # `ReleaseEnv.port_env/1` into its `{:env, …}` option. The count is declared
  # (rather than just the file) because the env for a port is often assembled
  # somewhere other than the `Port.open/2` line itself — there is no textual
  # way to tie a given occurrence to the scrub, so instead adding one forces
  # this number to change, and with it a fresh look at the new call.
  @port_open_allowlist %{
    "apps/arbiter/lib/arbiter/worker/claude_session.ex" => 1,
    "apps/arbiter/lib/arbiter/agents/preflight.ex" => 1,
    # bd-3qkbch: `arb session attach`'s full-terminal handoff to tmux. Not a
    # BEAM/agent child, but every Port.open/2 site is scrubbed regardless of
    # what it spawns (rule 2's own text).
    "apps/arbiter_cli/lib/arbiter_cli/cmd/session.ex" => 1
  }

  # Every file under `apps/*/lib` that contains a subprocess spawn primitive,
  # and why it is (or isn't) scrubbed. Mirrors the table in the bd-2oelme PR.
  #
  #   :helper   — `ReleaseEnv` itself, the one place `System.cmd/3` is allowed
  #               to run an arbitrary command.
  #   :scrubbed — routes at least one BEAM/agent spawn through `ReleaseEnv`.
  #   :pure_tool — only spawns tools that never read ROOTDIR/BINDIR
  #               (git, gh, cp, kill, pgrep, diff, dolt, …).
  @inventory %{
    @release_env_source => :helper,
    "apps/arbiter/lib/arbiter/worker/claude_session.ex" => :scrubbed,
    "apps/arbiter/lib/arbiter/agents/preflight.ex" => :scrubbed,
    "apps/arbiter/lib/arbiter/worker/worktree.ex" => :scrubbed,
    "apps/arbiter/lib/arbiter/workflows/code_review/checks.ex" => :scrubbed,
    "apps/arbiter/lib/arbiter/workflows/review_reply.ex" => :scrubbed,
    "apps/arbiter/lib/arbiter/quota/cloud_code.ex" => :scrubbed,
    # bd-bpt0ag: the single spawn point for coordinator sessions. It runs
    # `systemd-run` / `tmux` / `systemctl`, and the tmux server it starts goes
    # on to host an agent CLI and whatever that CLI runs — so the scrub has to
    # happen once here, at the scope boundary, and is inherited by every pane.
    "apps/arbiter/lib/arbiter/sessions/runner/host.ex" => :scrubbed,
    "apps/arbiter/lib/arbiter/single_instance.ex" => :pure_tool,
    "apps/arbiter/lib/arbiter/version.ex" => :pure_tool,
    "apps/arbiter/lib/arbiter/worker.ex" => :pure_tool,
    "apps/arbiter/lib/arbiter/loop/apply/repo_doc.ex" => :pure_tool,
    "apps/arbiter/lib/arbiter/mcp/agent_config.ex" => :pure_tool,
    "apps/arbiter/lib/arbiter/mergers/direct.ex" => :pure_tool,
    "apps/arbiter/lib/arbiter/mergers/gitlab.ex" => :pure_tool,
    "apps/arbiter/lib/arbiter/mergers/github/repo_resolver.ex" => :pure_tool,
    "apps/arbiter/lib/arbiter/mergers/net_diff.ex" => :pure_tool,
    "apps/arbiter/lib/arbiter/reviews/checkout.ex" => :pure_tool,
    # bd-1lszsc: git only (rev-parse / worktree add) to build a refine
    # session's read-only grounding checkout. Same classification as
    # `reviews/checkout.ex`, which does the same thing for a PR head.
    "apps/arbiter/lib/arbiter/sessions/repo_checkout.ex" => :pure_tool,
    # bd-2jkrqu: git only (rev-parse / fetch / push / merge-base), which never
    # reads ROOTDIR or BINDIR.
    "apps/arbiter/lib/arbiter/reviews/push_state.ex" => :pure_tool,
    "apps/arbiter/lib/arbiter/tasks/status_backfill.ex" => :pure_tool,
    "apps/arbiter/lib/arbiter/worker/primary_sync.ex" => :pure_tool,
    "apps/arbiter/lib/arbiter/worker/resume_context.ex" => :pure_tool,
    "apps/arbiter/lib/arbiter/worker/review_gate.ex" => :pure_tool,
    "apps/arbiter/lib/arbiter/workflows/code_review.ex" => :pure_tool,
    "apps/arbiter/lib/arbiter/workflows/code_review/consumer_trace.ex" => :pure_tool,
    "apps/arbiter/lib/arbiter/workflows/merge_queue/conflict_resolver.ex" => :pure_tool,
    "apps/arbiter/lib/mix/tasks/arbiter.import_from_dolt.ex" => :pure_tool,
    "apps/arbiter_web/lib/arbiter_web/application.ex" => :pure_tool,
    "apps/arbiter_cli/lib/arbiter_cli/version.ex" => :pure_tool,
    "apps/arbiter_cli/lib/arbiter_cli/cmd/init.ex" => :pure_tool,
    "apps/arbiter_cli/lib/arbiter_cli/cmd/start.ex" => :scrubbed,
    # bd-3qkbch: opens a Port for tmux only (§4.7's CLI fallback) — scrubbed
    # for the same blanket rule-2 reason, not because tmux is a BEAM/agent.
    "apps/arbiter_cli/lib/arbiter_cli/cmd/session.ex" => :scrubbed
  }

  # Spawn primitives that run a command of their own choosing. Rule 1 inspects
  # the command each one is given.
  @raw_spawn_primitives ["System.cmd(", "System.shell(", ":os.cmd(", "MuonTrap.cmd("]

  # `ReleaseEnv.cmd(` counts for the inventory: a site that has already been
  # routed through the helper is still a spawn site, and must stay classified.
  @spawn_primitives @raw_spawn_primitives ++ ["Port.open(", "ReleaseEnv.cmd("]

  # ---- source scanning ------------------------------------------------------

  # Every `apps/*/lib/**/*.ex` file, as {repo_relative_path, code_lines} where
  # code_lines drops whole-line comments (a moduledoc or `#` note that mentions
  # `System.cmd/3` is prose, not a spawn).
  defp source_files do
    @repo_root
    |> Path.join("apps/*/lib/**/*.ex")
    |> Path.wildcard()
    |> Enum.map(fn abs ->
      rel = Path.relative_to(abs, @repo_root)

      lines =
        abs
        |> File.read!()
        |> String.split("\n")
        |> Enum.with_index(1)
        |> Enum.reject(fn {line, _n} -> String.starts_with?(String.trim_leading(line), "#") end)

      {rel, lines}
    end)
  end

  defp spawn_files(files) do
    Enum.filter(files, fn {_rel, lines} ->
      Enum.any?(lines, fn {line, _n} ->
        Enum.any?(@spawn_primitives, &String.contains?(line, &1))
      end)
    end)
  end

  # Every raw-spawn occurrence in `lines`, as {line_no, primitive, command}
  # where `command` is `{:literal, "git"}` or `:dynamic`.
  #
  # The command is whatever follows the opening paren; `mix format` often puts
  # it on the next line for a multi-line call, so an empty tail continues onto
  # the following non-blank code line.
  defp raw_spawns(lines) do
    for {{line, n}, idx} <- Enum.with_index(lines),
        primitive <- @raw_spawn_primitives,
        tail <- tails(line, primitive) do
      tail =
        case String.trim(tail) do
          "" -> next_code_line(lines, idx + 1)
          other -> other
        end

      {n, primitive, command_token(primitive, tail)}
    end
  end

  # Every occurrence of `primitive` on one line, as the text following it — all
  # of them, so a second spawn tucked onto the same line can't hide behind the
  # first.
  defp tails(line, primitive) do
    case String.split(line, primitive) do
      [_] -> []
      [_ | rest] -> rest
    end
  end

  defp next_code_line(lines, idx) do
    lines
    |> Enum.drop(idx)
    |> Enum.map(fn {line, _n} -> String.trim(line) end)
    |> Enum.find("", &(&1 != ""))
  end

  # A command is only "known" if it is spelled out as a string (or charlist)
  # literal. Anything else is `:dynamic` and must go through the helper.
  # `System.shell/1` takes a whole script run by `sh -c`, so it is never OK.
  defp command_token("System.shell(", _tail), do: :shell
  defp command_token(_primitive, <<?", rest::binary>>), do: literal_until_quote(rest)
  defp command_token(_primitive, "~c\"" <> rest), do: literal_until_quote(rest)
  defp command_token(_primitive, _tail), do: :dynamic

  defp literal_until_quote(rest) do
    case String.split(rest, "\"", parts: 2) do
      [value, _] -> {:literal, value}
      _ -> :dynamic
    end
  end

  # ---- rules ----------------------------------------------------------------

  test "every directly spawned command is a literal pure tool" do
    offenders =
      for {rel, lines} <- source_files(),
          rel != @release_env_source,
          {n, primitive, command} <- raw_spawns(lines),
          reason = offence(command),
          do: "#{rel}:#{n}: #{primitive}… — #{reason}"

    assert offenders == [],
           """
           These sites spawn a command without the release-env scrub.

           Use `Arbiter.Worker.ReleaseEnv.cmd/3` instead of `System.cmd/3` — a
           child that inherits ROOTDIR/BINDIR/RELEASE_* from the systemd OTP
           release boots against the release's ERTS and dies with
           `cannot get bootfile` (bd-4hkzn3 / bd-2oelme). `ReleaseEnv.cmd/3` is
           the only call that may take a non-literal command.

           If the command really is a release-env-safe tool, add it to
           @pure_tool_commands — that is how a tool gets classified.

           #{Enum.join(offenders, "\n")}
           """
  end

  defp offence(:shell),
    do: "System.shell/1 runs the script through a shell, which may start a BEAM"

  defp offence(:dynamic),
    do: "command is not a literal, so it cannot be shown to be a pure tool"

  defp offence({:literal, cmd}) do
    base = cmd |> Path.basename() |> String.trim()

    cond do
      base in @pure_tool_commands -> nil
      cmd in @beam_or_agent_commands -> "#{cmd} starts a BEAM or an agent CLI"
      true -> "#{cmd} is not in @pure_tool_commands"
    end
  end

  test "Port.open/2 sites are allowlisted per occurrence and route their env through ReleaseEnv" do
    counts =
      for {rel, lines} <- source_files(),
          rel != @release_env_source,
          count = port_open_count(lines),
          count > 0,
          into: %{},
          do: {rel, count}

    mismatched =
      for rel <- Enum.sort(Map.keys(counts) ++ Map.keys(@port_open_allowlist)) |> Enum.uniq(),
          found = Map.get(counts, rel, 0),
          declared = Map.get(@port_open_allowlist, rel, 0),
          found != declared,
          do: "#{rel}: #{found} `Port.open/2` call(s), @port_open_allowlist declares #{declared}"

    assert mismatched == [],
           """
           The `Port.open/2` inventory is out of date. A port child inherits the
           release env, so every spawn must merge
           `Arbiter.Worker.ReleaseEnv.port_env/1` into its `{:env, …}` option.

           If you added a port: make it do that, then record the new count in
           @port_open_allowlist (the count is per-occurrence on purpose — a
           second port in an already-listed file has to be classified too). If
           you removed one, drop the count.

           #{Enum.join(mismatched, "\n")}
           """

    for {rel, _count} <- @port_open_allowlist do
      body = File.read!(Path.join(@repo_root, rel))

      assert body =~ "ReleaseEnv.port_env(",
             "#{rel} opens a port but no longer calls ReleaseEnv.port_env/1 — " <>
               "the release-env scrub was dropped from a spawn path."
    end
  end

  defp port_open_count(lines) do
    Enum.reduce(lines, 0, fn {line, _n}, acc -> acc + length(tails(line, "Port.open(")) end)
  end

  test "every spawn site in apps/*/lib is classified in @inventory" do
    found = source_files() |> spawn_files() |> Enum.map(&elem(&1, 0)) |> MapSet.new()
    declared = @inventory |> Map.keys() |> MapSet.new()

    unclassified = MapSet.difference(found, declared) |> Enum.sort()

    assert unclassified == [],
           """
           New subprocess spawn site(s) with no release-env classification.
           Decide whether the command can boot a BEAM or an agent CLI; if it
           can, route it through `Arbiter.Worker.ReleaseEnv`. Then add the file
           to @inventory (and to the table in the bd-2oelme PR body).

           #{Enum.join(unclassified, "\n")}
           """

    stale = MapSet.difference(declared, found) |> Enum.sort()

    assert stale == [],
           "These @inventory entries no longer contain a spawn — drop them:\n" <>
             Enum.join(stale, "\n")
  end

  test ":scrubbed files actually reference ReleaseEnv" do
    for {rel, :scrubbed} <- @inventory do
      body = File.read!(Path.join(@repo_root, rel))

      assert body =~ "ReleaseEnv",
             "#{rel} is classified :scrubbed but does not reference ReleaseEnv."
    end
  end

  test "the shared helper is the only module allowed to spawn an arbitrary command" do
    helper = File.read!(Path.join(@repo_root, @release_env_source))

    assert helper =~ "def cmd(command, args, opts",
           "#{@release_env_source} no longer defines the shared cmd/3 wrapper."

    # `clean_pairs/0` is raw material; splicing it in by hand at a call site is
    # exactly the per-site copy this ticket removed.
    hand_rolled =
      for {rel, lines} <- source_files(),
          rel != @release_env_source,
          {line, n} <- lines,
          String.contains?(line, "clean_pairs("),
          do: "#{rel}:#{n}: #{String.trim(line)}"

    assert hand_rolled == [],
           """
           `ReleaseEnv.clean_pairs/0` is called outside the helper. Use
           `ReleaseEnv.cmd/3` or `ReleaseEnv.port_env/1` so there is exactly
           one implementation of the scrub.

           #{Enum.join(hand_rolled, "\n")}
           """
  end
end
