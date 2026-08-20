defmodule ArbiterCli.Cmd.Config.Formatter do
  @moduledoc """
  Text/JSON rendering for `arb config get`, `overview`, `set`, and `unset`.
  """

  alias ArbiterCli.Cmd.Config.Value
  alias ArbiterCli.Output

  # ----- get ---------------------------------------------------------------

  def emit_get(:json, value) do
    Output.emit_json(value)
  end

  def emit_get(:text, nil, path) do
    if path do
      Output.die("config: key not found: #{path}")
    else
      IO.puts("(empty)")
    end
  end

  def emit_get(:text, value, _path), do: IO.puts(Value.pretty(value))

  # ----- overview ------------------------------------------------------------

  def emit_overview(:json, ws, config) do
    Output.emit_json(overview_map(ws, config))
  end

  def emit_overview(:text, ws, config) do
    IO.puts(render_overview(ws, config))
  end

  # Structured, secret-safe summary used by `--json`. Mirrors the text sections.
  defp overview_map(ws, config) do
    %{
      "workspace" => %{
        "id" => ws["id"],
        "name" => ws["name"],
        "prefix" => ws["prefix"]
      },
      "tracker" => Map.get(config, "tracker", %{}),
      "merge" => Map.get(config, "merge", %{}),
      "agent" => Map.get(config, "agent", %{}),
      "review_agent" => Map.get(config, "review_agent", %{}),
      "routing" => Map.get(config, "routing", %{}),
      "review" => Map.get(config, "review", %{}),
      "review_gate" => Map.get(config, "review_gate", %{}),
      "standing_orders" => Map.get(config, "standing_orders", []),
      "secret_keys" => ws["secret_keys"] || []
    }
  end

  defp render_overview(ws, config) do
    [
      "Workspace: #{ws["name"]}  (#{ws["id"]})  prefix=#{ws["prefix"]}",
      "",
      section("Tracker", tracker_lines(Map.get(config, "tracker"))),
      section("Merge", merge_lines(Map.get(config, "merge"))),
      section("Agent", agent_lines(Map.get(config, "agent"))),
      section("Review agent", agent_lines(Map.get(config, "review_agent"))),
      section("Routing", routing_lines(Map.get(config, "routing"))),
      section("Review", review_lines(config)),
      section("Standing orders", standing_order_lines(Map.get(config, "standing_orders"))),
      section("Secrets", secret_lines(ws["secret_keys"] || []))
    ]
    |> Enum.reject(&is_nil/1)
    |> Enum.join("\n")
  end

  defp section(_title, []), do: nil

  defp section(title, lines) do
    "== #{title} ==\n" <> Enum.map_join(lines, "\n", &("  " <> &1)) <> "\n"
  end

  defp tracker_lines(nil), do: ["type: none"]

  defp tracker_lines(tracker) when is_map(tracker) do
    type = Map.get(tracker, "type", "none")
    ["type: #{type}"] ++ kv_lines(Map.get(tracker, "config", %{}))
  end

  defp tracker_lines(_), do: []

  defp merge_lines(nil), do: ["strategy: direct"]

  defp merge_lines(merge) when is_map(merge) do
    ["strategy: #{Map.get(merge, "strategy", "direct")}"] ++
      flag_line(merge, "auto_merge") ++
      flag_line(merge, "watch_pipeline") ++
      scalar_line(merge, "pr_title_format") ++
      scalar_line(merge, "watchdog_max_polls") ++
      kv_lines(Map.get(merge, "config", %{}))
  end

  defp merge_lines(_), do: []

  defp agent_lines(nil), do: []

  defp agent_lines(block) when is_map(block) do
    type =
      case Map.get(block, "type") do
        t when is_binary(t) -> t
        list when is_list(list) -> "pool: " <> Enum.join(list, ", ")
        _ -> nil
      end

    if(type, do: ["type: #{type}"], else: []) ++ kv_lines(Map.get(block, "config", %{}))
  end

  defp agent_lines(_), do: []

  defp routing_lines(nil), do: []
  defp routing_lines(routing) when is_map(routing) and map_size(routing) == 0, do: []

  defp routing_lines(routing) when is_map(routing) do
    policy = Map.get(routing, "policy")
    if policy, do: ["policy: #{policy}"], else: kv_lines(routing)
  end

  defp routing_lines(_), do: []

  # Review config spans both the `review` block (required/rounds) and the
  # `review_gate` block (max_rounds); summarise both under one heading.
  defp review_lines(config) do
    review = Map.get(config, "review", %{})
    gate = Map.get(config, "review_gate", %{})

    []
    |> append_if(is_map(review), fn -> flag_line(review, "required") end)
    |> append_if(is_map(review), fn -> scalar_line(review, "rounds") end)
    |> append_if(is_map(gate), fn -> scalar_line(gate, "max_rounds") end)
  end

  defp standing_order_lines(orders) when is_list(orders) and orders != [] do
    orders
    |> Enum.with_index(1)
    |> Enum.map(fn {o, i} -> "#{i}. #{order_text(o)}" end)
  end

  defp standing_order_lines(_), do: []

  defp secret_lines([]), do: []
  defp secret_lines(keys), do: Enum.map(keys, &"#{&1}  (value hidden)")

  defp order_text(order) when is_binary(order), do: order

  defp order_text(%{"title" => title} = order) do
    case order["detail"] do
      d when is_binary(d) and d != "" -> "#{title} — #{d}"
      _ -> title
    end
  end

  defp order_text(order), do: inspect(order)

  # Render a sub-map as `key: value` lines, hiding nothing but never inventing
  # secret values (configs only carry refs, not plaintext).
  defp kv_lines(map) when is_map(map) and map_size(map) > 0 do
    map
    |> Enum.sort_by(fn {k, _} -> k end)
    |> Enum.map(fn {k, v} -> "#{k}: #{scalarize(v)}" end)
  end

  defp kv_lines(_), do: []

  defp flag_line(map, key) do
    case Map.get(map, key) do
      nil -> []
      v -> ["#{key}: #{scalarize(v)}"]
    end
  end

  defp scalar_line(map, key) do
    case Map.get(map, key) do
      nil -> []
      v -> ["#{key}: #{scalarize(v)}"]
    end
  end

  defp scalarize(v) when is_binary(v) or is_integer(v) or is_boolean(v), do: to_string(v)
  defp scalarize(v), do: Value.pretty_inline(v)

  defp append_if(acc, false, _fun), do: acc
  defp append_if(acc, true, fun), do: acc ++ fun.()

  # ----- set/unset result ---------------------------------------------------

  def emit_workspace_config(updated, :json), do: Output.emit_json(updated["config"])

  def emit_workspace_config(updated, :text) do
    IO.puts("updated workspace " <> (updated["name"] || updated["id"]))
    IO.puts(Value.pretty(updated["config"] || %{}))
  end

  @doc false
  def diff(before, after_) do
    "  before: " <>
      Value.pretty_inline(before) <> "\n" <> "  after:  " <> Value.pretty_inline(after_)
  end
end
