defmodule Arbiter.Agents.Claude.Security do
  @moduledoc """
  Translates a provider-agnostic `Arbiter.Agents.SecurityPolicy` into the
  Claude Code CLI's concrete permission mechanism.

  This is the Claude side of the policy seam: `SecurityPolicy` says *what*
  ("auto mode, deny destructive ops, no network"), this module says *how* in
  Claude's vocabulary. A second provider gets its own analogue and the
  normalized policy stays untouched.

  ## Mapping

  | Normalized mode | Claude argv | Deny enforced? |
  |---|---|---|
  | `:auto`   | `--permission-mode auto`         | yes |
  | `:strict` | `--permission-mode default`      | yes (unallowed ⇒ blocked) |
  | `:bypass` | `--dangerously-skip-permissions` | **no** (all checks skipped) |

  The allow/deny rules ride on a generated settings document passed inline as
  `--settings '<json>'` (the CLI accepts a JSON string, not just a file — so
  there is no shared-file race between concurrent acolytes, and nothing is
  read from the operator's `~/.claude`). The settings carry:

    * the expanded `safe_defaults` deny baseline (always non-empty unless the
      domain opted out),
    * the operator's extra `deny` rules,
    * `sandbox`-derived denies (network-egress tools when `network: false`),
    * the operator's `allow` rules,
    * `defaultMode` mirroring the chosen mode.

  In `:bypass` mode no settings are emitted — the flag skips every check, so
  emitting deny rules would only mislead. That is the deliberate, opt-in
  "I trust this run" posture.

  ## Honesty about enforcement level

  These are *permission-layer* guards inside the agent, not a kernel sandbox.
  They stop the agent's own tools from running a denied command, which is the
  failure mode of the motivating incident (an acolyte's own `git merge` /
  destructive op). They do **not** jail the OS process — a determined escape
  (e.g. a sub-subprocess) is out of scope here; genuine OS isolation
  (`sandbox.enabled` at the kernel level) is a documented follow-up. Bash
  prefix matching is also approximate (`rm -rf` is denied; an obfuscated
  `rm  -rf` or `rm -r -f` is covered by extra patterns but not exhaustively).
  The guarantee is "non-empty, meaningful deny by default", a strict
  improvement over the empty-deny inheritance it replaces.
  """

  alias Arbiter.Agents.SecurityPolicy

  @doc """
  The permission-mode argv fragment for a policy.

    * `:bypass` → `["--dangerously-skip-permissions"]`
    * `:auto`   → `["--permission-mode", "auto"]`
    * `:strict` → `["--permission-mode", "default"]`
  """
  @spec permission_argv(SecurityPolicy.t()) :: [String.t()]
  def permission_argv(%SecurityPolicy{permissions: %{mode: :bypass}}),
    do: ["--dangerously-skip-permissions"]

  def permission_argv(%SecurityPolicy{permissions: %{mode: mode}}),
    do: ["--permission-mode", cli_mode(mode)]

  @doc """
  The `--settings` argv fragment carrying the generated allow/deny document.
  Empty in `:bypass` mode (the flag enforces nothing, so settings are moot).
  """
  @spec settings_argv(SecurityPolicy.t()) :: [String.t()]
  def settings_argv(%SecurityPolicy{permissions: %{mode: :bypass}}), do: []

  def settings_argv(%SecurityPolicy{} = policy),
    do: ["--settings", Jason.encode!(settings(policy))]

  @doc """
  The generated Claude settings map for a policy — the same document written
  into the isolated `CLAUDE_CONFIG_DIR` (`Arbiter.Agents.Claude.ConfigDir`)
  as the install floor, and passed inline via `--settings` for the per-domain
  posture.
  """
  @spec settings(SecurityPolicy.t()) :: map()
  def settings(%SecurityPolicy{} = policy) do
    %{
      "permissions" => %{
        "defaultMode" => default_mode(policy.permissions.mode),
        "allow" => policy.permissions.allow,
        "deny" => deny_rules(policy)
      }
    }
  end

  @doc """
  The full, deduped Claude deny-rule list for a policy: expanded
  `safe_defaults` + operator `deny` + sandbox-derived denies.
  """
  @spec deny_rules(SecurityPolicy.t()) :: [String.t()]
  def deny_rules(%SecurityPolicy{permissions: perms, sandbox: sandbox}) do
    (Enum.flat_map(perms.safe_defaults, &expand_category/1) ++
       perms.deny ++
       sandbox_deny(sandbox))
    |> Enum.uniq()
  end

  # ---- internals ---------------------------------------------------------

  defp cli_mode(:auto), do: "auto"
  defp cli_mode(:strict), do: "default"

  defp default_mode(:auto), do: "auto"
  defp default_mode(:strict), do: "default"
  defp default_mode(:bypass), do: "bypassPermissions"

  # Recursive force-deletes. Bash rules match a command *prefix* up to `:`,
  # then a glob — `Bash(rm -rf:*)` matches `rm -rf <anything>`. We enumerate
  # the common spellings; this is a safety net, not a proof.
  defp expand_category(:no_destructive_fs) do
    [
      "Bash(rm -rf:*)",
      "Bash(rm -fr:*)",
      "Bash(rm -r -f:*)",
      "Bash(rm -f -r:*)",
      "Bash(rm -Rf:*)",
      "Bash(sudo rm:*)",
      "Bash(mkfs:*)",
      "Bash(dd:*)"
    ]
  end

  # Force pushes wedge shared branches (the motivating incident). The safer
  # `--force-with-lease` is intentionally *not* denied here.
  defp expand_category(:no_force_push) do
    [
      "Bash(git push --force:*)",
      "Bash(git push -f:*)",
      "Bash(git push --force=:*)"
    ]
  end

  # Reading secrets. Claude `Read(...)` rules use gitignore-style globs and
  # bind the Read tool; we add a couple of Bash guards for the obvious
  # `cat`/`less` exfil paths, acknowledging prefix matching can't be
  # exhaustive.
  defp expand_category(:no_secret_reads) do
    [
      "Read(**/.env)",
      "Read(**/.env.*)",
      "Read(**/*.pem)",
      "Read(**/*_rsa)",
      "Read(**/id_rsa)",
      "Read(**/id_ed25519)",
      "Read(**/.ssh/**)",
      "Read(**/.aws/credentials)",
      "Read(**/.netrc)",
      "Read(**/.npmrc)",
      "Read(**/secrets/**)",
      "Bash(cat .env:*)",
      "Bash(cat ~/.ssh:*)"
    ]
  end

  # Writes to sensitive paths outside a worktree. Full out-of-worktree write
  # prevention relies on `sandbox.filesystem: :worktree` scoping (the agent is
  # only handed its worktree as cwd and no extra `--add-dir`); these rules are
  # the explicit floor for the highest-value targets.
  defp expand_category(:no_outside_writes) do
    [
      "Write(/etc/**)",
      "Edit(/etc/**)",
      "Write(/usr/**)",
      "Write(~/.ssh/**)",
      "Edit(~/.ssh/**)",
      "Write(~/.claude/**)",
      "Write(~/.config/**)"
    ]
  end

  defp expand_category(_unknown), do: []

  # When the policy cuts network, deny the agent's network-egress tools.
  # (Permission-level: git/package-manager traffic isn't blocked here — that
  # needs an OS sandbox; see moduledoc.)
  defp sandbox_deny(%{network: false}) do
    [
      "WebFetch",
      "WebSearch",
      "Bash(curl:*)",
      "Bash(wget:*)",
      "Bash(nc:*)",
      "Bash(ncat:*)",
      "Bash(telnet:*)"
    ]
  end

  defp sandbox_deny(_sandbox), do: []
end
