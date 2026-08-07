defmodule ArbiterCli.Workspace do
  @moduledoc """
  Resolves the active workspace.

  Lookup order when `ARB_WORKSPACE` is unset:
    1. Workspace literally named `"default"`
    2. The sole workspace, if exactly one exists (an install that never had —
       or has since deleted — a workspace named `"default"` should still just
       work when there's no ambiguity about which workspace is "active")

  When `ARB_WORKSPACE` (or `--workspace`) is set, it is matched exactly by
  name or id and no fallback applies — an explicit selector that doesn't
  match is always an error.

  Returns `{:ok, workspace_map}` or `{:error, reason_string}`.
  """

  alias ArbiterCli.Client

  @doc """
  Pull a `--workspace <name>` / `--workspace=<name>` (or `-w`) flag out of an
  arg list, returning `{name_or_nil, remaining_argv}`.

  Workspace selection is a cross-cutting concern resolved centrally via
  `ARB_WORKSPACE` (see `resolve/0`), but the individual `arb issue *`
  subcommands each parse their own switches and would otherwise swallow a
  `--workspace` flag as an unknown boolean. Extracting it here — before the
  subcommand's own `OptionParser` runs — lets the flag override the active
  workspace exactly as the env var does, for every subcommand uniformly.

  The last occurrence wins. The returned name is applied by the caller via
  `System.put_env("ARB_WORKSPACE", name)`.
  """
  @spec take_flag([String.t()]) :: {String.t() | nil, [String.t()]}
  def take_flag(argv) when is_list(argv), do: take_flag(argv, nil, [])

  defp take_flag([], name, kept), do: {name, Enum.reverse(kept)}

  defp take_flag([flag, value | rest], _name, kept) when flag in ["--workspace", "-w"],
    do: take_flag(rest, value, kept)

  defp take_flag([flag], name, kept) when flag in ["--workspace", "-w"],
    # Dangling flag with no value — drop it; resolution falls back to the env.
    do: take_flag([], name, kept)

  defp take_flag(["--workspace=" <> value | rest], _name, kept),
    do: take_flag(rest, value, kept)

  defp take_flag(["-w=" <> value | rest], _name, kept),
    do: take_flag(rest, value, kept)

  defp take_flag([arg | rest], name, kept), do: take_flag(rest, name, [arg | kept])

  @spec resolve() :: {:ok, map()} | {:error, String.t()}
  def resolve do
    with {:ok, %{"data" => list}} <- Client.get("/api/workspaces") do
      resolve_from_list(list, System.get_env("ARB_WORKSPACE"))
    else
      {:error, %Client.Error{} = err} ->
        {:error, "could not load workspaces: #{err.message}"}
    end
  end

  # Explicit selector (env var or --workspace flag): must match exactly, no
  # fallback. Getting this wrong silently would route commands at the wrong
  # workspace.
  defp resolve_from_list(list, target) when is_binary(target) do
    case Enum.find(list, &(&1["name"] == target or &1["id"] == target)) do
      nil ->
        {:error,
         "no workspace named #{inspect(target)}. " <>
           "Set ARB_WORKSPACE or create one with `arb` (workspace creation is not yet a arb command — use the API)."}

      ws ->
        {:ok, ws}
    end
  end

  # No explicit selector: prefer a workspace literally named "default"; when
  # there isn't one but exactly one workspace exists, resolve to it — there's
  # no ambiguity to warn about. Only error when the choice is genuinely
  # ambiguous (multiple workspaces, none named "default").
  defp resolve_from_list(list, nil) do
    case Enum.find(list, &(&1["name"] == "default")) do
      nil ->
        case list do
          [only] ->
            {:ok, only}

          _ ->
            {:error,
             "no workspace named \"default\" and #{length(list)} workspaces exist — " <>
               "set ARB_WORKSPACE to pick one."}
        end

      ws ->
        {:ok, ws}
    end
  end

  @doc "Convenience: resolve and return just the id, or halt with a friendly error."
  @spec id_or_halt() :: String.t()
  def id_or_halt do
    case resolve() do
      {:ok, ws} -> ws["id"]
      {:error, msg} -> ArbiterCli.Output.die(msg)
    end
  end
end
