defmodule Arbiter.Worker.ReleaseEnv do
  @moduledoc """
  Strips OTP-release environment variables from worker subshell environments.

  When arbiter runs as a systemd OTP release (bd-aj6fv5), the service unit
  exports ROOTDIR, BINDIR, and RELEASE_* into the process environment. These
  variables are inherited by every `Port.open` child, including the Claude
  workers spawned in worktrees. If a worker shell runs `mix test` (or `elixir`
  / `erl` / `arb`), the Erlang runtime reads ROOTDIR and BINDIR to find its OTP
  libs and boot scripts — and finds the release's ERTS instead of the
  worktree's mise-pinned toolchain. The resulting crash:

      Runtime terminating during boot ({'cannot get bootfile',
        '/opt/arbiter/releases/v0.1.5/bin/no_dot_erlang.boot'})

  is the exact failure bd-4hkzn3 investigates. The ReviewGate degrades to
  static-analysis-only because `mix test` cannot boot.

  ## Fix

  `clean_pairs/0` returns `{name, false}` pairs for each release var currently
  set in the VM process environment. Erlang's `Port.open` interprets `false` as
  "unset this var in the child's environment" — so passing these pairs into the
  `{:env, pairs}` Port option removes them from the child without touching any
  other inherited var.

  It also returns a PATH override that strips the release's ERTS and bin dirs
  so `erl`, `erlc`, and `mix` (found via mise shims) resolve to the
  per-worktree toolchain rather than the release's bundled ERTS.

  ## The shared helper (bd-2oelme)

  `clean_pairs/0` is the raw material; callers must not splice it in by hand.
  Every spawn that can start a BEAM (`mix`, `elixir`, `erl`, `iex`) or an agent
  CLI (`claude`, `agy`, `codex`) — or a `sh -c` that may run one — goes through
  exactly one of:

    * `cmd/3` — a `System.cmd/3` drop-in that merges the cleanup pairs into
      the `:env` option (using `nil` to unset, which is what `System.cmd/3`
      understands).
    * `port_env/1` — returns `[{name, value | false}]` for `Port.open`'s
      `{:env, …}` option (`false` unsets, which is what Erlang's port driver
      understands), with caller pairs appended so they can still override.

  `Arbiter.Worker.ClaudeSession.env_pairs/3` (all worker Port.opens),
  `Arbiter.Agents.Preflight` (the auth probe), `Arbiter.Worker.Worktree`
  (`mix deps.get` worktree seeding), `Arbiter.Workflows.CodeReview.Checks`
  (the ReviewGate reviewer), `Arbiter.Workflows.ReviewReply` (the reply
  composer) and `Arbiter.Quota.CloudCode` (the `agy` usage probe) are the
  call sites. `release_env_guard_test.exs` holds the full inventory and fails
  if a new spawn site appears without being classified.

  Pure-tool spawns (`git`, `gh`, `glab`, `cp`, `kill`, `pgrep`, `diff`) are
  deliberately left alone: they never read ROOTDIR/BINDIR, and stripping vars
  from them would only add noise.
  """

  # Static release-specific var names, in addition to the RELEASE_* prefix scan.
  # ROOTDIR and BINDIR are the critical ones that hijack the Erlang runtime boot.
  # ERTS_LIB_DIR is set by some OTP release tooling and has the same effect.
  @static_release_vars ~w(ROOTDIR BINDIR ERTS_LIB_DIR)

  @doc """
  Returns env pairs that unset release-specific vars and (if needed) override
  PATH with a version that omits the release's ERTS and bin dirs.

  Returns `[]` when no release env is detected, so the call is a no-op on a
  plain dev-mode VM that was never started as an OTP release.
  """
  @spec clean_pairs() :: [{String.t(), String.t() | false}]
  def clean_pairs do
    unset_pairs() ++ cleaned_path_pairs()
  end

  @doc """
  `System.cmd/3` drop-in that scrubs release vars from the child environment.

  Merges `clean_pairs/0` (translated to `System.cmd/3`'s `nil`-means-unset
  convention) ahead of any caller-supplied `:env` pairs, so a caller can still
  override a specific var. All other options are passed through untouched.

  Use this for every `mix` / `elixir` / `erl` / `claude` / `agy` / `codex`
  spawn, and for any `sh -c` whose script may invoke one.
  """
  @spec cmd(binary(), [binary()], keyword()) :: {Collectable.t(), non_neg_integer()}
  def cmd(command, args, opts \\ []) when is_binary(command) and is_list(args) do
    System.cmd(command, args, Keyword.put(opts, :env, cmd_env(Keyword.get(opts, :env, []))))
  end

  @doc """
  Env pairs for `System.cmd/3`: the release cleanup (as `{name, nil}`) followed
  by `extra`.

  Only needed when a call site cannot use `cmd/3` directly — prefer `cmd/3`.
  """
  @spec cmd_env([{String.t(), String.t() | nil | false}]) :: [{String.t(), String.t() | nil}]
  def cmd_env(extra \\ []) when is_list(extra) do
    (clean_pairs() ++ extra)
    |> Enum.map(fn
      {name, false} -> {name, nil}
      pair -> pair
    end)
  end

  @doc """
  Env pairs for `Port.open`'s `{:env, …}` option: the release cleanup (as
  `{name, false}`) followed by `extra`, which wins on a name collision.

  Returns `extra` unchanged on a dev VM with no release env detected.
  """
  @spec port_env([{String.t(), String.t() | false}]) :: [{String.t(), String.t() | false}]
  def port_env(extra \\ []) when is_list(extra), do: clean_pairs() ++ extra

  # -- private ---------------------------------------------------------------

  # Returns {name, false} pairs for every release var currently set.
  defp unset_pairs do
    release_var_names()
    |> Enum.filter(&(System.get_env(&1) != nil))
    |> Enum.map(&{&1, false})
  end

  # Collect all var names to clean: the static list plus every RELEASE_* var
  # present in the current process environment (RELEASE_ROOT, RELEASE_NODE, …).
  defp release_var_names do
    dynamic =
      System.get_env()
      |> Map.keys()
      |> Enum.filter(&String.starts_with?(&1, "RELEASE_"))

    (@static_release_vars ++ dynamic) |> Enum.uniq()
  end

  # Strip release-owned bin dirs from PATH. We identify them by checking each
  # PATH segment against RELEASE_ROOT. If RELEASE_ROOT is unset or PATH is
  # already clean, returns [].
  defp cleaned_path_pairs do
    with path when is_binary(path) <- System.get_env("PATH"),
         release_root when is_binary(release_root) <- System.get_env("RELEASE_ROOT") do
      cleaned =
        path
        |> String.split(":")
        |> Enum.reject(&String.starts_with?(&1, release_root))
        |> Enum.join(":")

      if cleaned != path, do: [{"PATH", cleaned}], else: []
    else
      _ -> []
    end
  end
end
