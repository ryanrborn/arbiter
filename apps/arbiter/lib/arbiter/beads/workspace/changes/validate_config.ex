defmodule Arbiter.Beads.Workspace.Changes.ValidateConfig do
  @moduledoc """
  Validates the shape of a `Workspace.config` JSON map on create/update.

  Rules (loose — most keys are optional):

    * Top-level must be a map (or `nil` / missing — treated as `%{}`).
    * If `"tracker"` is present, it must be a map.
    * If `"tracker.type"` is present, it must be one of the values in
      `Arbiter.Beads.Workspace.valid_tracker_types/0` (`"none"`, `"jira"`,
      `"linear"`, `"github"`).
    * If `"tracker.config"` is present, it must be a map.
    * If `"merge"` is present, it must be a map.
    * If `"merge.strategy"` is present, it must be one of the values in
      `Arbiter.Beads.Workspace.valid_merger_strategies/0` (`"direct"`, `"github"`).
    * If `"vernacular"` is present, it must be a map.
    * If `"vernacular.aliases"` is present, it must be a map of string → string.
    * If `"vernacular.emoji"` is present, it must be a map of string → string.
    * If `"agent"` / `"review_agent"` is present, it must be a map.
    * If `"agent.type"` is present, it must be one of the values in
      `Arbiter.Agents.valid_agent_types/0` (`"claude"`, `"gemini"`), OR a
      non-empty list of such strings (multi-provider pool).
    * If `"agent.config"` / `"review_agent.config"` is present, it must be a map.
    * If `"routing"` is present, it must be a map.
    * If `"routing.policy"` is present, it must be one of the values in
      `Arbiter.Agents.Routing.valid_policies/0` (`"static"`, `"by_priority"`,
      `"by_difficulty"`, `"by_budget"`, `"round_robin"`).

  Unknown keys are allowed (forward-compat). Deeper validation of vernacular keys
  (coordinator, worker, etc.) is deferred to `Arbiter.Vernacular` in gte-P2 —
  there it falls back to defaults rather than rejecting.
  """

  use Ash.Resource.Change

  alias Ash.Changeset

  @impl true
  def change(changeset, _opts, _context) do
    case Changeset.get_attribute(changeset, :config) do
      nil -> changeset
      config when is_map(config) -> validate(changeset, config)
      _other -> Changeset.add_error(changeset, field: :config, message: "must be a map")
    end
  end

  defp validate(changeset, config) do
    changeset
    |> validate_tracker(Map.get(config, "tracker"))
    |> validate_merge(Map.get(config, "merge"))
    |> validate_vernacular(Map.get(config, "vernacular"))
    |> validate_agent_block("agent", Map.get(config, "agent"))
    |> validate_agent_block("review_agent", Map.get(config, "review_agent"))
    |> validate_routing(Map.get(config, "routing"))
  end

  defp validate_tracker(changeset, nil), do: changeset

  defp validate_tracker(changeset, tracker) when is_map(tracker) do
    valid_types = Arbiter.Beads.Workspace.valid_tracker_types()

    changeset
    |> then(fn cs ->
      case Map.get(tracker, "type") do
        nil ->
          cs

        type ->
          if type in valid_types do
            cs
          else
            Changeset.add_error(cs,
              field: :config,
              message:
                "tracker.type must be one of #{Enum.join(valid_types, ", ")}; got: #{inspect(type)}"
            )
          end
      end
    end)
    |> then(fn cs ->
      case Map.get(tracker, "config") do
        nil -> cs
        c when is_map(c) -> cs
        _ -> Changeset.add_error(cs, field: :config, message: "tracker.config must be a map")
      end
    end)
  end

  defp validate_tracker(changeset, _) do
    Changeset.add_error(changeset, field: :config, message: "tracker must be a map")
  end

  defp validate_merge(changeset, nil), do: changeset

  defp validate_merge(changeset, merge) when is_map(merge) do
    valid_strategies = Arbiter.Beads.Workspace.valid_merger_strategies()

    changeset
    |> then(fn cs ->
      case Map.get(merge, "strategy") do
        nil ->
          cs

        strategy ->
          if strategy in valid_strategies do
            cs
          else
            Changeset.add_error(cs,
              field: :config,
              message:
                "merge.strategy must be one of #{Enum.join(valid_strategies, ", ")}; got: #{inspect(strategy)}"
            )
          end
      end
    end)
    |> then(fn cs ->
      case Map.get(merge, "warden_max_polls") do
        nil -> cs
        n when is_integer(n) and n > 0 -> cs
        "infinity" -> cs
        s when is_binary(s) ->
          case Integer.parse(s) do
            {n, ""} when n > 0 -> cs
            _ ->
              Changeset.add_error(cs,
                field: :config,
                message: "merge.warden_max_polls must be a positive integer or \"infinity\"; got: #{inspect(s)}"
              )
          end
        other ->
          Changeset.add_error(cs,
            field: :config,
            message: "merge.warden_max_polls must be a positive integer or \"infinity\"; got: #{inspect(other)}"
          )
      end
    end)
  end

  defp validate_merge(changeset, _) do
    Changeset.add_error(changeset, field: :config, message: "merge must be a map")
  end

  defp validate_vernacular(changeset, nil), do: changeset

  defp validate_vernacular(changeset, vernacular) when is_map(vernacular) do
    changeset
    |> validate_string_map(Map.get(vernacular, "aliases"), "vernacular.aliases")
    |> validate_string_map(Map.get(vernacular, "emoji"), "vernacular.emoji")
  end

  defp validate_vernacular(changeset, _) do
    Changeset.add_error(changeset, field: :config, message: "vernacular must be a map")
  end

  defp validate_string_map(changeset, nil, _label), do: changeset

  defp validate_string_map(changeset, map, label) when is_map(map) do
    invalid =
      Enum.find(map, fn
        {k, v} when is_binary(k) and is_binary(v) -> false
        _ -> true
      end)

    case invalid do
      nil ->
        changeset

      {k, v} ->
        Changeset.add_error(changeset,
          field: :config,
          message:
            "#{label} must be a map of string → string; got: #{inspect(k)} => #{inspect(v)}"
        )
    end
  end

  defp validate_string_map(changeset, _, label) do
    Changeset.add_error(changeset, field: :config, message: "#{label} must be a map")
  end

  defp validate_agent_block(changeset, _label, nil), do: changeset

  defp validate_agent_block(changeset, label, block) when is_map(block) do
    valid_types = Arbiter.Agents.valid_agent_types()

    changeset
    |> then(fn cs ->
      case Map.get(block, "type") do
        nil ->
          cs

        type when is_binary(type) ->
          if type in valid_types do
            cs
          else
            Changeset.add_error(cs,
              field: :config,
              message:
                "#{label}.type must be one of #{Enum.join(valid_types, ", ")}; got: #{inspect(type)}"
            )
          end

        types when is_list(types) ->
          invalid = Enum.reject(types, &(&1 in valid_types))

          cond do
            types == [] ->
              Changeset.add_error(cs,
                field: :config,
                message: "#{label}.type list must not be empty"
              )

            invalid != [] ->
              Changeset.add_error(cs,
                field: :config,
                message:
                  "#{label}.type list contains invalid types #{inspect(invalid)}; " <>
                    "each must be one of #{Enum.join(valid_types, ", ")}"
              )

            true ->
              cs
          end

        other ->
          Changeset.add_error(cs,
            field: :config,
            message:
              "#{label}.type must be a string or list of strings; got: #{inspect(other)}"
          )
      end
    end)
    |> then(fn cs ->
      case Map.get(block, "config") do
        nil -> cs
        c when is_map(c) -> cs
        _ -> Changeset.add_error(cs, field: :config, message: "#{label}.config must be a map")
      end
    end)
  end

  defp validate_agent_block(changeset, label, _) do
    Changeset.add_error(changeset, field: :config, message: "#{label} must be a map")
  end

  defp validate_routing(changeset, nil), do: changeset

  defp validate_routing(changeset, routing) when is_map(routing) do
    valid_policies = Arbiter.Agents.Routing.valid_policies()

    case Map.get(routing, "policy") do
      nil ->
        changeset

      policy ->
        if policy in valid_policies do
          changeset
        else
          Changeset.add_error(changeset,
            field: :config,
            message:
              "routing.policy must be one of #{Enum.join(valid_policies, ", ")}; got: #{inspect(policy)}"
          )
        end
    end
  end

  defp validate_routing(changeset, _) do
    Changeset.add_error(changeset, field: :config, message: "routing must be a map")
  end
end
