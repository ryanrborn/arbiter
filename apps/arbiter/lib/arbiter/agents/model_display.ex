defmodule Arbiter.Agents.ModelDisplay do
  @moduledoc """
  Maps concrete model ids to short, human-friendly display names for
  dashboards and CLI output.

  Model ids are long and version-stamped (`claude-sonnet-4-6`,
  `gemini-2.5-pro`); operators scanning a list of running acolytes want the
  family name. `short/1` collapses an id to its family ("Sonnet", "Pro", …) by
  prefix match, falling back to the raw id when nothing matches so an
  unrecognised model still renders something useful rather than blank.

  | Prefix              | Short  |
  |---------------------|--------|
  | `claude-opus*`      | Opus   |
  | `claude-sonnet*`    | Sonnet |
  | `claude-haiku*`     | Haiku  |
  | `gemini-2.5-pro*`   | Pro    |
  | `gemini-2.5-flash*` | Flash  |
  """

  # Ordered prefix → short-name rules. First match wins, so more specific
  # prefixes (e.g. flash-lite still maps to Flash) need no special-casing.
  @rules [
    {"claude-opus", "Opus"},
    {"claude-sonnet", "Sonnet"},
    {"claude-haiku", "Haiku"},
    # Tier aliases the routing layer uses before the concrete id is known.
    {"opus", "Opus"},
    {"sonnet", "Sonnet"},
    {"haiku", "Haiku"},
    {"gemini-2.5-pro", "Pro"},
    {"gemini-2.5-flash", "Flash"}
  ]

  @doc """
  Short display name for a model id. Returns the raw value for unrecognised
  models, and `nil` for `nil`.

      iex> Arbiter.Agents.ModelDisplay.short("gemini-2.5-pro")
      "Pro"
      iex> Arbiter.Agents.ModelDisplay.short("claude-sonnet-4-6")
      "Sonnet"
      iex> Arbiter.Agents.ModelDisplay.short("something-else")
      "something-else"
  """
  @spec short(String.t() | nil) :: String.t() | nil
  def short(nil), do: nil

  def short(model) when is_binary(model) do
    case Enum.find(@rules, fn {prefix, _} -> String.starts_with?(model, prefix) end) do
      {_prefix, name} -> name
      nil -> model
    end
  end
end
