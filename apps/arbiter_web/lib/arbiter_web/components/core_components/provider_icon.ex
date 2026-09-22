defmodule ArbiterWeb.CoreComponents.ProviderIcon do
  @moduledoc """
  Renders the logo of the AI provider (Claude / Codex / Gemini) a worker is
  running on.

  This is the single place in the codebase that maps a provider string to a
  logo or a display name — every caller (the board's Running column, the
  workers index, worker detail) passes the plain string from
  `Arbiter.Worker.provider/1` and never branches on its value itself. When a
  fuller provider-adapter model lands, only `@providers` below has to change.
  """
  use Phoenix.Component

  @fallback_name "Unknown provider"

  @providers %{
    "claude" => %{
      name: "Claude",
      svg: ~S"""
      <path d="M12 4 L14.2 10.2 L20.5 10.9 L15.6 15 L17.1 21.2 L12 17.7 L6.9 21.2 L8.4 15 L3.5 10.9 L9.8 10.2 Z" />
      """
    },
    "codex" => %{
      name: "Codex",
      svg: ~S"""
      <path d="M8.5 6.5 L3 12 L8.5 17.5" />
      <path d="M15.5 6.5 L21 12 L15.5 17.5" />
      <path d="M13.5 4 L10.5 20" />
      """
    },
    "gemini" => %{
      name: "Gemini",
      svg: ~S"""
      <path d="M12 3 C12 8 16 12 21 12 C16 12 12 16 12 21 C12 16 8 12 3 12 C8 12 12 8 12 3 Z" />
      """
    }
  }

  @fallback_svg ~S"""
  <circle cx="12" cy="12" r="8.5" />
  <path d="M12 15.5v.01" />
  <path d="M9.7 9.3a2.3 2.3 0 1 1 3.4 2c-.7.5-1.1 1-1.1 2" />
  """

  @doc """
  Renders the provider's logo as an inline SVG, sized and colored via
  `currentColor` so it reads legibly in both light and dark themes.

  Unknown or `nil` providers get a generic fallback icon. Every rendering
  carries a `title` and `aria-label` naming the provider (or "Unknown
  provider" for the fallback), so the icon is identifiable without relying on
  shape alone.
  """
  attr :provider, :string, default: nil, doc: ~s(e.g. "claude", "codex", "gemini", or nil)
  attr :class, :any, default: "size-4"
  attr :rest, :global

  def provider_icon(assigns) do
    info = Map.get(@providers, assigns.provider)

    assigns =
      assigns
      |> assign(:name, (info && info.name) || @fallback_name)
      |> assign(:body, (info && info.svg) || @fallback_svg)

    ~H"""
    <svg
      viewBox="0 0 24 24"
      fill="none"
      stroke="currentColor"
      stroke-width="1.5"
      stroke-linecap="round"
      stroke-linejoin="round"
      role="img"
      aria-label={@name}
      class={@class}
      {@rest}
    >
      <title>{@name}</title>
      {Phoenix.HTML.raw(@body)}
    </svg>
    """
  end

  @doc "The provider's display name (or the fallback), for callers that need the text form."
  @spec display_name(String.t() | nil) :: String.t()
  def display_name(provider) do
    case Map.get(@providers, provider) do
      %{name: name} -> name
      nil -> @fallback_name
    end
  end

  @doc false
  @spec __known_providers__() :: [String.t()]
  def __known_providers__, do: Map.keys(@providers)
end
