defmodule Arbiter.Agents.SecurityPolicy do
  @moduledoc """
  The normalized, **provider-agnostic** security posture for an acolyte run.

  An acolyte (worker or reviewer) is an autonomous coding agent spawned in a
  git worktree. Left unconfigured it silently inherits the host operator's
  global agent config — on the Claude provider that means the operator's
  personal `~/.claude/settings.json` (historically `defaultMode: auto`, an
  **empty deny list**) and an **un-sandboxed** run with full filesystem and
  network reach. A wedged live server traced to exactly that posture
  (2026-06-03) is what this module exists to prevent.

  This struct is the single normalized shape every provider adapter maps to
  its own mechanism. It names *intent* ("auto mode, deny destructive ops,
  scope the filesystem to the worktree"), never provider syntax. The Claude
  adapter (`Arbiter.Agents.Claude.Security`) translates it into
  `--permission-mode` / `--settings` / `--dangerously-skip-permissions`; a
  future adapter (antigravity, Codex, …) maps the *same* struct to its own
  flags. See `docs/acolyte-security.md` and the harness design
  (`docs/agent-harness-design.md`, bd-c6xf18).

  ## Shape

      %Arbiter.Agents.SecurityPolicy{
        permissions: %{
          mode: :auto | :strict | :bypass,
          allow: [String.t()],          # operator-added allow rules (adapter-interpreted)
          deny:  [String.t()],          # operator-added deny rules (adapter-interpreted)
          safe_defaults: [atom()]       # baseline destructive-op categories (non-empty by default)
        },
        sandbox: %{
          enabled: boolean(),
          filesystem: :worktree | :none,
          network: boolean()
        }
      }

  ### `permissions.mode`

    * `:bypass` — the headless-safe default. The interactive permission
      classifier is skipped entirely (`--dangerously-skip-permissions`) so
      there is no approval prompt that can freeze a headless acolyte.
      The **deny list is still enforced** via `--settings` — the deny list is
      a hard block at the tool level, orthogonal to the interactive classifier.
      This is the right default for autonomous, headless acolyte runs where
      worktree containment + the deny list are the real fence.
    * `:auto`   — opt-in for interactive/supervised runs. The permission
      classifier is active (`--permission-mode auto`): edits are auto-accepted
      but the classifier can pause and ask for approval. The deny list is also
      enforced. **Do not use as the acolyte default**: in headless `--print`
      mode, a classifier prompt that can't be answered freezes the run
      silently.
    * `:strict` — only explicitly allowed tools run; anything not on the
      allow-list is blocked (in non-interactive `--print` mode "ask" collapses
      to "deny"). Deny still enforced.

  ### `permissions.safe_defaults`

  The baseline destructive-operation categories every adapter must deny — the
  "non-empty deny even in `auto`" guarantee. Each adapter expands a category
  into its own concrete rules. Categories:

    * `:no_destructive_fs`  — recursive force-deletes (`rm -rf`, …).
    * `:no_force_push`      — `git push --force` / `-f`.
    * `:no_secret_reads`    — reading `.env`, private keys, `~/.ssh`, cloud creds.
    * `:no_outside_writes`  — writing to sensitive paths outside the worktree.

  Replaceable as a whole (set `safe_defaults: []` to opt a domain out — not
  recommended), but defaults non-empty. In `:bypass` mode they are
  informational only (bypass enforces nothing).

  ### `sandbox`

  Normalized isolation intent. `filesystem: :worktree` keeps file access
  scoped to the worktree the agent was handed; `network: false` cuts the
  agent's network-egress tools. Adapters enforce this with whatever their
  provider supports — for Claude that is permission rules + directory scoping
  (a permission-level guard, *not* a kernel jail; full OS isolation is a
  documented follow-up). The field is also surfaced verbatim so the operator
  can see the declared posture.

  ## Resolution

  `resolve/2` layers, lowest precedence first:

    1. `base/0` — the hardcoded safe baseline (this module).
    2. `Application.get_env(:arbiter, :acolyte_security_policy)` — the
       install-wide default override.
    3. `workspace.config["agent"]["security"]` — the per-domain posture.
    4. an explicit per-dispatch / per-bead `override` map.

  For `permissions.allow` / `permissions.deny` each layer **unions** onto the
  previous (a domain adds to the baseline rather than dropping it). `mode`,
  `safe_defaults`, and every `sandbox` field are **replaced** by the highest
  layer that sets them. Unknown / malformed values are ignored (the codebase
  reads JSON config leniently), so a typo degrades to the safer inherited
  value rather than raising.
  """

  @enforce_keys [:permissions, :sandbox]
  defstruct [:permissions, :sandbox]

  @type mode :: :auto | :strict | :bypass
  @type filesystem :: :worktree | :none

  @type t :: %__MODULE__{
          permissions: %{
            mode: mode(),
            allow: [String.t()],
            deny: [String.t()],
            safe_defaults: [atom()]
          },
          sandbox: %{
            enabled: boolean(),
            filesystem: filesystem(),
            network: boolean()
          }
        }

  @valid_modes [:auto, :strict, :bypass]
  @valid_filesystems [:worktree, :none]
  @safe_default_categories [
    :no_destructive_fs,
    :no_force_push,
    :no_secret_reads,
    :no_outside_writes
  ]

  @doc "Valid `permissions.mode` atoms."
  @spec valid_modes() :: [mode()]
  def valid_modes, do: @valid_modes

  @doc "Valid `sandbox.filesystem` atoms."
  @spec valid_filesystems() :: [filesystem()]
  def valid_filesystems, do: @valid_filesystems

  @doc "The baseline destructive-op categories an adapter must deny by default."
  @spec safe_default_categories() :: [atom()]
  def safe_default_categories, do: @safe_default_categories

  @doc """
  The hardcoded safe baseline: `bypass` mode (headless-safe — no interactive
  classifier freeze), the full destructive-op deny baseline, worktree-scoped
  filesystem, network on (acolytes need it for `git push` / package installs),
  no operator extras. See `permissions.mode` in the moduledoc for rationale.
  """
  @spec base() :: t()
  def base do
    %__MODULE__{
      permissions: %{
        mode: :bypass,
        allow: [],
        deny: [],
        safe_defaults: @safe_default_categories
      },
      sandbox: %{
        enabled: true,
        filesystem: :worktree,
        network: true
      }
    }
  end

  @doc """
  The install-wide default: `base/0` overlaid with
  `Application.get_env(:arbiter, :acolyte_security_policy)`. This is the floor
  used whenever no workspace policy is in play (ad-hoc Tribunal runs, bare
  `ClaudeSession.start/1` callers).
  """
  @spec default() :: t()
  def default do
    merge(base(), Application.get_env(:arbiter, :acolyte_security_policy, %{}))
  end

  @doc """
  Resolve the effective policy for a workspace (or `nil`), with an optional
  per-dispatch `override` map applied last. See the moduledoc for precedence.
  """
  @spec resolve(map() | nil, map()) :: t()
  def resolve(workspace, override \\ %{})

  def resolve(nil, override), do: merge(default(), override)

  def resolve(%{__struct__: _, config: config}, override),
    do: resolve_from_config(config, override)

  def resolve(%{"config" => config}, override),
    do: resolve_from_config(config, override)

  def resolve(%{config: config}, override),
    do: resolve_from_config(config, override)

  def resolve(_other, override), do: merge(default(), override)

  defp resolve_from_config(config, override) do
    config = config || %{}
    workspace_policy = get_in(config, ["agent", "security"]) || %{}

    alt_mode =
      case get_in(config, ["security", "mode"]) do
        m when is_binary(m) or (is_atom(m) and not is_nil(m)) ->
          m

        _ ->
          case get_in(config, ["agent", "config", "security_mode"]) do
            m when is_binary(m) or (is_atom(m) and not is_nil(m)) -> m
            _ -> nil
          end
      end

    workspace_policy =
      if alt_mode do
        Map.update(workspace_policy, "permissions", %{"mode" => alt_mode}, fn perms ->
          Map.put(perms, "mode", alt_mode)
        end)
      else
        workspace_policy
      end

    default()
    |> merge(workspace_policy)
    |> merge(override)
  end

  @doc """
  Overlay a raw (string- or atom-keyed) map onto a policy. List fields
  (`allow` / `deny`) union; scalar fields replace. Used internally by
  `resolve/2`; exposed for adapter tests.
  """
  @spec merge(t(), map() | nil) :: t()
  def merge(%__MODULE__{} = policy, nil), do: policy
  def merge(%__MODULE__{} = policy, raw) when raw == %{}, do: policy

  def merge(%__MODULE__{} = policy, raw) when is_map(raw) do
    perms = sub_map(raw, :permissions)
    sandbox = sub_map(raw, :sandbox)

    %__MODULE__{
      permissions: merge_permissions(policy.permissions, perms),
      sandbox: merge_sandbox(policy.sandbox, sandbox)
    }
  end

  defp merge_permissions(base, raw) do
    %{
      mode: parse_mode(get(raw, :mode), base.mode),
      allow: union(base.allow, list_of_strings(get(raw, :allow))),
      deny: union(base.deny, list_of_strings(get(raw, :deny))),
      safe_defaults: parse_safe_defaults(get(raw, :safe_defaults), base.safe_defaults)
    }
  end

  defp merge_sandbox(base, raw) do
    %{
      enabled: parse_bool(get(raw, :enabled), base.enabled),
      filesystem: parse_filesystem(get(raw, :filesystem), base.filesystem),
      network: parse_bool(get(raw, :network), base.network)
    }
  end

  # ---- summary (for prime / dashboard / REST) ----------------------------

  @doc """
  A JSON-friendly, string-keyed summary of the resolved policy — the shape
  surfaced by the REST workspace serializer, `arb prime`, and the dashboard.
  """
  @spec summary(t()) :: map()
  def summary(%__MODULE__{} = p) do
    %{
      "mode" => Atom.to_string(p.permissions.mode),
      "allow" => p.permissions.allow,
      "deny" => p.permissions.deny,
      "safe_defaults" => Enum.map(p.permissions.safe_defaults, &Atom.to_string/1),
      "sandbox" => %{
        "enabled" => p.sandbox.enabled,
        "filesystem" => Atom.to_string(p.sandbox.filesystem),
        "network" => p.sandbox.network
      }
    }
  end

  @doc """
  A one-line human summary, e.g. `auto · fs=worktree · net=on · 4 safe-default
  denies`. Used by the dashboard badge tooltip and `arb prime`.
  """
  @spec one_line(t()) :: String.t()
  def one_line(%__MODULE__{} = p) do
    deny_count = length(p.permissions.safe_defaults) + length(p.permissions.deny)

    [
      Atom.to_string(p.permissions.mode),
      "fs=#{p.sandbox.filesystem}",
      "net=#{if p.sandbox.network, do: "on", else: "tools-off"}",
      "#{deny_count} #{if deny_count == 1, do: "deny", else: "denies"}"
    ]
    |> Enum.join(" · ")
  end

  # ---- parsing helpers ---------------------------------------------------

  # A raw map may carry string keys (JSON workspace config) or atom keys
  # (Application env / programmatic override). `get/2` tries both.
  defp get(raw, key) when is_map(raw) do
    case Map.fetch(raw, key) do
      {:ok, v} -> v
      :error -> Map.get(raw, Atom.to_string(key))
    end
  end

  defp get(_raw, _key), do: nil

  defp sub_map(raw, key) do
    case get(raw, key) do
      m when is_map(m) -> m
      _ -> %{}
    end
  end

  defp parse_mode(nil, fallback), do: fallback

  defp parse_mode(value, fallback) do
    case to_atom(value) do
      m when m in @valid_modes -> m
      _ -> fallback
    end
  end

  defp parse_filesystem(nil, fallback), do: fallback

  defp parse_filesystem(value, fallback) do
    case to_atom(value) do
      f when f in @valid_filesystems -> f
      _ -> fallback
    end
  end

  defp parse_bool(nil, fallback), do: fallback
  defp parse_bool(b, _fallback) when is_boolean(b), do: b
  defp parse_bool("true", _fallback), do: true
  defp parse_bool("false", _fallback), do: false
  defp parse_bool(_other, fallback), do: fallback

  # safe_defaults, if present at a layer, *replaces* (so a domain can opt out
  # by setting `[]`). An absent key inherits. Unknown category names are
  # dropped, not raised.
  defp parse_safe_defaults(nil, fallback), do: fallback

  defp parse_safe_defaults(list, _fallback) when is_list(list) do
    list
    |> Enum.map(&to_atom/1)
    |> Enum.filter(&(&1 in @safe_default_categories))
    |> Enum.uniq()
  end

  defp parse_safe_defaults(_other, fallback), do: fallback

  defp to_atom(v) when is_atom(v), do: v

  defp to_atom(v) when is_binary(v) do
    String.to_existing_atom(v)
  rescue
    ArgumentError -> nil
  end

  defp to_atom(_), do: nil

  defp list_of_strings(list) when is_list(list),
    do: Enum.filter(list, &(is_binary(&1) and &1 != ""))

  defp list_of_strings(_), do: []

  defp union(a, b), do: Enum.uniq(a ++ b)
end
