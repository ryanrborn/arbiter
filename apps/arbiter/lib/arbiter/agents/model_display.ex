defmodule Arbiter.Agents.ModelDisplay do
  @moduledoc """
  Maps concrete model ids to short, human-friendly display names for
  dashboards and CLI output.

  Model ids are long and version-stamped (`claude-sonnet-4-6`,
  `gemini-2.5-pro`); operators scanning a list of running workers want the
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
  | `gemini-3.*-flash*` (agy) | Flash  |
  | `gemini-3.*-pro*` (agy)   | Pro    |
  | `gpt-oss*` (agy)    | GPT-OSS |

  The agy fork's own tier map (bd-d2yut8) resolves to Gemini 3.x ids with an
  effort suffix (`gemini-3.8-flash-low`, `gemini-3.1-pro-high`, …) — a fixed
  prefix can't cover every version agy might catalogue next, so those two
  rows match by family word (`flash`/`pro`) rather than a literal id.
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
      nil -> agy_family(model) || model
    end
  end

  # agy's own catalogue (bd-d2yut8): Gemini 3.x ids carry an effort suffix
  # (`-low`/`-medium`/`-high`) after an arbitrary version number
  # (`gemini-3.8-flash-low`, `gemini-3.1-pro-high`, …), so these match by
  # family word rather than a fixed prefix; `claude-*-4-6*` ids already hit
  # `@rules` above (same families as native Claude), so no rule needed here.
  defp agy_family("gemini-3" <> _ = model) do
    cond do
      String.contains?(model, "flash") -> "Flash"
      String.contains?(model, "pro") -> "Pro"
      true -> nil
    end
  end

  defp agy_family("gpt-oss" <> _), do: "GPT-OSS"
  defp agy_family(_model), do: nil
end
