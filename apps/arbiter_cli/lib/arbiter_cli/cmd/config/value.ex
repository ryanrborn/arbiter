defmodule ArbiterCli.Cmd.Config.Value do
  @moduledoc """
  Value parsing, dotted-path map manipulation, and the safety-check guardrail
  for `arb config set`/`unset` — the parts of `arb config` that are pure data
  transforms with no I/O.
  """

  @doc false
  def parse_value("true"), do: true
  def parse_value("false"), do: false

  def parse_value(raw) when is_binary(raw) do
    cond do
      String.match?(raw, ~r/^-?\d+$/) ->
        String.to_integer(raw)

      String.starts_with?(raw, "{") or String.starts_with?(raw, "[") ->
        case Jason.decode(raw) do
          {:ok, v} -> v
          {:error, _} -> raw
        end

      raw == "null" ->
        nil

      true ->
        raw
    end
  end

  # ----- dotted-path helpers ---------------------------------------------

  @doc false
  def split(path) when is_binary(path) do
    path |> String.split(".") |> Enum.reject(&(&1 == ""))
  end

  @doc false
  def get_in_path(value, []), do: value

  def get_in_path(map, [k | rest]) when is_map(map) do
    case Map.get(map, k) do
      nil -> nil
      sub -> get_in_path(sub, rest)
    end
  end

  def get_in_path(_, _), do: nil

  @doc false
  def put_in_path(map, [k], value) when is_map(map), do: Map.put(map, k, value)

  def put_in_path(map, [k | rest], value) when is_map(map) do
    sub =
      case Map.get(map, k) do
        %{} = s -> s
        _ -> %{}
      end

    Map.put(map, k, put_in_path(sub, rest, value))
  end

  @doc false
  def drop_path(map, [k]) when is_map(map), do: Map.delete(map, k)

  def drop_path(map, [k | rest]) when is_map(map) do
    case Map.get(map, k) do
      %{} = sub -> Map.put(map, k, drop_path(sub, rest))
      _ -> map
    end
  end

  def drop_path(other, _), do: other

  @doc false
  def deep_merge(left, right) when is_map(left) and is_map(right) do
    Map.merge(left, right, fn _k, l, r ->
      if is_map(l) and is_map(r), do: deep_merge(l, r), else: r
    end)
  end

  # ----- guardrails --------------------------------------------------------

  @doc """
  Returns `:ok` if the new config is "safe", or `{:unsafe, [reasons]}` if it
  drops a key the system relies on. Reasons mirror the task description.
  """
  def safety_check(new_config) when is_map(new_config) do
    reasons =
      []
      |> check_repo_paths(new_config)
      |> check_tracker(new_config)

    case reasons do
      [] -> :ok
      list -> {:unsafe, Enum.reverse(list)}
    end
  end

  defp check_repo_paths(reasons, config) do
    case Map.fetch(config, "repo_paths") do
      {:ok, m} when is_map(m) and map_size(m) == 0 ->
        ["repo_paths is empty — worker dispatch cannot resolve a working dir" | reasons]

      _ ->
        reasons
    end
  end

  defp check_tracker(reasons, config) do
    case get_in_path(config, ["tracker"]) do
      %{"type" => type} = tracker when is_binary(type) and type != "none" ->
        case Map.get(tracker, "config") do
          c when is_map(c) and map_size(c) > 0 ->
            reasons

          _ ->
            ["tracker.type is #{inspect(type)} but tracker.config is missing/empty" | reasons]
        end

      _ ->
        reasons
    end
  end

  # ----- rendering ----------------------------------------------------------

  @doc false
  def pretty(value) do
    case Jason.encode(value, pretty: true) do
      {:ok, s} -> s
      {:error, _} -> inspect(value)
    end
  end

  @doc false
  def pretty_inline(value) do
    case Jason.encode(value) do
      {:ok, s} -> s
      {:error, _} -> inspect(value)
    end
  end
end
