defmodule ArbiterWeb.Labels do
  @moduledoc """
  Pluralization for vernacular labels, so headers read naturally regardless of
  the configured vocabulary ("refinery" → "refineries", "watch" → "watches",
  "bead" → "beads"). A naive `label <> "s"` breaks on trailing -y and sibilant
  endings, which a polished surface shouldn't show.

  Imported into every view via `ArbiterWeb` so index/detail/dashboard pages
  share one implementation.
  """

  @doc "Pluralize a label, preserving its configured case (for inline prose)."
  @spec plural(String.t()) :: String.t()
  def plural(word) when is_binary(word) do
    cond do
      String.ends_with?(word, ~w(s x z ch sh)) -> word <> "es"
      Regex.match?(~r/[^aeiou]y$/u, word) -> String.replace_suffix(word, "y", "ies")
      true -> word <> "s"
    end
  end

  @doc "Capitalize then pluralize a label (for section headers / stat titles)."
  @spec cap_plural(String.t()) :: String.t()
  def cap_plural(word) when is_binary(word), do: word |> String.capitalize() |> plural()
end
