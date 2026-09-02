defmodule ArbiterCli.Cmd.Workspace.Secrets do
  @moduledoc """
  `arb workspace secret ls|set|rm` — encrypted-at-rest workspace secrets.
  Values are write-only: reads only ever return key names.
  """

  alias ArbiterCli.ArgParser
  alias ArbiterCli.{Client, Output}
  alias ArbiterCli.Cmd.Workspace.Resolver

  @spec run([String.t()], keyword()) :: :ok | no_return()
  def run(argv, opts) do
    {parsed, rest, mode} = ArgParser.parse(argv, switches: Keyword.fetch!(opts, :switches))
    workspace_opt = parsed[:workspace]

    case rest do
      ["set", key, value] ->
        set(workspace_opt, key, value, mode)

      ["set", key | vrest] when vrest != [] ->
        set(workspace_opt, key, Enum.join(vrest, " "), mode)

      ["set" | _] ->
        Output.die("workspace secret set requires <key> <value>")

      ["rm", key] ->
        rm(workspace_opt, key, mode)

      ["rm" | _] ->
        Output.die("workspace secret rm requires exactly one <key>")

      ["ls"] ->
        ls(workspace_opt, mode)

      ["ls" | _] ->
        Output.die("workspace secret ls takes no positional arguments")

      [] ->
        Output.die("workspace secret requires a subcommand", "verbs: set, rm, ls")

      [unknown | _] ->
        Output.die("unknown workspace secret subcommand: #{unknown}", "verbs: set, rm, ls")
    end
  end

  defp set(workspace_opt, key, value, mode) do
    if String.trim(key) == "", do: Output.die("workspace secret set: key must not be empty")
    patch_secrets(workspace_opt, %{key => value}, mode)
  end

  defp rm(workspace_opt, key, mode) do
    ws = Resolver.resolve_workspace!(workspace_opt)

    unless key in (ws["secret_keys"] || []) do
      Output.die("workspace secret rm: no secret named #{inspect(key)}")
    end

    # A null value tells the server's merge-patch to remove the key.
    patch_secrets(ws, %{key => nil}, mode)
  end

  defp ls(workspace_opt, mode) do
    ws = Resolver.resolve_workspace!(workspace_opt)
    keys = ws["secret_keys"] || []

    case mode do
      :json ->
        Output.emit_json(%{"secret_keys" => keys})

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
  defp patch_secrets(%{} = ws, secrets, mode) when is_map_key(ws, "id") do
    case Client.patch("/api/workspaces/" <> ws["id"], %{"secrets" => secrets}) do
      {:ok, updated} -> emit_result(updated, mode)
      {:error, err} -> Output.die(err)
    end
  end

  defp patch_secrets(workspace_opt, secrets, mode) do
    patch_secrets(Resolver.resolve_workspace!(workspace_opt), secrets, mode)
  end

  defp emit_result(ws, :json),
    do: Output.emit_json(%{"secret_keys" => ws["secret_keys"] || []})

  defp emit_result(ws, :text) do
    keys = ws["secret_keys"] || []
    IO.puts("ok — secrets: #{if keys == [], do: "(none)", else: Enum.join(keys, ", ")}")
  end
end
