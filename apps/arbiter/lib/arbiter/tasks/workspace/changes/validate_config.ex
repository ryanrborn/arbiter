defmodule Arbiter.Tasks.Workspace.Changes.ValidateConfig do
  @moduledoc """
  Validates the shape of a `Workspace.config` JSON map on create/update.

  Rules (loose — most keys are optional):

    * Top-level must be a map (or `nil` / missing — treated as `%{}`).
    * If `"tracker"` is present, it must be a map.
    * If `"tracker.type"` is present, it must be one of the values in
      `Arbiter.Tasks.Workspace.valid_tracker_types/0` (`"none"`, `"jira"`,
      `"linear"`, `"github"`).
    * If `"tracker.config"` is present, it must be a map.
    * If `"merge"` is present, it must be a map.
    * If `"merge.strategy"` is present, it must be one of the values in
      `Arbiter.Tasks.Workspace.valid_merger_strategies/0` (`"direct"`, `"github"`).
    * If `"agent"` / `"review_agent"` is present, it must be a map.
    * If `"agent.type"` is present, it must be one of the values in
      `Arbiter.Agents.valid_agent_types/0` (`"claude"`, `"gemini"`), OR a
      non-empty list of such strings (multi-provider pool).
    * If `"agent.config"` / `"review_agent.config"` is present, it must be a map.
    * If `"routing"` is present, it must be a map.
    * If `"routing.policy"` is present, it must be one of the values in
      `Arbiter.Agents.Routing.valid_policies/0` (`"static"`, `"by_priority"`,
      `"by_difficulty"`, `"by_budget"`, `"round_robin"`).
    * If `"review_gate"` is present, it must be a map.
    * If `"review_gate.max_rounds"` is present, it must be a positive integer.
    * If `"conductor"` is present, it must be a map.
    * If `"conductor.max_concurrent"` is present, it must be a positive integer.
    * If `"review_automation"` is present, it must be a map.
    * If `"review_automation.default"` is present, it must be `"auto"` or `"flag"`.
    * If `"review_automation.auto_authors"` is present, it must be a list of strings.
    * If `"review_automation.repo_overrides"` is present, it must be a map where
      every value is `"auto"` or `"flag"`.

  Unknown keys are allowed (forward-compat) — including any legacy
  `"vernacular"` key, which is now ignored rather than validated.
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
    |> validate_agent_block("agent", Map.get(config, "agent"))
    |> validate_agent_block("review_agent", Map.get(config, "review_agent"))
    |> validate_routing(Map.get(config, "routing"))
    |> validate_review_gate(Map.get(config, "review_gate"))
    |> validate_conductor(Map.get(config, "conductor"))
    |> validate_review_automation(Map.get(config, "review_automation"))
  end

  defp validate_tracker(changeset, nil), do: changeset

  defp validate_tracker(changeset, tracker) when is_map(tracker) do
    valid_types = Arbiter.Tasks.Workspace.valid_tracker_types()

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
    valid_strategies = Arbiter.Tasks.Workspace.valid_merger_strategies()

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
      case Map.get(merge, "watchdog_max_polls") do
        nil ->
          cs

        n when is_integer(n) and n > 0 ->
          cs

        "infinity" ->
          cs

        s when is_binary(s) ->
          case Integer.parse(s) do
            {n, ""} when n > 0 ->
              cs

            _ ->
              Changeset.add_error(cs,
                field: :config,
                message:
                  "merge.watchdog_max_polls must be a positive integer or \"infinity\"; got: #{inspect(s)}"
              )
          end

        other ->
          Changeset.add_error(cs,
            field: :config,
            message:
              "merge.watchdog_max_polls must be a positive integer or \"infinity\"; got: #{inspect(other)}"
          )
      end
    end)
  end

  defp validate_merge(changeset, _) do
    Changeset.add_error(changeset, field: :config, message: "merge must be a map")
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
            message: "#{label}.type must be a string or list of strings; got: #{inspect(other)}"
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

  defp validate_review_gate(changeset, nil), do: changeset

  defp validate_review_gate(changeset, review_gate) when is_map(review_gate) do
    case Map.get(review_gate, "max_rounds") do
      nil ->
        changeset

      n when is_integer(n) and n > 0 ->
        changeset

      s when is_binary(s) ->
        case Integer.parse(s) do
          {n, ""} when n > 0 ->
            changeset

          _ ->
            Changeset.add_error(changeset,
              field: :config,
              message: "review_gate.max_rounds must be a positive integer; got: #{inspect(s)}"
            )
        end

      other ->
        Changeset.add_error(changeset,
          field: :config,
          message: "review_gate.max_rounds must be a positive integer; got: #{inspect(other)}"
        )
    end
  end

  defp validate_review_gate(changeset, _) do
    Changeset.add_error(changeset, field: :config, message: "review_gate must be a map")
  end

  defp validate_conductor(changeset, nil), do: changeset

  defp validate_conductor(changeset, conductor) when is_map(conductor) do
    case Map.get(conductor, "max_concurrent") do
      nil ->
        changeset

      n when is_integer(n) and n > 0 ->
        changeset

      s when is_binary(s) ->
        case Integer.parse(s) do
          {n, ""} when n > 0 ->
            changeset

          _ ->
            Changeset.add_error(changeset,
              field: :config,
              message: "conductor.max_concurrent must be a positive integer; got: #{inspect(s)}"
            )
        end

      other ->
        Changeset.add_error(changeset,
          field: :config,
          message: "conductor.max_concurrent must be a positive integer; got: #{inspect(other)}"
        )
    end
  end

  defp validate_conductor(changeset, _) do
    Changeset.add_error(changeset, field: :config, message: "conductor must be a map")
  end

  @valid_automation_modes ~w[auto flag]

  defp validate_review_automation(changeset, nil), do: changeset

  defp validate_review_automation(changeset, block) when is_map(block) do
    changeset
    |> then(fn cs ->
      case Map.get(block, "default") do
        nil ->
          cs

        mode ->
          if mode in @valid_automation_modes do
            cs
          else
            Changeset.add_error(cs,
              field: :config,
              message:
                "review_automation.default must be one of #{Enum.join(@valid_automation_modes, ", ")}; got: #{inspect(mode)}"
            )
          end
      end
    end)
    |> then(fn cs ->
      case Map.get(block, "auto_authors") do
        nil ->
          cs

        list when is_list(list) ->
          invalid = Enum.reject(list, &is_binary/1)

          if invalid == [] do
            cs
          else
            Changeset.add_error(cs,
              field: :config,
              message: "review_automation.auto_authors must be a list of strings"
            )
          end

        _ ->
          Changeset.add_error(cs,
            field: :config,
            message: "review_automation.auto_authors must be a list of strings"
          )
      end
    end)
    |> then(fn cs ->
      case Map.get(block, "repo_overrides") do
        nil ->
          cs

        overrides when is_map(overrides) ->
          invalid = Enum.reject(overrides, fn {_k, v} -> v in @valid_automation_modes end)

          if invalid == [] do
            cs
          else
            Changeset.add_error(cs,
              field: :config,
              message:
                "review_automation.repo_overrides values must each be one of " <>
                  "#{Enum.join(@valid_automation_modes, ", ")}"
            )
          end

        _ ->
          Changeset.add_error(cs,
            field: :config,
            message: "review_automation.repo_overrides must be a map"
          )
      end
    end)
  end

  defp validate_review_automation(changeset, _) do
    Changeset.add_error(changeset, field: :config, message: "review_automation must be a map")
  end
end
