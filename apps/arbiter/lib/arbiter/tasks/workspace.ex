defmodule Arbiter.Tasks.Workspace do
  @moduledoc """
  A `Workspace` groups tasks and holds user-configurable settings: tracker
  config (external system: none, jira, linear, github), merge strategy, agent
  routing, and so on.

  These live in a single JSON `config` column. Missing keys fall back to a
  `:none` tracker. Tracker abstraction: see `Arbiter.Trackers`.

  ## Default workspace

  At boot, `priv/repo/seeds.exs` ensures a workspace named `"default"` exists with
  a `:none` tracker. Tasks land here unless the user partitions them across
  multiple workspaces.

  ## Config shape (all keys optional)

      %{
        "tracker" => %{
          "type" => "jira",                    # one of: "none", "jira", "linear", "github"
          "config" => %{
            "host" => "leotechnologies.atlassian.net",
            "project_key" => "VR",
            "credentials_ref" => "env:JIRA_TOKEN"
          }
        },
        "merge" => %{
          "strategy" => "direct",              # one of: "direct", "gitlab", "github"
          "config" => %{                       # adapter-specific; shape depends on strategy
            "owner" => "myorg",                # e.g. for "github": owner/repo/credentials
            "repo" => "myrepo",
            "credentials_ref" => "env:GITHUB_TOKEN"
          }
        },
        "review_gate" => %{
          "max_rounds" => 2                    # optional integer ≥ 1; caps the difficulty
                                               # default (min wins). See review_gate_max_rounds/1.
        }
      }

  Tracker helpers (`Tracker.for_task/1`) land in gte-019.
  Merger resolution (`Arbiter.Mergers.for_workspace/1`) reads `merge.strategy`.
  """

  use Ash.Resource,
    otp_app: :arbiter,
    domain: Arbiter.Tasks,
    data_layer: AshSqlite.DataLayer,
    extensions: [AshCloak]

  @valid_tracker_types ~w(none jira shortcut linear github)
  @valid_merger_strategies ~w(direct gitlab github)

  sqlite do
    table "workspaces"
    repo Arbiter.Repo
  end

  # Encrypt the `secrets` attribute at rest. ash_cloak renames the raw attribute
  # to `encrypted_secrets` (a binary/bytea column, public?: false, sensitive?:
  # true), wires writes through AES-256-GCM, and adds a decrypting calculation.
  #
  # We deliberately do NOT enable `decrypt_by_default`: auto-loading that
  # calculation immediately after a write (Ash 3.25 / ash_cloak 0.2) trips an
  # internal calculation-attach error. Instead, internal callers decrypt on
  # demand via `secrets_map/1`, which reads the always-selected stored
  # `encrypted_secrets` column. The decrypted value is NEVER serialised — see
  # ArbiterWeb workspace_json.
  cloak do
    vault(Arbiter.Vault)
    attributes([:secrets])
  end

  actions do
    defaults [:read, :destroy]

    create :create do
      primary? true
      accept [:name, :description, :prefix, :config]

      argument :secrets, :map do
        allow_nil? true

        description """
        Write-only map of secret key → token string, merge-patched into the
        workspace's encrypted secrets. A key with a null value removes it.
        Never returned in any read response. Referenced via
        `credentials_ref: "secret:<key>"`.
        """
      end

      change {Arbiter.Tasks.Workspace.Changes.MergeSecrets, []}
      change {Arbiter.Tasks.Workspace.Changes.ValidateConfig, []}
      change {Arbiter.Tasks.Workspace.Changes.StartMergeQueue, []}
      change {Arbiter.Tasks.Workspace.Changes.StartPRPatrol, []}
    end

    update :update do
      primary? true
      accept [:name, :description, :prefix, :config]
      require_atomic? false

      argument :secrets, :map do
        allow_nil? true

        description """
        Write-only map of secret key → token string, merge-patched into the
        workspace's existing encrypted secrets. A key with a null value removes
        it; omitting the argument leaves all secrets untouched.
        """
      end

      change {Arbiter.Tasks.Workspace.Changes.MergeSecrets, []}
      change {Arbiter.Tasks.Workspace.Changes.ValidateConfig, []}
    end

    update :patch_config do
      description """
      Field-level config update. Deep-merges `patch` into the existing config
      and removes `unset_paths` (dotted strings), then runs ValidateConfig on
      the result. Unlike `:update`, this **never** replaces the whole config
      map — siblings of the changed key are preserved.
      """

      require_atomic? false
      accept []

      argument :patch, :map do
        allow_nil? true
        description "Partial config to deep-merge into the existing config."
      end

      argument :unset_paths, {:array, :string} do
        allow_nil? true

        description "Dotted paths to remove from the existing config (e.g. \"tracker.config.host\")."
      end

      change {Arbiter.Tasks.Workspace.Changes.PatchConfig, []}
      change {Arbiter.Tasks.Workspace.Changes.ValidateConfig, []}
    end
  end

  attributes do
    uuid_v7_primary_key :id

    attribute :name, :string do
      allow_nil? false
      public? true
      constraints min_length: 1, max_length: 100, trim?: true
    end

    attribute :description, :string do
      public? true
      constraints max_length: 500, trim?: true
    end

    attribute :prefix, :string do
      allow_nil? false
      public? true
      default "bd"
      constraints min_length: 1, max_length: 16, trim?: true, match: ~r/^[a-z][a-z0-9]*$/

      description """
      Short identifier prepended to every Issue ID in this workspace (e.g. "bd-3o8",
      "verus-VR-17575"). Lowercase letters + digits only, max 16 chars.
      """
    end

    attribute :config, :map do
      public? true
      default %{}

      description """
      Workspace configuration: tracker, merge strategy, agent routing, etc.
      See module doc for shape. Missing keys fall back to a :none tracker.
      """
    end

    # Encrypted at rest via ash_cloak (see the `cloak` block). At compile time
    # this attribute is renamed to `encrypted_secrets` (binary column,
    # public?: false) and replaced by a decrypting calculation of the same name.
    # Holds %{String.t() => String.t()} — secret key → token. Write-only:
    # set through the create/update `secrets` argument, never serialised.
    attribute :secrets, :map do
      public? false
      allow_nil? true
      default %{}

      description "Encrypted tracker/merger credentials. Resolved via credentials_ref \"secret:<key>\"."
    end

    create_timestamp :created_at
    update_timestamp :updated_at
  end

  @doc """
  Decrypts and returns the workspace's secrets map.

  Reads the stored `encrypted_secrets` column (always selected, since it is a
  plain attribute) and decrypts it with `Arbiter.Vault`. Returns `%{}` when no
  secrets are set or the column is unloaded — so callers can treat "no secrets"
  and "missing key" uniformly.

  This is the internal read path for `credentials_ref: "secret:<key>"`
  resolution (see `Arbiter.Agents.CredentialsRef`). The values are never
  serialised; only `secret_keys` (names) are exposed via the API.
  """
  @spec secrets_map(t()) :: %{optional(String.t()) => String.t()}
  def secrets_map(workspace) do
    case Map.get(workspace, :encrypted_secrets) do
      enc when is_binary(enc) ->
        enc
        |> Base.decode64!()
        |> Arbiter.Vault.decrypt!()
        |> Ash.Helpers.non_executable_binary_to_term()

      _ ->
        %{}
    end
  end

  @doc """
  Returns the list of valid tracker type strings.
  """
  def valid_tracker_types, do: @valid_tracker_types

  @doc """
  Returns the list of valid merger strategy strings.

  `~w(direct gitlab github)`.
  """
  def valid_merger_strategies, do: @valid_merger_strategies

  @doc """
  Resolves the merger strategy for a workspace from
  `config["merge"]["strategy"]`, as an atom.

  Falls back to `:direct` when unset, malformed, or not a recognized strategy.
  Mirrors how `Arbiter.Trackers` resolves a tracker type.
  """
  @spec merger_strategy(t()) :: atom()
  def merger_strategy(workspace) do
    case get_in(workspace.config || %{}, ["merge", "strategy"]) do
      strategy when strategy in @valid_merger_strategies -> String.to_atom(strategy)
      _ -> :direct
    end
  end

  @doc """
  Whether the workspace auto-merges an approved merge request from
  `config["merge"]["auto_merge"]`.

  When `true`, an approved (but not-yet-merged) MR is merged automatically by
  the worker's `Arbiter.Worker.Watchdog` before the worker completes. When
  `false` (the default), the worker parks at `:awaiting_review` until a human
  merges; the next poll then sees `:merged` and completes.

  Accepts both a real boolean and the string `"true"`/`"false"` that round-trip
  through JSON workspace config. Anything else is treated as `false`.
  """
  @spec auto_merge?(t()) :: boolean()
  def auto_merge?(workspace) do
    case get_in(workspace.config || %{}, ["merge", "auto_merge"]) do
      true -> true
      "true" -> true
      _ -> false
    end
  end

  @doc """
  PR/MR title formatting convention for this workspace.

  Read from `config["merge"]["pr_title_format"]`:

    * `"conventional_commit"` — emit `type: [TICKET] description` (Conventional
      Commits format). Stripping internal team prefixes (`VS:`, etc.) and
      de-duplicating trailing ticket parentheticals.
    * anything else / absent — `:raw` (pass the task title through unchanged).
  """
  @spec pr_title_format(t()) :: :conventional_commit | :raw
  def pr_title_format(workspace) do
    case get_in(workspace.config || %{}, ["merge", "pr_title_format"]) do
      "conventional_commit" -> :conventional_commit
      _ -> :raw
    end
  end

  @doc """
  Workspace-override for the Watchdog watchdog cap (`config["merge"]["watchdog_max_polls"]`).

  Returns a positive integer, `:infinity`, or `nil` when not configured (the
  Watchdog then uses its mode-specific default: `Arbiter.Worker.Watchdog.default_max_polls_auto/0`
  for `auto_merge: true` lanes, `:infinity` for `auto_merge: false` lanes).

  Accepts an integer, a stringified integer (round-trips through JSON), or the
  string `"infinity"`.
  """
  @spec watchdog_max_polls(t()) :: pos_integer() | :infinity | nil
  def watchdog_max_polls(workspace) do
    case get_in(workspace.config || %{}, ["merge", "watchdog_max_polls"]) do
      n when is_integer(n) and n > 0 ->
        n

      "infinity" ->
        :infinity

      s when is_binary(s) ->
        case Integer.parse(s) do
          {n, ""} when n > 0 -> n
          _ -> nil
        end

      _ ->
        nil
    end
  end

  @doc """
  Whether a ReviewGate (second-worker code review) gates merges for this
  workspace, from `config["review"]["required"]`.

  When `true`, the worker parks at `:awaiting_review_gate` after the worker's
  `arb done` and spawns a distinct reviewer worker; the branch merges only on
  an APPROVE verdict. When `false` (the **default**), completion routes straight
  to the merger as before — so enabling reviews never surprises an install that
  hasn't opted in.

  Accepts both a real boolean and the string `"true"`/`"false"` that round-trip
  through JSON workspace config. Anything else is treated as `false`.
  """
  @spec review_required?(t()) :: boolean()
  def review_required?(workspace) do
    case get_in(workspace.config || %{}, ["review", "required"]) do
      true -> true
      "true" -> true
      _ -> false
    end
  end

  @doc """
  Whether the Watchdog should watch CI pipeline status alongside MR state, from
  `config["merge"]["watch_pipeline"]`.

  When `true`, the Watchdog escalates to the Admiral when a pipeline fails, but
  does NOT fail the task — a human may force-merge or rerun. Defaults to
  `false` so installs without CI are unaffected.

  Accepts both a real boolean and the string `"true"`/`"false"` that
  round-trip through JSON workspace config.
  """
  @spec watch_pipeline?(t()) :: boolean()
  def watch_pipeline?(workspace) do
    case get_in(workspace.config || %{}, ["merge", "watch_pipeline"]) do
      true -> true
      "true" -> true
      _ -> false
    end
  end

  @doc """
  The maximum number of revise-and-re-review rounds the ReviewGate runs before
  escalating, from `config["review"]["rounds"]`. Defaults to `2`.

  Reserved for the Stage 2 revise loop (bd-4g1rg1 ships only the Stage 1 gate);
  Stage 1 runs a single review pass regardless of this value. Accepts an integer
  or the stringified integer that round-trips through JSON config.
  """
  @spec review_rounds(t()) :: pos_integer()
  def review_rounds(workspace) do
    case get_in(workspace.config || %{}, ["review", "rounds"]) do
      n when is_integer(n) and n > 0 ->
        n

      s when is_binary(s) ->
        case Integer.parse(s) do
          {n, ""} when n > 0 -> n
          _ -> 2
        end

      _ ->
        2
    end
  end

  @doc """
  Per-workspace Conductor concurrency cap from `config["conductor"]["max_concurrent"]`.

  When set, the Conductor uses `min(workspace_cap, system_cap, quota_headroom)`
  as the effective concurrency limit for this workspace's graphs. Returns `nil`
  when not configured, in which case the system-wide cap applies uncapped.

  Accepts a positive integer or the stringified integer that round-trips
  through JSON config.
  """
  @spec max_concurrent(t()) :: pos_integer() | nil
  def max_concurrent(workspace) do
    case get_in(workspace.config || %{}, ["conductor", "max_concurrent"]) do
      n when is_integer(n) and n > 0 ->
        n

      s when is_binary(s) ->
        case Integer.parse(s) do
          {n, ""} when n > 0 -> n
          _ -> nil
        end

      _ ->
        nil
    end
  end

  @doc """
  The PRPatrol author allowlist, from `config["pr_patrol"]["author_logins"]`.

  When set to a non-empty list of forge logins, PRPatrol files follow-ups only
  for open PRs authored by one of those logins — so a workspace can patrol just
  its operator's own PRs rather than every open PR in the repo. Returns `[]`
  when unset / empty / malformed, which PRPatrol treats as "patrol all open PRs"
  (the backward-compatible default).
  """
  @spec pr_patrol_author_logins(t()) :: [String.t()]
  def pr_patrol_author_logins(workspace) do
    (workspace.config || %{})
    |> get_in(["pr_patrol", "author_logins"])
    |> List.wrap()
    |> Enum.filter(&is_binary/1)
  end

  @doc """
  Optional workspace cap on the ReviewGate's revise-and-rediscuss round count,
  from `config["review_gate"]["max_rounds"]`.

  When set, this cap is applied as `min(difficulty_default, workspace_cap)` so
  it can only tighten the difficulty-derived default — never loosen it beyond
  what the difficulty allows. Returns `nil` when not configured, letting the
  difficulty default apply uncapped.

  Accepts a positive integer or the stringified integer that round-trips through
  JSON config.
  """
  @spec review_gate_max_rounds(t()) :: pos_integer() | nil
  def review_gate_max_rounds(workspace) do
    case get_in(workspace.config || %{}, ["review_gate", "max_rounds"]) do
      n when is_integer(n) and n > 0 ->
        n

      s when is_binary(s) ->
        case Integer.parse(s) do
          {n, ""} when n > 0 -> n
          _ -> nil
        end

      _ ->
        nil
    end
  end
end
