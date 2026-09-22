defmodule ArbiterWeb.Api.QuotaController do
  @moduledoc """
  `GET /api/quota` — the current quota state for a workspace. Backs `arb quota`.

  Resolves the target workspace from `?workspace=<id|name>`, falling back to
  the installation default.

  A pure DB read (bd-ajh7bd): every provider is read from its persisted quota
  table, kept fresh by the background `Arbiter.Quota.CloudProbe` polling
  (`/api/oauth/usage` for Anthropic, and similar endpoints for Codex / Gemini
  CLI / Antigravity). No provider is fetched live here, so a dashboard/CLI load
  carries no request-time latency or rate-limit exposure.

  `quotas` carries every tracked provider as the uniform view shape (each
  including its own `provider` field) — `claude` is kept as a top-level key too
  for `arb quota` and other existing consumers of the pre-multi-provider shape.

  Since P5 (`docs/provider-account-design.md` §6) the quota rows are keyed by
  **provider account**, and `?workspace=` is the lookup shorthand that
  resolves to that workspace's account (one per provider). Each `quotas`
  entry therefore carries `account` and `workspaces` — the account it belongs
  to and every workspace metered under it, with that workspace's own spend —
  and `workspace` names the workspace the lookup came in through.
  `workspace_id` is retained for one release as its deprecated alias. The
  top-level `account` / `workspaces` describe the headline (Claude) provider.

    * `claude` — the latest polled snapshot, including per-model weekly breakdowns
      and overage spend; `null` before the first poll.
    * `codex` — the persisted OpenAI session/weekly-window snapshot (a distinct
      shape, so it stays a top-level key rather than joining `quotas`); `null`
      (with a `codex_message`) until the Codex probe has stored one.
    * `gemini` / `antigravity` — the persisted per-model Cloud Code Assist
      snapshot (bd-57ukgb), each `null` until that CLI is authenticated and
      probed on this host.
  """

  use ArbiterWeb, :controller

  alias Arbiter.Quota
  alias Arbiter.Tasks.Workspace
  require Ash.Query

  def show(conn, params) do
    case resolve_workspace_id(Map.get(params, "workspace")) do
      {:ok, ws_id} ->
        accounts = Quota.account_ids(ws_id)
        codex = Quota.Codex.serialize_latest(accounts["codex"])

        # Every `account`/`workspaces` block below carries each workspace's
        # 30-day spend, and each of those is a full ledger scan that does not
        # vary by provider. One request = one scan per workspace, so the memo
        # is built here and threaded through all three calls.
        spend = Quota.spend_cache(accounts)

        # §6's `--json` gains `account` / `workspaces` at the top level. They
        # describe the **headline** (Claude) provider's account; a workspace
        # may sit on a different account per provider, so each `quotas` entry
        # carries its own pair too.
        headline = Quota.account_fields(accounts["claude"], "claude", spend)

        render(conn, :show,
          workspace_id: ws_id,
          workspace: workspace_view(ws_id),
          requested_workspace: Map.get(params, "workspace"),
          claude:
            Quota.serialize(accounts["claude"], "claude",
              workspace_id: ws_id,
              spend_cache: spend
            ),
          quotas: Quota.list_serialized_for_workspace(ws_id, spend_cache: spend),
          account: headline[:account],
          workspaces: headline[:workspaces],
          codex: codex,
          codex_message: Quota.codex_absence_message(codex),
          # bd-1fpjgx: mirrors `claude`'s `credentials_expired` field, sourced
          # the same way — live off `CredentialWatchdog`'s held state, not the
          # persisted snapshot, so it reflects the free 401-streak / agy-exit
          # signal `CloudProbe` now feeds it for these adapters too.
          codex_credentials_expired:
            Arbiter.Agents.CredentialWatchdog.expired?(Arbiter.Agents.Codex),
          gemini: Quota.CloudCode.serialize_latest(accounts["gemini_cli"], "gemini_cli"),
          antigravity: Quota.CloudCode.serialize_latest(accounts["antigravity"], "antigravity"),
          gemini_credentials_expired:
            Arbiter.Agents.CredentialWatchdog.expired?(Arbiter.Agents.Gemini)
        )

      {:error, message} ->
        conn
        |> put_status(:not_found)
        |> json(%{error: %{type: "not_found", message: message}})
    end
  end

  defp workspace_view(ws_id) do
    case Ash.get(Workspace, ws_id) do
      {:ok, %Workspace{id: id, name: name}} -> %{id: id, name: name}
      _ -> %{id: ws_id, name: nil}
    end
  rescue
    _ -> %{id: ws_id, name: nil}
  end

  # Explicit `?workspace=` (id, then name) wins; else the installation default.
  defp resolve_workspace_id(nil), do: default_workspace_id()
  defp resolve_workspace_id(""), do: default_workspace_id()

  defp resolve_workspace_id(ref) do
    with :error <- by_id(ref), :error <- by_name(ref) do
      {:error, "workspace #{inspect(ref)} not found"}
    end
  end

  defp by_id(ref) do
    case Ash.get(Workspace, ref) do
      {:ok, %Workspace{id: id}} -> {:ok, id}
      _ -> :error
    end
  rescue
    _ -> :error
  end

  defp by_name(ref) do
    case Workspace |> Ash.Query.filter(name == ^ref) |> Ash.read_one() do
      {:ok, %Workspace{id: id}} -> {:ok, id}
      _ -> :error
    end
  rescue
    _ -> :error
  end

  defp default_workspace_id do
    case Quota.default_workspace_id() do
      {:ok, id} -> {:ok, id}
      {:error, :no_workspaces} -> {:error, "no workspaces exist on this installation"}
      {:error, _} -> {:error, "no default workspace; pass ?workspace=<id>"}
    end
  end
end
