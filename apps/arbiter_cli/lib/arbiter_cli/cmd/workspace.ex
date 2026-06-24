defmodule ArbiterCli.Cmd.Workspace do
  @moduledoc """
  `arb workspace <verb>` — inspect the configured workspaces and manage secrets.

      arb workspace list                       all workspaces (name, prefix, id)
      arb workspace show <id>                  one workspace's detail incl. config

      arb workspace secret ls                  names of the configured secrets
      arb workspace secret set <key> <value>   store/overwrite an encrypted secret
      arb workspace secret rm <key>            remove an encrypted secret

  Secrets are stored encrypted at rest (ash_cloak) and are never returned in
  plaintext — only their key names are shown. Reference one from workspace
  config with `credentials_ref: "secret:<key>"`, e.g.

      arb config set tracker.config.credentials_ref secret:tracker_token
      arb workspace secret set tracker_token sct_rw_...

  All verbs accept `--workspace <name>` to target a workspace other than the
  default. Reads from `GET /api/workspaces`; writes via `PATCH /api/workspaces/:id`.
  """

  alias ArbiterCli.{Client, Output, Workspace}

  @switches [workspace: :string, json: :boolean]

  def run(argv) do
    case argv do
      ["list" | rest] ->
        list(rest)

      ["ls" | rest] ->
        list(rest)

      ["show" | rest] ->
        show(rest)

      ["secret" | rest] ->
        secret(rest)

      ["--help" | _] ->
        IO.puts(@moduledoc)

      ["-h" | _] ->
        IO.puts(@moduledoc)

      [] ->
        Output.die("workspace requires a subcommand", "verbs: list, show, secret")

      [unknown | _] ->
        Output.die("unknown workspace subcommand: #{unknown}", "verbs: list, show, secret")
    end
  end

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
