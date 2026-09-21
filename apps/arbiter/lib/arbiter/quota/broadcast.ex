defmodule Arbiter.Quota.Broadcast do
  @moduledoc """
  Fan a quota write out to the LiveView topics that care about it (P5).

  Quota rows are keyed by provider account since
  `docs/provider-account-design.md` §6, but the dashboard subscribes per
  workspace — a page is looking at a workspace, not an account. So one
  account-keyed write broadcasts to every workspace metered under that
  account, and three workspaces sharing one plan all update off the single
  row that was written, instead of three.

  `{:quota_updated, workspace_id, view}` keeps its existing shape, so
  `ArbiterWeb.LiveHooks` and the topbar are unchanged.
  """

  require Logger

  alias Arbiter.Accounts.Resolver

  @doc """
  Broadcast `view` on the `quota:<workspace_id>` topic of every workspace
  linked to `account_id`. Best-effort: a PubSub failure is logged, never
  raised into the write that triggered it.
  """
  @spec quota_updated(String.t() | nil, map()) :: :ok | :error
  def quota_updated(account_id, view) do
    account_id
    |> Resolver.workspace_ids()
    |> Enum.each(&broadcast(&1, view))
  rescue
    e ->
      Logger.debug("quota pubsub broadcast failed: #{inspect(e)}")
      :error
  end

  defp broadcast(workspace_id, view) do
    Phoenix.PubSub.broadcast(
      Arbiter.PubSub,
      "quota:#{workspace_id}",
      {:quota_updated, workspace_id, Map.put(view, :workspace_id, workspace_id)}
    )
  end
end
