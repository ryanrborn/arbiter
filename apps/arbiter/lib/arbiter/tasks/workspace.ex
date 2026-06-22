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
    data_layer: AshSqlite.DataLayer

  @valid_tracker_types ~w(none jira shortcut linear github)
  @valid_merger_strategies ~w(direct gitlab github)

  sqlite do
    table "workspaces"
    repo Arbiter.Repo
  end

  actions do
    defaults [:read, :destroy]

    create :create do
      primary? true
      accept [:name, :description, :prefix, :config]
      change {Arbiter.Tasks.Workspace.Changes.ValidateConfig, []}
      change {Arbiter.Tasks.Workspace.Changes.StartMergeQueue, []}
    end

    update :update do
      primary? true
      accept [:name, :description, :prefix, :config]
      require_atomic? false
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

    create_timestamp :created_at
    update_timestamp :updated_at
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
