defmodule ArbiterCli.Vernacular do
  @moduledoc "Fetches global vernacular labels from the Arbiter API for CLI output."

  @defaults %{
    "coordinator" => "coordinator",
    "worker" => "polecat",
    "issue" => "bead",
    "rig" => "rig",
    "epic" => "mountain",
    "merge_queue" => "refinery",
    "monitor" => "witness",
    "watchdog" => "deacon",
    "workspace" => "workspace",
    "escalation" => "escalation",
    "pr" => "pull request",
    "sling" => "sling",
    "worktree" => "worktree"
  }

  @spec fetch() :: map()
  def fetch do
    case ArbiterCli.Client.get("/api/settings") do
      {:ok, %{"data" => %{"vernacular" => v}}} when is_map(v) -> Map.merge(@defaults, v)
      _ -> @defaults
    end
  end

  @spec label(map(), String.t()) :: String.t()
  def label(v, key), do: Map.get(v, key, Map.get(@defaults, key, key))

  @spec cap(map(), String.t()) :: String.t()
  def cap(v, key), do: label(v, key) |> String.capitalize()
end
