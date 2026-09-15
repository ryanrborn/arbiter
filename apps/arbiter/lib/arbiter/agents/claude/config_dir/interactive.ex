defmodule Arbiter.Agents.Claude.ConfigDir.Interactive do
  @moduledoc """
  The **interactive-session** variant of `Arbiter.Agents.Claude.ConfigDir`
  (bd-aprlbb, RFC §9.2).

  `ConfigDir` seeds the config dir a `claude --print` worker runs against. A
  browser-hosted coordinator session is the other shape: a real PTY, a real
  TUI, and — crucially — **nobody at the keyboard during launch**. RFC §9.2
  measured that a fresh `CLAUDE_CONFIG_DIR` blocks on three interactive prompts
  before the agent is usable:

  | Gate | Key written here |
  |---|---|
  | Theme picker | `theme` |
  | Login-method wizard | `hasCompletedOnboarding: true` + `lastOnboardingVersion` |
  | "Is this a folder you trust?" | `projects.<cwd>.hasTrustDialogAccepted: true` |

  The live check of the first real browser session (bd-5xlkkj) found two more
  that §9.2 had not measured, because they only fire once the *other* three are
  answered and the TUI actually gets far enough to load a project:

  | Gate | Key written here |
  |---|---|
  | "New MCP server found in this project: arbiter" | `enabledMcpjsonServers` (settings) + `projects.<cwd>.enabledMcpjsonServers` |
  | "WARNING: Claude Code running in Bypass Permissions mode" | not seeded — *removed*, by running the session in `auto` mode (see `settings/1`) |

  Key names verified against the installed CLI (Claude Code 2.1.272) rather
  than assumed: the settings schema describes `enabledMcpjsonServers` as "List
  of approved MCP servers from .mcp.json", and the permission-mode enum is
  `["acceptEdits", "auto", "bypassPermissions", "default", "dontAsk", "plan"]`.

  `--print` never reaches any of them, which is why `ConfigDir` does not seed
  them today — it writes `settings.json` but never `.claude.json`. In a
  detached tmux pane an unseeded launch does not fail, it **hangs**: a session
  that looks alive, bills nothing, and does nothing. So this is not a nicety;
  it is the difference between a session and a wedged pane.

  ## What this does not share with `ConfigDir`

  `ConfigDir.path/0` is one **install-wide** directory shared by every worker.
  A session's config dir is **per session** (`<sessions_root>/<id>/config`,
  §9.1) and is passed in — that isolation is what makes per-session metering
  work at all (the JSONL `Arbiter.Sessions.UsageIngest` reads lives under it),
  and it is the only isolation mode B still provides (§8.2).

  The auth mode is likewise **explicit** here rather than inferred. `ConfigDir`
  decides whether to seed `.credentials.json` from the worker OAuth-token gate;
  a session's mode is an operator choice recorded on the session row, so this
  module takes `:auth_mode` and calls the matching `ConfigDir` half
  (`seed_credentials/2` for mode B, `remove_credentials/1` for mode A).

  ## Preserving what Claude Code writes back

  `.claude.json` is Claude Code's own mutable state file — it rewrites it
  constantly (`numStartups`, per-project session metrics, the `bridgeOauth*`
  keys Remote Control needs). So this **merges** into whatever is on disk
  rather than overwriting it, and re-running on a live session's config dir is
  safe. A file that fails to parse is replaced: a corrupt state file would
  otherwise wedge every future launch, and nothing in it is precious.

  ## Secrets

  Nothing written here goes near a command line (§10.3). The mode-B credential
  is a mode-`0600` copy inside the config dir; the mode-A token is written by
  `Arbiter.Sessions.Provisioning` into a `0600` env file the launch wrapper
  sources. Neither is ever an argv token.
  """

  alias Arbiter.Agents.Claude.ConfigDir
  alias Arbiter.Agents.Claude.Security
  alias Arbiter.Agents.SecurityPolicy

  require Logger

  @claude_json ".claude.json"
  @settings_json "settings.json"

  # The version stamped into `lastOnboardingVersion` when neither config nor the
  # operator's own `.claude.json` answers. Only the "what's new" re-onboarding
  # reads it — `hasCompletedOnboarding` is the gate that actually blocks (§9.2)
  # — so a slightly stale value costs a changelog screen, not a hang.
  @fallback_onboarding_version "2.1.270"
  @default_theme "dark"

  @type opts :: [
          cwd: String.t(),
          auth_mode: :seeded_credentials | :oauth_token,
          source_dir: String.t() | nil,
          primary_checkout: String.t() | nil,
          theme: String.t(),
          extra_deny: [String.t()],
          mcp_servers: [String.t()]
        ]

  @doc """
  Seed `dir` as an interactive `CLAUDE_CONFIG_DIR`: `.claude.json` (the three
  §9.2 gates), the hardened `settings.json`, and the mode's credential posture.

  ## Options

    * `:cwd` — **required**. The session's working directory; it is the path
      that gets the trust entry, so it must be the same string the agent is
      launched with or the trust dialog still fires.
    * `:auth_mode` — `:seeded_credentials` (mode B, default) or `:oauth_token`
      (mode A). See §8.1.
    * `:source_dir` — the operator config dir to seed from. Defaults to
      `ConfigDir.source_dir/0`; pass `nil` explicitly to seed from nowhere.
    * `:primary_checkout` — the live source tree to deny writes under (§10.2
      layer 3). Defaults to `Arbiter.Config.Paths.primary_checkout/0`; `nil`
      omits the rule.
    * `:theme` — default `#{@default_theme}`.
    * `:extra_deny` — additional Claude deny rules to union in.
    * `:mcp_servers` — the `.mcp.json` server keys to pre-approve, so first
      launch does not stop on "New MCP server found in this project". Defaults
      to `[Arbiter.MCP.server_name/0]`; `[]` writes no pre-approval at all,
      which is the honest answer for a session provisioned with `mcp: false`.

  Returns `:ok`, or `{:error, reason}` when the directory could not be
  prepared. Unlike `ConfigDir.ensure/1` a failure is **not** degradable: a
  session launched against an unseeded dir hangs on the wizard, so the caller
  must abort the launch rather than continue.
  """
  @spec ensure(String.t(), opts()) :: :ok | {:error, term()}
  def ensure(dir, opts) when is_binary(dir) do
    cwd = Keyword.fetch!(opts, :cwd)

    with :ok <- File.mkdir_p(dir),
         :ok <- write_claude_json(dir, cwd, opts),
         :ok <- write_settings(dir, opts) do
      seed_auth(dir, opts)
    end
  rescue
    e -> {:error, e}
  end

  @doc """
  The `.claude.json` document for a session, merged over `existing`.

  Exposed so a test can assert the three gates without touching a filesystem,
  and so the provisioning UI can *show* an operator what gets pre-answered.
  """
  @spec claude_json(map(), String.t(), opts()) :: map()
  def claude_json(existing, cwd, opts \\ []) when is_map(existing) and is_binary(cwd) do
    projects = Map.get(existing, "projects", %{})

    project =
      projects
      |> Map.get(cwd, %{})
      |> Map.put("hasTrustDialogAccepted", true)
      |> put_mcp_approval(opts)

    existing
    |> Map.put("theme", Keyword.get(opts, :theme) || Map.get(existing, "theme") || @default_theme)
    |> Map.put("hasCompletedOnboarding", true)
    |> Map.put("lastOnboardingVersion", onboarding_version(existing, opts))
    # Auto mode's own two one-time screens (bd-5xlkkj). Neither is a security
    # gate — one is the "auto mode is now the default" notice, the other the
    # auto-mode entry warning — but both are text an unattended launch would
    # otherwise put in front of a session before its first prompt.
    |> Map.put("hasSeenAutoDefaultNotice", true)
    |> Map.put("hasSeenAutoModeEntryWarning", true)
    |> Map.put("projects", Map.put(projects, cwd, project))
  end

  @doc """
  The session `settings.json` document: the **interactive** hardened floor
  (`Arbiter.Agents.SecurityPolicy.interactive_session/0`) plus the §10.2
  layer-3 deny rules for the primary checkout, plus the two first-launch
  pre-answers this file exists to give (bd-5xlkkj).

  Layer 3 is a **guardrail, not a sandbox** — a session runs as the operator's
  user and can reach anything that user can (§10.2's own caveat). It catches
  the accident case, which is the observed failure mode: a careless edit in the
  live checkout that Phoenix hot-reload picks up half-written.

  ## Not the worker profile

  This used to be `SecurityPolicy.default/0` — the **headless worker's**
  document, `bypassPermissions` and all. That was wrong in both directions: it
  handed every session the bypass-mode acceptance warning on first launch, and
  it denied `Monitor`/`ScheduleWakeup`, which a coordinator session needs to
  watch the `/events` stream. `interactive_session/0` is the separate profile;
  the worker's is untouched.

  `skipAutoPermissionPrompt` suppresses auto mode's own entry warning. It is
  only honoured from the policy, user and flag settings sources — the user
  source is exactly this file, since a session's `CLAUDE_CONFIG_DIR` is its
  own (§9.1).
  """
  @spec settings(opts()) :: map()
  def settings(opts \\ []) do
    extra = checkout_deny_rules(primary_checkout(opts)) ++ Keyword.get(opts, :extra_deny, [])
    policy = SecurityPolicy.interactive_session()

    %{
      policy
      | permissions: %{policy.permissions | deny: policy.permissions.deny ++ extra}
    }
    |> Security.settings()
    |> Map.put("skipAutoPermissionPrompt", true)
    |> put_mcp_approval(opts)
  end

  @doc """
  Claude deny rules keeping a session's edits out of the primary checkout
  (§10.2 layer 3). `nil` yields `[]` — an unresolved checkout means the guard
  is inactive, which is honest, not silently skipped.
  """
  @spec checkout_deny_rules(String.t() | nil) :: [String.t()]
  def checkout_deny_rules(nil), do: []

  def checkout_deny_rules(checkout) when is_binary(checkout) do
    root = String.trim_trailing(checkout, "/")

    [
      "Write(#{root}/**)",
      "Edit(#{root}/**)",
      "NotebookEdit(#{root}/**)"
    ]
  end

  @doc "The filenames this module owns inside a session config dir."
  @spec filenames() :: [String.t()]
  def filenames, do: [@claude_json, @settings_json]

  @doc """
  The `.mcp.json` server keys a session pre-approves, resolved from `opts`.

  Defaults to the one server provisioning actually writes
  (`Arbiter.MCP.server_name/0`). Pre-approving a *named* server rather than
  setting `enableAllProjectMcpServers` is the point: the session's cwd is a
  scaffold we wrote, but blanket approval would also cover any `.mcp.json` a
  git worktree created inside it later brings along.
  """
  @spec mcp_servers(opts()) :: [String.t()]
  def mcp_servers(opts \\ []) do
    case Keyword.get(opts, :mcp_servers) do
      nil -> [Arbiter.MCP.server_name()]
      servers when is_list(servers) -> Enum.filter(servers, &(is_binary(&1) and &1 != ""))
    end
  end

  # ---- internals ----------------------------------------------------------

  # Two places read this, and which one answers depends on whether the cwd is a
  # trusted workspace — so both get written. Verified against Claude Code
  # 2.1.272: with only the settings key the server reports approved, and with
  # only the `.claude.json` project key it reports approved too; with neither it
  # reports "⏸ Pending approval (run `claude` to approve)".
  defp put_mcp_approval(document, opts) do
    case mcp_servers(opts) do
      [] -> document
      servers -> Map.put(document, "enabledMcpjsonServers", servers)
    end
  end

  defp write_claude_json(dir, cwd, opts) do
    path = Path.join(dir, @claude_json)
    document = path |> read_json() |> claude_json(cwd, opts)

    File.write(path, Jason.encode!(document, pretty: true))
  end

  defp write_settings(dir, opts) do
    path = Path.join(dir, @settings_json)
    # Unlink first: `File.write/2` follows a symlink, and an earlier build of
    # `ConfigDir` symlinked this file at the operator's real one.
    _ = File.rm(path)
    File.write(path, Jason.encode!(settings(opts), pretty: true))
  end

  # Mode B seeds the operator's grant; mode A must not carry one alongside its
  # token (two independent refreshers rotate each other out — bd-6umoh9).
  defp seed_auth(dir, opts) do
    case Keyword.get(opts, :auth_mode, :seeded_credentials) do
      :oauth_token -> ConfigDir.remove_credentials(dir)
      _ -> ConfigDir.seed_credentials(dir, source_dir(opts))
    end
  end

  defp source_dir(opts) do
    if Keyword.has_key?(opts, :source_dir) do
      Keyword.get(opts, :source_dir)
    else
      ConfigDir.source_dir()
    end
  end

  defp primary_checkout(opts) do
    if Keyword.has_key?(opts, :primary_checkout) do
      Keyword.get(opts, :primary_checkout)
    else
      Arbiter.Config.Paths.primary_checkout()
    end
  end

  # `lastOnboardingVersion` gates the "what's new" screen, not the blocking
  # login wizard (`hasCompletedOnboarding` is that one, and §9.2 measured it).
  # So the right answer is simply the **highest** version any of our sources
  # knows about: a value below the installed CLI's costs a changelog screen an
  # operator has to dismiss, and a value above it costs nothing.
  #
  # Taking the operator's value as a *floor* rather than a preference is the
  # point — their `~/.claude.json` may well be older than our constant (it was,
  # on the dogfood host: 2.1.63 against a 2.1.270 CLI), and preferring it would
  # hand every session the screen we are trying to pre-answer.
  defp onboarding_version(existing, opts) do
    case Keyword.get(opts, :onboarding_version) do
      explicit when is_binary(explicit) and explicit != "" ->
        explicit

      _ ->
        [
          @fallback_onboarding_version,
          operator_onboarding_version(opts),
          binary_or_nil(Map.get(existing, "lastOnboardingVersion"))
        ]
        |> Enum.reject(&is_nil/1)
        |> Enum.reduce(&higher_version/2)
    end
  end

  # Version strings from other people's files are data: an unparseable one
  # loses rather than crashing a launch.
  defp higher_version(a, b) do
    case {Version.parse(a), Version.parse(b)} do
      {{:ok, va}, {:ok, vb}} -> if Version.compare(va, vb) == :lt, do: b, else: a
      {{:ok, _}, :error} -> a
      {:error, {:ok, _}} -> b
      _ -> a
    end
  end

  defp operator_onboarding_version(opts) do
    case source_dir(opts) do
      source when is_binary(source) ->
        # The operator's file sits *beside* their config dir (`~/.claude.json`
        # next to `~/.claude`), not inside it — check both spellings.
        binary_or_nil(read_json(Path.join(source, @claude_json))["lastOnboardingVersion"]) ||
          binary_or_nil(read_json(source <> ".json")["lastOnboardingVersion"])

      _ ->
        nil
    end
  end

  defp binary_or_nil(value) when is_binary(value) and value != "", do: value
  defp binary_or_nil(_), do: nil

  # A `.claude.json` that does not parse is treated as absent. It is Claude
  # Code's own scratch state; refusing to launch over a truncated write would
  # wedge the session for nothing.
  defp read_json(path) do
    with {:ok, body} <- File.read(path),
         {:ok, %{} = json} <- Jason.decode(body) do
      json
    else
      {:error, :enoent} ->
        %{}

      other ->
        if match?({:error, _}, other) do
          Logger.warning(
            "Arbiter.Agents.Claude.ConfigDir.Interactive: #{inspect(path)} is unreadable or " <>
              "not JSON (#{inspect(other)}); rewriting it from scratch"
          )
        end

        %{}
    end
  end
end
