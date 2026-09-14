defmodule Arbiter.Config.Paths do
  @moduledoc """
  Single resolver for the two on-disk roots that must never bake in a
  developer's home directory: `worktree_root/0`
  (`Arbiter.Worker.Worktree`, `Arbiter.Reviews.Checkout`) and
  `output_log_root/0` (`Arbiter.Worker.OutputLog`).

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
