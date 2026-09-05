defmodule Arbiter.StandingOrders do
  @moduledoc """
  Shared utilities for rendering standing orders consistently across the app.
  """

  @doc """
  Render a standing order element to canonical text (no display prefix).
  Handles both string and `{"title", "detail"}` map formats, normalizing them
  for consistent hashing. Used by `Arbiter.Worker.RunProvenance` for
  dispatch-time provenance hashing; `ArbiterCli.Cmd.Prime.standing_order_line/1`
  and `standing_orders_component.ex` still hold separate rendering copies
  pending a follow-up ticket to unify them.
  """
  @spec canonical_text(any()) :: String.t()
  def canonical_text(%{"title" => title} = order) when is_binary(title) do
    case order["detail"] do
      detail when is_binary(detail) and detail != "" -> "#{title} — #{detail}"
      _ -> title
    end
  end

  def canonical_text(text) when is_binary(text), do: text
  def canonical_text(other), do: inspect(other)
end
