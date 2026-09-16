defmodule Arbiter.Config.Paths do
  @moduledoc """
  Single resolver for the on-disk roots that must never bake in a
  developer's home directory: `worktree_root/0`
  (`Arbiter.Worker.Worktree`, `Arbiter.Reviews.Checkout`),
  `output_log_root/0` (`Arbiter.Worker.OutputLog`) and `sessions_root/0`
  (`Arbiter.Sessions.Layout`) — plus `primary_checkout/0`, the live source
  tree those roots must stay outside of (RFC §10.2).

  A release doesn't load `config/dev.exs`, so a plain
  `Application.get_env(:arbiter, :worktree_root, "/some/other/box/arbiter-worktrees")`
  fallback bakes one developer's home directory into every release.
  Resolution order, checked fresh on every call (no caching, so
  `ARBITER_*` env vars take effect immediately — note this also means an
  `ARBITER_*` var exported in a shell outranks any test's own
  `Application.put_env/3`):

    1. environment variable (`ARBITER_WORKTREE_ROOT` / `ARBITER_OUTPUT_LOG_ROOT`)
    2. application config (`config :arbiter, :worktree_root, ...`) — set by
       `config/dev.exs`, `config/test.exs`, or a test's own
       `Application.put_env/3`
    3. `$HOME`-relative default, expanded at call time
  """

  @spec worktree_root() :: String.t()
  def worktree_root do
    resolve("ARBITER_WORKTREE_ROOT", :worktree_root, "~/dev/arbiter-worktrees")
  end

  @spec output_log_root() :: String.t()
  def output_log_root do
    resolve("ARBITER_OUTPUT_LOG_ROOT", :output_log_root, "~/dev/arbiter-worker-logs")
  end

  @doc """
  Root holding the per-session provisioning scaffolds (RFC §9.1,
  `<sessions_root>/<session-id>/…`).

  Deliberately a sibling of the worktree root and **never** inside the primary
  checkout: §10.2 layer 1 is "scaffold, never point at a checkout", and a
  default that nested session working directories under the live source tree
  would hand Phoenix hot-reload a directory full of agent scratch files.
  `Arbiter.Sessions.Layout.outside_primary_checkout?/1` asserts the property
  rather than trusting this default.
  """
  @spec sessions_root() :: String.t()
  def sessions_root do
    resolve("ARBITER_SESSIONS_ROOT", :sessions_root, "~/dev/arbiter-sessions")
  end

  @doc """
  Root holding the shared memory layers a coordinator session mounts
  read-only (RFC §9.4, `Arbiter.Sessions.Memory`).

  Points at a flat directory of frontmatter-tagged `*.md` files — the
  frontmatter convention documented on `Arbiter.Sessions.Memory` (a
  `metadata.type` key, and for `project` a `metadata.workspace_id` key). This
  is not the layout `arb init` produces today (`memory/MEMORY.md` has no such
  frontmatter); an operator wanting real memory mounted into sessions must
  point `ARBITER_MEMORY_ROOT` at a directory laid out this way. The default is
  an empty directory that just happens not to exist yet, which
  `Arbiter.Sessions.Memory` treats as "no memories" rather than an error.
  """
  @spec memory_root() :: String.t()
  def memory_root do
    resolve("ARBITER_MEMORY_ROOT", :memory_root, "~/.arbiter/memory")
  end

  @doc """
  The **primary checkout** — the source tree the live server runs from, and the
  thing RFC §10.2 exists to keep sessions out of.

  Resolution mirrors `scripts/build-local-release.sh` and
  `ArbiterCli.Cmd.Start.project_root/0` so all three agree on what "the live
  checkout" means:

    1. `ARB_PRIMARY_CHECKOUT` — the explicit override, same as the script's.
    2. `config :arbiter, :primary_checkout` — explicit configuration.
    3. `ARB_HOME` — how the server is started.
    4. `~/.config/arbiter/home` — recorded by `arb install-service`.
    5. `~/dev/arbiter`.

  Note the order differs from `worktree_root/0` and friends above, which put
  their environment variable first. `ARB_HOME` is **ambient**, not an override:
  it is exported into every process the server spawns (including every worker
  and every test run started from a checkout), so treating it the way those
  roots treat their dedicated `ARBITER_*` vars would mean an explicit
  configuration could never win. `ARB_PRIMARY_CHECKOUT` is the dedicated
  override and keeps its place at the top.

  Returns `nil` when nothing resolves (no `HOME`), which callers must treat as
  "the guard is inactive" rather than "there is no checkout" — an unresolved
  checkout is exactly the case `build-local-release.sh` warns loudly about.
  `Arbiter.Sessions.Layout.outside_primary_checkout?/2` reads it that way.
  """
  @spec primary_checkout() :: String.t() | nil
  def primary_checkout do
    env("ARB_PRIMARY_CHECKOUT") || configured_checkout() || env("ARB_HOME") ||
      recorded_home() || home_relative("dev/arbiter")
  end

  defp configured_checkout do
    case Application.get_env(:arbiter, :primary_checkout) do
      value when is_binary(value) and value != "" -> Path.expand(value)
      _ -> nil
    end
  end

  defp env(name) do
    case System.get_env(name) do
      value when is_binary(value) and value != "" -> Path.expand(value)
      _ -> nil
    end
  end

  defp recorded_home do
    with path when is_binary(path) <- home_relative(".config/arbiter/home"),
         {:ok, contents} <- File.read(path),
         trimmed when trimmed != "" <- String.trim(contents) do
      Path.expand(trimmed)
    else
      _ -> nil
    end
  end

  defp home_relative(rest) do
    case System.get_env("HOME") do
      home when is_binary(home) and home != "" -> Path.join(home, rest)
      _ -> nil
    end
  end

  @doc """
  Directories holding Claude Code session JSONLs that belong to the
  **coordinator**, swept by `Arbiter.Sessions.UsageIngest` (bd-be804c).

  Each entry is a `<config_dir>/projects/<project-slug>` directory — i.e. the
  directory the `<session-id>.jsonl` files live in, not the config dir above
  them. On the dogfood host that is
  `~/.claude/projects/-home-ryan-dev-admiral`.

  Same resolution order as the roots above, except the **default is `[]`**:
  metering someone's `~/.claude` is opt-in. A wrong guess here would either
  silently meter nothing or, worse, bill an unrelated project's sessions to
  the fleet, so an install that wants coordinator metering names its
  directories explicitly.

  `ARBITER_COORDINATOR_SESSION_DIRS` takes a `:`- or `,`-separated list;
  application config takes a list or a single string. Blank entries are
  dropped (an empty segment would otherwise expand to the cwd) and `~` is
  expanded.
  """
  @spec coordinator_session_dirs() :: [String.t()]
  def coordinator_session_dirs do
    raw =
      System.get_env("ARBITER_COORDINATOR_SESSION_DIRS") ||
        Application.get_env(:arbiter, :coordinator_session_dirs) ||
        []

    raw
    |> List.wrap()
    |> Enum.flat_map(&String.split(&1, [":", ","]))
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
    |> Enum.map(&Path.expand/1)
    |> Enum.uniq()
  end

  defp resolve(env_var, config_key, default) do
    System.get_env(env_var) ||
      Application.get_env(:arbiter, config_key) ||
      expand_default(default, env_var)
  end

  defp expand_default("~/" <> rest, env_var) do
    case System.get_env("HOME") do
      nil ->
        raise "cannot resolve default path \"~/#{rest}\": HOME is unset — set #{env_var} " <>
                "(or the corresponding :arbiter application config) explicitly"

      home ->
        Path.join(home, rest)
    end
  end
end
