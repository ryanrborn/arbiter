defmodule Arbiter.Quota.Overage do
  @moduledoc """
  Overage-spend accounting for `:continue`-mode dispatch (bd-7cd38f).

  When a workspace dispatches past the Anthropic plan cap (see
  `Arbiter.Quota.Gate.Continue`), we account the overage as the workspace's spend
  over the current 5h window, read straight from the token-cost ledger
  (`Arbiter.Usage.summarize/1`). This is the zero-migration v1 approach from the
  bd-3qcd8y design: a windowed sum of `cost_usd`, not a per-request tag.

  The window is `[reset_5h_at - 5h, now]` — i.e. spend since the current 5h
  window opened. When the snapshot carries no `reset_5h_at`, we fall back to the
  trailing 5 hours from now.
  """

  alias Arbiter.Quota.AnthropicQuota
  alias Arbiter.Tasks.Workspace
  alias Arbiter.Usage

  @five_hours_seconds 5 * 60 * 60

  @doc """
  The workspace's total spend (USD) over the current 5h window — the figure the
  overage indicator and alert threshold compare against. Returns `0.0` on any
  read error so accounting never disrupts dispatch.
  """
  @spec windowed_spend(Workspace.t() | nil, AnthropicQuota.t() | nil) :: float()
  def windowed_spend(workspace, quota) do
    ws_id = workspace && workspace.id

    if is_binary(ws_id) do
      since = window_start(quota)

      case Usage.summarize(by: :workspace, since: since, workspace_id: ws_id) do
        {:ok, rows} ->
          rows
          |> Enum.reduce(0.0, fn r, acc -> acc + (r.total_cost_usd || 0.0) end)

        _ ->
          0.0
      end
    else
      0.0
    end
  rescue
    _ -> 0.0
  end

  @doc """
  Start of the current 5h window as a `DateTime`. Derived from the snapshot's
  `reset_5h_at` (window opens 5h before it resets); falls back to `now - 5h`.
  """
  @spec window_start(AnthropicQuota.t() | nil) :: DateTime.t()
  def window_start(%AnthropicQuota{reset_5h_at: %DateTime{} = reset}) do
    DateTime.add(reset, -@five_hours_seconds, :second)
  end

  def window_start(_quota) do
    DateTime.add(DateTime.utc_now(), -@five_hours_seconds, :second)
  end
end
