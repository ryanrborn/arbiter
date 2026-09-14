defmodule Arbiter.Worker.ReleaseEnvGuardTest do
  @moduledoc """
  bd-2oelme: a missed subprocess spawn only fails in release mode, which dev CI
  never exercises — so the inventory is asserted in a test instead.

  Three rules, all evaluated against the source of `apps/*/lib`:

    1. **Literal BEAM/agent commands must not call `System.cmd/3` directly.**
       `System.cmd("mix", …)`, `System.cmd("sh", …)`, `System.cmd("claude", …)`
       and friends must go through `Arbiter.Worker.ReleaseEnv.cmd/3`.
    2. **`Port.open/2` is allowlisted.** A file that opens a port must be
       declared here and must reference `ReleaseEnv`.
    3. **Every spawn site is classified.** A file containing any spawn
       primitive must appear in `@inventory`, so a new one can't land
       unclassified.

  When you add a spawn site, add its file to `@inventory` with the right
  classification — that is the whole maintenance cost.
  """
  use ExUnit.Case, async: true

  @repo_root Path.expand("../../../../..", __DIR__)

  # Commands that boot a BEAM or an agent CLI, plus the shells that may invoke
  # one. A `System.cmd/3` with any of these as a *literal* first argument is a
  # bug: it must be `ReleaseEnv.cmd/3`.
  @beam_or_agent_commands ~w(
    mix elixir elixirc iex erl erlc escript
    claude agy codex gemini
    sh bash zsh /bin/sh /bin/bash env
  )

  # Files that may call `Port.open/2`. Each must route its env through
  # `ReleaseEnv`.
  @port_open_allowlist [
    "apps/arbiter/lib/arbiter/worker/claude_session.ex",
    "apps/arbiter/lib/arbiter/agents/preflight.ex"
  ]

  # Every file under `apps/*/lib` that contains a subprocess spawn primitive,
  # and why it is (or isn't) scrubbed. Mirrors the table in the bd-2oelme PR.
  #
  #   :helper   — `ReleaseEnv` itself, the one place `System.cmd/3` is allowed
  #               to run an arbitrary command.
  #   :scrubbed — routes at least one BEAM/agent spawn through `ReleaseEnv`.
  #   :pure_tool — only spawns tools that never read ROOTDIR/BINDIR
  #               (git, gh, cp, kill, pgrep, diff, dolt, …).
  #   :cli_escript — `arbiter_cli`; the `arb` escript is never a child of the
  #               release VM (see the moduledoc note below), and the app has no
  #               runtime dependency on `:arbiter`, so `ReleaseEnv` is not
  #               reachable from it.
  @inventory %{
    "apps/arbiter/lib/arbiter/worker/release_env.ex" => :helper,
    "apps/arbiter/lib/arbiter/worker/claude_session.ex" => :scrubbed,
    "apps/arbiter/lib/arbiter/agents/preflight.ex" => :scrubbed,
    "apps/arbiter/lib/arbiter/worker/worktree.ex" => :scrubbed,
    "apps/arbiter/lib/arbiter/workflows/code_review/checks.ex" => :scrubbed,
    "apps/arbiter/lib/arbiter/workflows/review_reply.ex" => :scrubbed,
    "apps/arbiter/lib/arbiter/quota/cloud_code.ex" => :scrubbed,
    "apps/arbiter/lib/arbiter/single_instance.ex" => :pure_tool,
    "apps/arbiter/lib/arbiter/version.ex" => :pure_tool,
    "apps/arbiter/lib/arbiter/worker.ex" => :pure_tool,
    "apps/arbiter/lib/arbiter/loop/apply/repo_doc.ex" => :pure_tool,
    "apps/arbiter/lib/arbiter/mcp/agent_config.ex" => :pure_tool,
    "apps/arbiter/lib/arbiter/mergers/direct.ex" => :pure_tool,
    "apps/arbiter/lib/arbiter/mergers/gitlab.ex" => :pure_tool,
    "apps/arbiter/lib/arbiter/mergers/github/repo_resolver.ex" => :pure_tool,
    "apps/arbiter/lib/arbiter/reviews/checkout.ex" => :pure_tool,
    "apps/arbiter/lib/arbiter/tasks/status_backfill.ex" => :pure_tool,
    "apps/arbiter/lib/arbiter/worker/primary_sync.ex" => :pure_tool,
    "apps/arbiter/lib/arbiter/worker/resume_context.ex" => :pure_tool,
    "apps/arbiter/lib/arbiter/worker/review_gate.ex" => :pure_tool,
    "apps/arbiter/lib/arbiter/workflows/code_review.ex" => :pure_tool,
    "apps/arbiter/lib/arbiter/workflows/code_review/consumer_trace.ex" => :pure_tool,
    "apps/arbiter/lib/arbiter/workflows/merge_queue/conflict_resolver.ex" => :pure_tool,
    "apps/arbiter/lib/mix/tasks/arbiter.import_from_dolt.ex" => :pure_tool,
    "apps/arbiter_web/lib/arbiter_web/application.ex" => :pure_tool,
    "apps/arbiter_cli/lib/arbiter_cli/version.ex" => :cli_escript,
    "apps/arbiter_cli/lib/arbiter_cli/cmd/init.ex" => :cli_escript,
    "apps/arbiter_cli/lib/arbiter_cli/cmd/start.ex" => :cli_escript
  }

  # `ReleaseEnv.cmd(` counts: a site that has already been routed through the
  # helper is still a spawn site, and must stay in the inventory.
  @spawn_primitives [
    "System.cmd(",
    "System.shell(",
    "Port.open(",
    ":os.cmd(",
    "MuonTrap",
    "ReleaseEnv.cmd("
  ]

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

  # ---- rules ----------------------------------------------------------------

  test "no BEAM or agent CLI is spawned via a bare System.cmd/3" do
    offenders =
      for {rel, lines} <- source_files(),
          rel != "apps/arbiter/lib/arbiter/worker/release_env.ex",
          {line, n} <- lines,
          cmd <- @beam_or_agent_commands,
          String.contains?(line, ~s|System.cmd("#{cmd}"|),
          do: "#{rel}:#{n}: #{String.trim(line)}"

    assert offenders == [],
           """
           These sites spawn a BEAM or agent CLI without the release-env scrub.
           Use `Arbiter.Worker.ReleaseEnv.cmd/3` instead of `System.cmd/3` — a
           child that inherits ROOTDIR/BINDIR/RELEASE_* from the systemd OTP
           release boots against the release's ERTS and dies with
           `cannot get bootfile` (bd-4hkzn3 / bd-2oelme).

           #{Enum.join(offenders, "\n")}
           """
  end

  test "Port.open/2 sites are allowlisted and route their env through ReleaseEnv" do
    port_files =
      for {rel, lines} <- source_files(),
          Enum.any?(lines, fn {line, _n} -> String.contains?(line, "Port.open(") end),
          rel != "apps/arbiter/lib/arbiter/worker/release_env.ex",
          do: rel

    unexpected = port_files -- @port_open_allowlist

    assert unexpected == [],
           """
           New `Port.open/2` site(s). A port child inherits the release env, so
           the spawn must merge `Arbiter.Worker.ReleaseEnv.port_env/1` into its
           `{:env, …}` option. Add the file to @port_open_allowlist once it does.

           #{Enum.join(unexpected, "\n")}
           """

    for rel <- @port_open_allowlist do
      body = File.read!(Path.join(@repo_root, rel))

      assert body =~ "ReleaseEnv",
             "#{rel} opens a port but no longer references ReleaseEnv — the " <>
               "release-env scrub was dropped from a spawn path."
    end
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
end
