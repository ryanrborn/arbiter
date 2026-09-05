defmodule Arbiter.StandingOrders do
  @moduledoc """
  Shared utilities for rendering standing orders consistently across the app.
  """

  @doc """
  Render a standing order element to canonical text (no display prefix).
  Handles both string and `{"title", "detail"}` map formats, normalizing them
  for consistent hashing and display. Used by dispatch-time provenance capture
  and coordinator display layers to ensure hashed text and displayed text
  cannot drift.
  """
  @spec canonical_text(String.t() | map() | any()) :: String.t()
  def canonical_text(%{"title" => title} = order) do
    case order["detail"] do
      detail when is_binary(detail) and detail != "" -> "#{title} — #{detail}"
      _ -> title
    end
  end

  def canonical_text(text) when is_binary(text), do: text
  def canonical_text(other), do: inspect(other)
end
