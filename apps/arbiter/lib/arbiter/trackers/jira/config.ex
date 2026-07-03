defmodule Arbiter.Trackers.Jira.Config do
  @moduledoc """
  Reads the Jira tracker configuration from the active workspace.

  ## Resolution order

    1. Process dict (`put_active/1`) — set by request lifecycles or tests.
    2. `Application.get_env(:arbiter, :jira_default_config)` — a static
       fallback for tools that don't carry a workspace (e.g. a CLI escript
       or a Mix task seeded from env vars).
    3. Neither → `{:error, %Error{kind: :config_missing}}`.

  ## Shape

      %{
        "host" => "leotechnologies.atlassian.net",
        "project_key" => "VR",
        "credentials_ref" => "env:JIRA_TOKEN",
        "email" => "ryan.born@leotechnologies.com",
        # optional:
        "status_map" => %{
          # Task lifecycle event -> Jira target STATUS name (NOT a transition
          # name). `Arbiter.Trackers.Jira.transition/2` resolves a path of
          # transitions to reach the target status, walking the workflow graph
          # for multi-hop moves (e.g. Backlog -> … -> In Progress).
          "open" => "To Do",
          "in_progress" => "In Progress",
          "pr_opened" => "In Code Review",
          "approved_unmerged" => "Pending Merge",
          "merged" => "Code Complete",
          # `:closed` targets the terminal status. On LeoTech's VR (Verus)
          # workflow this is "Done"; the path runs In Code Review -> Code
          # Complete -> Done, and the Code Complete hop is gated until the
          # "QA Testing Notes" and "Deployment Notes" custom fields are set.
          "closed" => "Done"
        },
        # Optional transition graph used for multi-hop path-finding. Keys are
        # the *source* status name; each edge names the transition to invoke
        # and the status it lands on. The single-hop fast path (a live
        # transition whose `to` already equals the target) needs no graph —
        # only multi-hop targets do. See `@default_transition_graph`.
        "transition_graph" => %{
          "Backlog" => [%{"transition" => "To do next", "to" => "To Do"}],
          "To Do" => [%{"transition" => "Start work", "to" => "In Progress"}]
        },
        "field_ids" => %{
          "title" => "summary",
          "description" => "description",
          # Verified LeoTech VR custom-field IDs (textarea, ADF-encoded).
          "qa_notes" => "customfield_10184",
          "deployment_notes" => "customfield_10185",
          "assignee" => "assignee"
        }
      }

  `credentials_ref` is a small DSL: `"env:NAME"` looks up `System.get_env/1`.
  Other prefixes (e.g. `"file:..."`) could be added later; today only `env:`
  is supported. A bare string (no prefix) is treated as a literal token, but
  this should be avoided outside of tests.
  """

  alias Arbiter.Agents.CredentialsRef
  alias Arbiter.Tasks.Workspace
  alias Arbiter.Trackers.Jira.Error

  @pdict_key {__MODULE__, :active_workspace_config}

  # Task lifecycle event -> Jira target STATUS name. The adapter path-finds a
  # sequence of transitions to reach the target (see `Jira.transition/2`).
  # Events with no entry here are treated as "this tracker doesn't model that
  # state" and are skipped silently — only a *mapped* status that can't be
  # reached fails loudly. Defaults are the conservative Jira-default status
  # names; LeoTech's VR (Verus) workflow overrides them via workspace config.
  @default_status_map %{
    open: "To Do",
    in_progress: "In Progress",
    pr_opened: "In Code Review",
    approved_unmerged: "Pending Merge",
    merged: "Code Complete",
    closed: "Done"
  }

  # Default multi-hop transition graph for LeoTech's VR (Verus) workflow,
  # keyed by SOURCE status name. Each edge is the transition to invoke and the
  # status it lands on. Only multi-hop targets need a graph entry — a target
  # reachable by a single live transition is resolved directly from the
  # `/transitions` response (its `to` field), no graph required.
  #
  # The verified edges (transition ids in parens) come from the VR workflow
  # discovery in bd-c4cfuv:
  #   Backlog --Pull request created--> n/a; Backlog --To do next--> To Do (141)
  #   In Progress --Pull request created--> In Code Review (51)
  #   In Code Review --Approved and merged--> Code Complete (61)
  #   In Code Review --Approved and not merged--> Pending Merge (111)
  #
  # The "To Do -> In Progress" and "Code Complete -> Done" edges were not
  # captured by the discovery pass; the names below are best-guess and should
  # be confirmed against a live `/transitions` probe and overridden per
  # workspace via `tracker.config.transition_graph` if they differ.
  @default_transition_graph %{
    "Backlog" => [%{"transition" => "To do next", "to" => "To Do"}],
    "What's Next" => [%{"transition" => "To do next", "to" => "To Do"}],
    "Groomed" => [%{"transition" => "To do next", "to" => "To Do"}],
    "To Do" => [%{"transition" => "Start work", "to" => "In Progress"}],
    "In Progress" => [%{"transition" => "Pull request created", "to" => "In Code Review"}],
    "In Code Review" => [
      %{"transition" => "Approved and merged", "to" => "Code Complete"},
      %{"transition" => "Approved and not merged", "to" => "Pending Merge"}
    ],
    "Code Complete" => [%{"transition" => "Done", "to" => "Done"}]
  }

  # The QA / Deployment custom-field IDs default to LeoTech's verified VR
  # (Verus) workspace IDs — these are the gated fields LeoTech requires before
  # a forward transition (`com.atlassian.jira.plugin.system.customfieldtypes:textarea`,
  # so they take ADF). A workspace running a *different* Jira instance overrides
  # them via `tracker.config.field_ids`; the merge in `field_ids/1` lets the
  # workspace win. Keeping them here (rather than only in workspace config)
  # means the gate is correct out-of-the-box for the common case.
  #
  # `fix_version` → `"fixVersions"` is the built-in Jira field for fix versions.
  # Including it here lets the gating machinery discover and satisfy the
  # fix-version gate when workflows require it (see bd-1924hi).
  @default_field_ids %{
    title: "summary",
    description: "description",
    assignee: "assignee",
    qa_notes: "customfield_10184",
    deployment_notes: "customfield_10185",
    fix_version: "fixVersions"
  }

  # Priority name → Arbiter priority integer (0 = highest, 4 = lowest).
  # Configurable via workspace `tracker.config.priority_map`. Jira's standard
  # priority names; workspaces using custom names override them per-entry.
  @default_priority_map %{
    "Highest" => 0,
    "High" => 1,
    "Medium" => 2,
    "Low" => 3,
    "Lowest" => 4
  }

  # Default difficulty bucket thresholds: [{max_pts, difficulty}] sorted
  # ascending. Used when `difficulty.field_id` is configured but no custom
  # buckets are supplied. pts ≤ 1 → D0, ≤ 3 → D1, ≤ 5 → D2, ≤ 8 → D3, > 8 → D4.
  @default_difficulty_buckets [{1, 0}, {3, 1}, {5, 2}, {8, 3}]

  @type transition_edge :: %{required(String.t()) => String.t()}

  @type config :: %{
          host: String.t(),
          project_key: String.t(),
          email: String.t() | nil,
          token: String.t(),
          status_map: %{atom() => String.t()},
          transition_graph: %{String.t() => [transition_edge()]},
          field_ids: %{atom() => String.t()},
          priority_map: %{String.t() => 0..4},
          story_points_field: String.t() | nil,
          difficulty_buckets: [{non_neg_integer(), 0..4}] | nil,
          fix_version_name: String.t() | nil
        }

  @doc """
  Set the active Jira workspace config for the current process. Accepts a
  `Workspace` (reads its `config["tracker"]["config"]`), a raw tracker-config
  map, or `nil` to clear.

  Idempotent; safe to call from request setup.
  """
  @spec put_active(Workspace.t() | map() | nil) :: :ok
  def put_active(nil) do
    Process.delete(@pdict_key)
    :ok
  end

  def put_active(%Workspace{config: config} = workspace) do
    tracker_config = get_in(config || %{}, ["tracker", "config"]) || %{}

    Process.put(
      @pdict_key,
      CredentialsRef.embed_secrets(tracker_config, Workspace.secrets_map(workspace))
    )

    :ok
  end

  def put_active(%{} = tracker_config) do
    Process.put(@pdict_key, tracker_config)
    :ok
  end

  @doc """
  Merge a per-repo tracker config override over the current process's active
  config. Looks up `config["tracker"]["config"]["repos"][repo]` and, if present,
  merges it over the config seeded by `put_active/1` — so a workspace whose
  repos bind to different Jira projects targets the right one. No-op when `repo`
  is nil/blank or the workspace declares no override for it. See
  `Arbiter.Trackers.ConfigOverride`.
  """
  @spec override_repo(Workspace.t() | nil, String.t() | nil) :: :ok
  def override_repo(workspace, repo),
    do: Arbiter.Trackers.ConfigOverride.apply(@pdict_key, workspace, repo)

  @doc "Clear the per-process active config."
  @spec clear() :: :ok
  def clear do
    Process.delete(@pdict_key)
    :ok
  end

  @doc """
  Resolve the active Jira config into a fully-populated struct (with the
  token already looked up from env). Returns `{:ok, config}` or
  `{:error, %Error{kind: :config_missing}}`.
  """
  @spec resolve() :: {:ok, config} | {:error, Error.t()}
  def resolve do
    raw =
      Process.get(@pdict_key) ||
        Application.get_env(:arbiter, :jira_default_config) ||
        %{}

    with {:ok, host} <- fetch_string(raw, "host"),
         {:ok, project_key} <- fetch_string(raw, "project_key"),
         {:ok, token} <- fetch_token(raw) do
      {:ok,
       %{
         host: host,
         project_key: project_key,
         email: stringy(Map.get(raw, "email")),
         token: token,
         status_map: status_map(raw),
         transition_graph: transition_graph(raw),
         field_ids: field_ids(raw),
         priority_map: priority_map(raw),
         story_points_field: story_points_field(raw),
         difficulty_buckets: difficulty_buckets(raw),
         fix_version_name: stringy(Map.get(raw, "fix_version_name"))
       }}
    end
  end

  @doc "Same as resolve/0 but raises on missing config (for callers that prefer fail-fast)."
  @spec resolve!() :: config | no_return
  def resolve! do
    case resolve() do
      {:ok, cfg} ->
        cfg

      {:error, %Error{message: msg}} ->
        raise ArgumentError, msg
    end
  end

  @doc "Returns the active project_key, or nil if none."
  @spec active_project_key() :: String.t() | nil
  def active_project_key do
    case Process.get(@pdict_key) || Application.get_env(:arbiter, :jira_default_config) do
      %{"project_key" => key} when is_binary(key) -> key
      _ -> nil
    end
  end

  # ---- Internals ----------------------------------------------------------

  defp fetch_string(map, key) do
    case Map.get(map, key) do
      v when is_binary(v) and v != "" ->
        {:ok, v}

      _ ->
        {:error,
         %Error{
           kind: :config_missing,
           status: nil,
           message:
             "Jira config missing #{inspect(key)}. Set workspace.config[\"tracker\"][\"config\"][#{inspect(key)}] or :arbiter, :jira_default_config in Application env.",
           raw: nil
         }}
    end
  end

  # Resolve the token via the shared credentials_ref DSL (env: / secret: /
  # literal), mapping its tagged failures onto Jira's config_missing error.
  defp fetch_token(raw) do
    case CredentialsRef.resolve(Map.get(raw, "credentials_ref"), raw) do
      {:ok, token} ->
        {:ok, token}

      {:env_unset, name} ->
        {:error, config_missing("Jira credentials env var #{inspect(name)} is unset")}

      {:secret_not_found, key} ->
        {:error, config_missing("Jira secret #{inspect(key)} is not set on the workspace")}

      :missing ->
        {:error, config_missing("Jira config missing \"credentials_ref\"")}
    end
  end

  defp config_missing(message) do
    %Error{kind: :config_missing, status: nil, message: message, raw: nil}
  end

  defp status_map(raw) do
    user = Map.get(raw, "status_map") || %{}

    base =
      Enum.into(@default_status_map, %{}, fn {atom_key, default} ->
        {atom_key, Map.get(user, Atom.to_string(atom_key), default)}
      end)

    # Allow workspaces to map extra lifecycle events beyond the defaults.
    extras =
      for {k, v} <- user, is_binary(k), is_binary(v), into: %{} do
        {String.to_atom(k), v}
      end

    Map.merge(base, extras)
  end

  # The transition graph drives multi-hop path-finding. Workspaces may supply
  # their own (string-keyed status -> list of %{"transition","to"} edges); the
  # VR default is used when none is configured. A workspace that sets an empty
  # map opts out of graph-based multi-hop (single-hop fast path still works).
  defp transition_graph(raw) do
    case Map.get(raw, "transition_graph") do
      %{} = graph when map_size(graph) > 0 -> normalize_graph(graph)
      _ -> @default_transition_graph
    end
  end

  defp normalize_graph(graph) do
    for {from, edges} <- graph, is_binary(from), is_list(edges), into: %{} do
      {from, Enum.filter(edges, &valid_edge?/1)}
    end
  end

  defp valid_edge?(%{"transition" => t, "to" => to}) when is_binary(t) and is_binary(to), do: true
  defp valid_edge?(_), do: false

  defp field_ids(raw) do
    user = Map.get(raw, "field_ids") || %{}

    base =
      Enum.into(@default_field_ids, %{}, fn {atom_key, default} ->
        {atom_key, Map.get(user, Atom.to_string(atom_key), default)}
      end)

    # Allow workspace to define extra fields beyond the defaults.
    extras =
      for {k, v} <- user, is_binary(k), is_binary(v), into: %{} do
        {String.to_atom(k), v}
      end

    Map.merge(base, extras)
  end

  defp stringy(nil), do: nil
  defp stringy(v) when is_binary(v), do: v
  defp stringy(_), do: nil

  # priority_map: workspace-configurable name → Arbiter priority integer.
  # String keys (Jira priority names); workspace overrides win per-entry.
  defp priority_map(raw) do
    user = Map.get(raw, "priority_map") || %{}

    base =
      Enum.into(@default_priority_map, %{}, fn {name, default} ->
        case Map.fetch(user, name) do
          {:ok, v} when is_integer(v) and v >= 0 and v <= 4 -> {name, v}
          _ -> {name, default}
        end
      end)

    extras =
      for {k, v} <- user,
          is_binary(k),
          is_integer(v) and v >= 0 and v <= 4,
          not Map.has_key?(@default_priority_map, k),
          into: %{} do
        {k, v}
      end

    Map.merge(base, extras)
  end

  # story_points_field: Jira custom-field ID for story points (e.g.
  # "customfield_10016"). Read from `difficulty.field_id` in config. When nil,
  # difficulty extraction is disabled.
  defp story_points_field(raw) do
    get_in(raw, ["difficulty", "field_id"]) |> stringy()
  end

  # difficulty_buckets: [{max_pts, difficulty}] sorted ascending, or nil (off).
  # When a workspace sets `difficulty.field_id` but omits `difficulty.buckets`,
  # the default bucketing applies.
  defp difficulty_buckets(raw) do
    field_id = story_points_field(raw)

    if is_nil(field_id) do
      nil
    else
      case get_in(raw, ["difficulty", "buckets"]) do
        buckets when is_list(buckets) and length(buckets) > 0 ->
          parse_buckets(buckets) || @default_difficulty_buckets

        _ ->
          @default_difficulty_buckets
      end
    end
  end

  defp parse_buckets(buckets) do
    parsed =
      Enum.flat_map(buckets, fn
        [max, diff]
        when (is_integer(max) or is_float(max)) and is_integer(diff) and diff >= 0 and diff <= 4 ->
          [{round(max), diff}]

        _ ->
          []
      end)

    case Enum.sort_by(parsed, fn {max, _} -> max end) do
      [] -> nil
      sorted -> sorted
    end
  end
end
