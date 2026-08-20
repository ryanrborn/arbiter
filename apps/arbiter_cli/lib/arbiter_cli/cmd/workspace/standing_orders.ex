defmodule ArbiterCli.Cmd.Workspace.StandingOrders do
  @moduledoc """
  `arb workspace standing-order ls|add|rm` — workspace-global or
  repo-scoped standing orders (`config.standing_orders` /
  `repo_paths.<repo>.standing_orders`).
  """

  alias ArbiterCli.ArgParser
  alias ArbiterCli.Cmd.Workspace.Resolver
  alias ArbiterCli.{Client, Output}

  @spec run([String.t()], keyword()) :: :ok | no_return()
  def run(argv, opts) do
    {parsed, rest, mode} = ArgParser.parse(argv, switches: Keyword.fetch!(opts, :switches))
    workspace_opt = parsed[:workspace]
    # --repo is canonical; --rig is a deprecated alias kept for existing
    # scripts/muscle-memory (bd-1aw9dl). --repo wins if both are given.
    repo_opt = parsed[:repo] || parsed[:rig]

    case rest do
      ["ls"] ->
        ls(workspace_opt, repo_opt, mode)

      ["ls" | _] ->
        Output.die("workspace standing-order ls takes no positional arguments")

      ["add" | text] when text != [] ->
        add(workspace_opt, repo_opt, Enum.join(text, " "), mode)

      ["add" | _] ->
        Output.die("workspace standing-order add requires <text>")

      ["rm", target] ->
        rm(workspace_opt, repo_opt, target, mode)

      ["rm" | rest_args] when rest_args != [] ->
        # Allow an unquoted multi-word text match as a convenience.
        rm(workspace_opt, repo_opt, Enum.join(rest_args, " "), mode)

      ["rm" | _] ->
        Output.die("workspace standing-order rm requires an <index|text>")

      [] ->
        Output.die("workspace standing-order requires a subcommand", "verbs: ls, add, rm")

      [unknown | _] ->
        Output.die(
          "unknown workspace standing-order subcommand: #{unknown}",
          "verbs: ls, add, rm"
        )
    end
  end

  defp ls(workspace_opt, repo_opt, mode) do
    ws = Resolver.resolve_workspace!(workspace_opt)
    orders = current_standing_orders(ws, repo_opt)

    case mode do
      :json ->
        Output.emit_json(orders_json(orders, repo_opt))

      :text ->
        if orders == [] do
          IO.puts("(no standing orders#{repo_label(repo_opt)})")
        else
          IO.puts("Standing orders#{repo_label(repo_opt)} (#{length(orders)}):")

          orders
          |> Enum.with_index(1)
          |> Enum.each(fn {o, i} -> IO.puts("  #{i}. #{order_text(o)}") end)
        end
    end
  end

  defp add(workspace_opt, repo_opt, text, mode) do
    text = String.trim(text)
    if text == "", do: Output.die("workspace standing-order add: text must not be empty")

    ws = Resolver.resolve_workspace!(workspace_opt)
    require_registered_repo!(ws, repo_opt, "add")
    orders = current_standing_orders(ws, repo_opt)
    patch_standing_orders(ws, repo_opt, orders ++ [text], mode)
  end

  defp rm(workspace_opt, repo_opt, target, mode) do
    ws = Resolver.resolve_workspace!(workspace_opt)
    require_registered_repo!(ws, repo_opt, "rm")
    orders = current_standing_orders(ws, repo_opt)

    if orders == [] do
      Output.die(
        "workspace standing-order rm: this workspace has no standing orders#{repo_label(repo_opt)}"
      )
    end

    new_orders =
      case Integer.parse(target) do
        {n, ""} when n >= 1 and n <= length(orders) ->
          List.delete_at(orders, n - 1)

        {n, ""} when is_integer(n) ->
          Output.die(
            "workspace standing-order rm: index #{n} out of range (1..#{length(orders)})"
          )

        _ ->
          # Text match against the human-readable form of each order.
          case Enum.find_index(orders, &(order_text(&1) == target)) do
            nil ->
              Output.die("workspace standing-order rm: no order matching #{inspect(target)}")

            idx ->
              List.delete_at(orders, idx)
          end
      end

    patch_standing_orders(ws, repo_opt, new_orders, mode)
  end

  # Patches `config.standing_orders` wholesale (a list patch replaces the list,
  # never appends) while leaving sibling config keys untouched. With `--repo`,
  # patches just that repo's `standing_orders` sub-key under `repo_paths`,
  # preserving its `path`/`target_branch` siblings.
  defp patch_standing_orders(%{} = ws, nil, orders, mode) do
    payload = %{"patch" => %{"standing_orders" => orders}}
    do_patch_standing_orders(ws, nil, payload, mode)
  end

  defp patch_standing_orders(%{} = ws, repo, orders, mode) do
    {repo_paths_key, entry_key, entry} = Resolver.resolve_repo(ws, repo)

    entry_map =
      case entry do
        %{} = m -> m
        p when is_binary(p) -> %{"path" => p}
        _ -> %{}
      end

    new_entry = Map.put(entry_map, "standing_orders", orders)
    payload = %{"patch" => %{repo_paths_key => %{entry_key => new_entry}}}
    do_patch_standing_orders(ws, repo, payload, mode)
  end

  defp do_patch_standing_orders(%{} = ws, repo, payload, mode) do
    case Client.patch("/api/workspaces/" <> ws["id"] <> "/config", payload) do
      {:ok, updated} ->
        new_orders = current_standing_orders(updated, repo)

        case mode do
          :json ->
            Output.emit_json(orders_json(new_orders, repo))

          :text ->
            IO.puts("ok — #{length(new_orders)} standing order(s)")

            new_orders
            |> Enum.with_index(1)
            |> Enum.each(fn {o, i} -> IO.puts("  #{i}. #{order_text(o)}") end)
        end

      {:error, err} ->
        Output.die(err)
    end
  end

  defp orders_json(orders, nil), do: %{"standing_orders" => orders}

  # "repo" is canonical; "rig" is dual-emitted alongside it as a deprecated
  # legacy key so existing consumers keep working (bd-1aw9dl).
  defp orders_json(orders, repo),
    do: %{"standing_orders" => orders, "repo" => repo, "rig" => repo}

  defp repo_label(nil), do: ""
  defp repo_label(repo), do: " for repo #{repo}"

  defp current_standing_orders(ws, nil) do
    case get_in(ws, ["config", "standing_orders"]) do
      orders when is_list(orders) -> orders
      _ -> []
    end
  end

  defp current_standing_orders(ws, repo) do
    case Resolver.resolve_repo(ws, repo) do
      {_key, _entry_key, %{"standing_orders" => orders}} when is_list(orders) -> orders
      _ -> []
    end
  end

  # Requires `repo` (when given) to already be registered under
  # `repo_paths` — a standing order scoped to an unregistered repo
  # is almost always a typo, and silently creating a path-less repo entry would
  # hide it.
  defp require_registered_repo!(_ws, nil, _verb), do: :ok

  defp require_registered_repo!(ws, repo, verb) do
    case Resolver.resolve_repo(ws, repo) do
      {_key, _entry_key, nil} ->
        Output.die(
          "workspace standing-order #{verb}: no repo named #{inspect(repo)} registered",
          "register its path first: arb config set repo_paths.#{repo}.path <path>"
        )

      _ ->
        :ok
    end
  end

  # A standing order is either a short imperative string or a {title, detail}
  # object; render either to a single human-readable line (matches `arb prime`).
  defp order_text(order) when is_binary(order), do: order

  defp order_text(%{"title" => title} = order) do
    case order["detail"] do
      d when is_binary(d) and d != "" -> "#{title} — #{d}"
      _ -> title
    end
  end

  defp order_text(order), do: inspect(order)
end
