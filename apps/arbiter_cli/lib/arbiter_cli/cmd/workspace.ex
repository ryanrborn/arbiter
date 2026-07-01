defmodule ArbiterCli.Cmd.Workspace do
  @moduledoc """
  `arb workspace <verb>` — create and inspect workspaces, manage secrets, and
  edit standing orders.

      arb workspace list                       all workspaces (name, prefix, id)
      arb workspace show <id>                  one workspace's detail incl. config
      arb workspace create <name>              create a new workspace
        [--prefix bd] [--tracker-type none] [--merger-strategy direct]
        [--description "..."]

      arb workspace standing-order ls          list this workspace's standing orders
      arb workspace standing-order add <text>  append one standing order
      arb workspace standing-order rm <index|text>
                                               remove one standing order (1-based
                                               index, or exact text match)

      arb workspace secret ls                  names of the configured secrets
      arb workspace secret set <key> <value>   store/overwrite an encrypted secret
      arb workspace secret rm <key>            remove an encrypted secret

  Secrets are stored encrypted at rest (ash_cloak) and are never returned in
  plaintext — only their key names are shown. Reference one from workspace
  config with `credentials_ref: "secret:<key>"`, e.g.

      arb config set tracker.config.credentials_ref secret:tracker_token
      arb workspace secret set tracker_token sct_rw_...

  Standing orders live in `config.standing_orders` — a list of short imperative
  strings surfaced high in every worker's `arb prime` briefing. The `add`/`rm`
  verbs edit individual entries via `PATCH /api/workspaces/:id/config` so the
  rest of the config is never clobbered.

  All verbs accept `--workspace <name>` to target a workspace other than the
  default. Reads from `GET /api/workspaces`; writes via `PATCH /api/workspaces/:id`.
  """

  alias ArbiterCli.{Client, Output, Workspace}

  # Mirrors Arbiter.Tasks.Workspace.valid_tracker_types/0 and
  # valid_merger_strategies/0 for friendly client-side errors on `create`. The
  # server's ValidateConfig remains the source of truth.
  @valid_tracker_types ~w(none jira shortcut linear github gitlab)
  @valid_merger_strategies ~w(direct gitlab github)

  @switches [
    workspace: :string,
    json: :boolean,
    prefix: :string,
    description: :string,
    tracker_type: :string,
    merger_strategy: :string
  ]

  def run(argv) do
    case argv do
      ["list" | rest] ->
        list(rest)

      ["ls" | rest] ->
        list(rest)

      ["show" | rest] ->
        show(rest)

      ["create" | rest] ->
        create(rest)

      ["standing-order" | rest] ->
        standing_order(rest)

      ["secret" | rest] ->
        secret(rest)

      ["--help" | _] ->
        IO.puts(@moduledoc)

      ["-h" | _] ->
        IO.puts(@moduledoc)

      [] ->
        Output.die("workspace requires a subcommand", verbs())

      [unknown | _] ->
        Output.die("unknown workspace subcommand: #{unknown}", verbs())
    end
  end

  defp verbs, do: "verbs: list, show, create, standing-order, secret"

  defp list(argv) do
    mode = Output.mode(argv)

    case Client.get("/api/workspaces") do
      {:ok, %{"data" => list}} -> emit_list(list, mode)
      {:ok, _} -> emit_list([], mode)
      {:error, err} -> Output.die(err)
    end
  end

  defp show(argv) do
    mode = Output.mode(argv)
    rest = Output.drop_json(argv)

    id =
      case rest do
        [id] -> id
        [] -> Output.die("workspace show requires a workspace id or name")
        _ -> Output.die("workspace show takes exactly one argument: the workspace id")
      end

    case Client.get("/api/workspaces/" <> id) do
      {:ok, ws} -> Output.emit_workspace(ws, mode)
      {:error, err} -> Output.die(err)
    end
  end

  # ----- create ----------------------------------------------------------

  defp create(argv) do
    {opts, rest, _invalid} = OptionParser.parse(argv, switches: @switches)
    mode = if opts[:json], do: :json, else: :text

    name =
      case rest do
        [name] -> name
        [] -> Output.die("workspace create requires a name", "arb workspace create <name>")
        _ -> Output.die("workspace create takes exactly one positional argument: the name")
      end

    if String.trim(name) == "", do: Output.die("workspace create: name must not be empty")

    prefix = opts[:prefix] || "bd"
    tracker_type = opts[:tracker_type] || "none"
    merger_strategy = opts[:merger_strategy] || "direct"

    unless tracker_type in @valid_tracker_types do
      Output.die(
        "workspace create: invalid --tracker-type #{inspect(tracker_type)}",
        "one of: #{Enum.join(@valid_tracker_types, ", ")}"
      )
    end

    unless merger_strategy in @valid_merger_strategies do
      Output.die(
        "workspace create: invalid --merger-strategy #{inspect(merger_strategy)}",
        "one of: #{Enum.join(@valid_merger_strategies, ", ")}"
      )
    end

    config = %{
      "tracker" => %{"type" => tracker_type},
      "merge" => %{"strategy" => merger_strategy}
    }

    body =
      %{"name" => name, "prefix" => prefix, "config" => config}
      |> maybe_put("description", opts[:description])

    case Client.post("/api/workspaces", body) do
      {:ok, ws} ->
        case mode do
          :json -> IO.puts(Jason.encode!(ws))
          :text -> IO.puts("created workspace #{ws["name"]} (#{ws["id"]}) prefix=#{ws["prefix"]}")
        end

      {:error, err} ->
        Output.die(err)
    end
  end

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, _key, ""), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  # ----- standing-order add / rm / ls ------------------------------------

  defp standing_order(argv) do
    {opts, rest, _invalid} = OptionParser.parse(argv, switches: @switches)
    mode = if opts[:json], do: :json, else: :text
    workspace_opt = opts[:workspace]

    case rest do
      ["ls"] ->
        standing_order_ls(workspace_opt, mode)

      ["ls" | _] ->
        Output.die("workspace standing-order ls takes no positional arguments")

      ["add" | text] when text != [] ->
        standing_order_add(workspace_opt, Enum.join(text, " "), mode)

      ["add" | _] ->
        Output.die("workspace standing-order add requires <text>")

      ["rm", target] ->
        standing_order_rm(workspace_opt, target, mode)

      ["rm" | rest_args] when rest_args != [] ->
        # Allow an unquoted multi-word text match as a convenience.
        standing_order_rm(workspace_opt, Enum.join(rest_args, " "), mode)

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

  defp standing_order_ls(workspace_opt, mode) do
    ws = resolve_workspace!(workspace_opt)
    orders = current_standing_orders(ws)

    case mode do
      :json ->
        IO.puts(Jason.encode!(%{"standing_orders" => orders}))

      :text ->
        if orders == [] do
          IO.puts("(no standing orders)")
        else
          IO.puts("Standing orders (#{length(orders)}):")

          orders
          |> Enum.with_index(1)
          |> Enum.each(fn {o, i} -> IO.puts("  #{i}. #{order_text(o)}") end)
        end
    end
  end

  defp standing_order_add(workspace_opt, text, mode) do
    text = String.trim(text)
    if text == "", do: Output.die("workspace standing-order add: text must not be empty")

    ws = resolve_workspace!(workspace_opt)
    orders = current_standing_orders(ws)
    patch_standing_orders(ws, orders ++ [text], mode)
  end

  defp standing_order_rm(workspace_opt, target, mode) do
    ws = resolve_workspace!(workspace_opt)
    orders = current_standing_orders(ws)

    if orders == [] do
      Output.die("workspace standing-order rm: this workspace has no standing orders")
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

    patch_standing_orders(ws, new_orders, mode)
  end

  # Patches `config.standing_orders` wholesale (a list patch replaces the list,
  # never appends) while leaving sibling config keys untouched.
  defp patch_standing_orders(%{} = ws, orders, mode) do
    payload = %{"patch" => %{"standing_orders" => orders}}

    case Client.patch("/api/workspaces/" <> ws["id"] <> "/config", payload) do
      {:ok, updated} ->
        new_orders = current_standing_orders(updated)

        case mode do
          :json ->
            IO.puts(Jason.encode!(%{"standing_orders" => new_orders}))

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

  defp current_standing_orders(ws) do
    case get_in(ws, ["config", "standing_orders"]) do
      orders when is_list(orders) -> orders
      _ -> []
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

  # ----- secret set / rm / ls --------------------------------------------

  defp secret(argv) do
    {opts, rest, _invalid} = OptionParser.parse(argv, switches: @switches)
    mode = if opts[:json], do: :json, else: :text
    workspace_opt = opts[:workspace]

    case rest do
      ["set", key, value] ->
        secret_set(workspace_opt, key, value, mode)

      ["set", key | vrest] when vrest != [] ->
        secret_set(workspace_opt, key, Enum.join(vrest, " "), mode)

      ["set" | _] ->
        Output.die("workspace secret set requires <key> <value>")

      ["rm", key] ->
        secret_rm(workspace_opt, key, mode)

      ["rm" | _] ->
        Output.die("workspace secret rm requires exactly one <key>")

      ["ls"] ->
        secret_ls(workspace_opt, mode)

      ["ls" | _] ->
        Output.die("workspace secret ls takes no positional arguments")

      [] ->
        Output.die("workspace secret requires a subcommand", "verbs: set, rm, ls")

      [unknown | _] ->
        Output.die("unknown workspace secret subcommand: #{unknown}", "verbs: set, rm, ls")
    end
  end

  defp secret_set(workspace_opt, key, value, mode) do
    if String.trim(key) == "", do: Output.die("workspace secret set: key must not be empty")
    patch_secrets(workspace_opt, %{key => value}, "set secret #{key}", mode)
  end

  defp secret_rm(workspace_opt, key, mode) do
    ws = resolve_workspace!(workspace_opt)

    unless key in (ws["secret_keys"] || []) do
      Output.die("workspace secret rm: no secret named #{inspect(key)}")
    end

    # A null value tells the server's merge-patch to remove the key.
    patch_secrets(ws, %{key => nil}, "remove secret #{key}", mode)
  end

  defp secret_ls(workspace_opt, mode) do
    ws = resolve_workspace!(workspace_opt)
    keys = ws["secret_keys"] || []

    case mode do
      :json ->
        IO.puts(Jason.encode!(%{"secret_keys" => keys}))

      :text ->
        if keys == [] do
          IO.puts("(no secrets)")
        else
          IO.puts("Secrets (#{length(keys)}):")
          Enum.each(keys, &IO.puts("  #{&1}"))
        end
    end
  end

  # Merge-patch the secrets map on the workspace via the update endpoint. The
  # response never echoes secret values — re-fetch the (names-only) workspace.
  defp patch_secrets(%{} = ws, secrets, _label, mode) when is_map_key(ws, "id") do
    case Client.patch("/api/workspaces/" <> ws["id"], %{"secrets" => secrets}) do
      {:ok, updated} -> emit_secret_result(updated, mode)
      {:error, err} -> Output.die(err)
    end
  end

  defp patch_secrets(workspace_opt, secrets, label, mode) do
    patch_secrets(resolve_workspace!(workspace_opt), secrets, label, mode)
  end

  defp emit_secret_result(ws, :json),
    do: IO.puts(Jason.encode!(%{"secret_keys" => ws["secret_keys"] || []}))

  defp emit_secret_result(ws, :text) do
    keys = ws["secret_keys"] || []
    IO.puts("ok — secrets: #{if keys == [], do: "(none)", else: Enum.join(keys, ", ")}")
  end

  defp resolve_workspace!(%{} = ws) when is_map_key(ws, "id"), do: ws

  defp resolve_workspace!(nil) do
    case Workspace.resolve() do
      {:ok, ws} -> ws
      {:error, msg} -> Output.die(msg)
    end
  end

  defp resolve_workspace!(name) when is_binary(name) do
    case Client.get("/api/workspaces") do
      {:ok, %{"data" => list}} ->
        case Enum.find(list, &(&1["name"] == name)) do
          nil -> Output.die("no workspace named #{inspect(name)}")
          ws -> ws
        end

      {:error, err} ->
        Output.die(err)
    end
  end

  defp emit_list(list, :json), do: IO.puts(Jason.encode!(%{"data" => list}))

  defp emit_list([], :text) do
    IO.puts("(no workspaces)")
  end

  defp emit_list(list, :text) do
    IO.puts("Workspaces (#{length(list)}):")

    Enum.each(list, fn ws ->
      IO.puts("  #{ws["name"]}  prefix=#{ws["prefix"]}  id=#{ws["id"]}")
    end)
  end
end
