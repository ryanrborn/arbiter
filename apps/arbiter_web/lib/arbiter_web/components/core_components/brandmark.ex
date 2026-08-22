defmodule ArbiterWeb.CoreComponents.Brandmark do
  @moduledoc """
  The Arbiter brandmark: `[/]` (icon) and `[arbiter]` (wordmark) forms of one
  identity — two brackets around either a rising slash or the lowercase word.

  Geometry is copied verbatim from the brandmark design handoff (bd-3vqk9m,
  `design_handoff_brandmark/assets/*.svg`) — do not re-derive coordinates
  from screenshots. Colors are read from the `--arb-live` / `--arb-live-ink`
  / `--arb-text-primary` design tokens so the mark themes with light/dark
  mode instead of baking in the dark-mode oklch values from the standalone
  asset files.
  """
  use Phoenix.Component

  @doc """
  Renders the Arbiter brandmark.

  ## Examples

      <.brandmark form="icon" size={32} tone="accent" />
      <.brandmark form="wordmark" size={140} tone="mono" />
  """
  attr(:form, :string,
    default: "icon",
    values: ~w(icon wordmark),
    doc: "icon renders [/], wordmark renders [arbiter]"
  )

  attr(:size, :integer,
    default: 32,
    doc:
      "icon form: rendered edge length in px (picks display vs. micro master). " <>
        "wordmark form: rendered width in px (picks stroke weight; below 120 falls back to icon)"
  )

  attr(:tone, :string, default: "accent", values: ~w(accent inverse mono tile))
  attr(:class, :string, default: nil)
  attr(:rest, :global)

  def brandmark(%{form: "wordmark"} = assigns), do: wordmark(assigns)
  def brandmark(assigns), do: icon(assigns)

  # Below the wordmark's 120px minimum width there is no room for the word —
  # the geometry table calls for icon-only, and picking that fallback is the
  # component's job, not the caller's (same as the icon's display/micro switch).
  defp wordmark(%{size: size} = assigns) when size < 120, do: icon(assigns)

  defp wordmark(assigns) do
    colors = tone_colors(assigns.tone)
    stroke = if assigns.size < 140, do: "5", else: "4"

    assigns =
      assigns
      |> assign(:colors, colors)
      |> assign(:stroke, stroke)
      |> assign(:height, round(assigns.size * 48 / 200))

    # The <text> node's whitespace is significant (it is the rendered word),
    # and the SVG "text" tag isn't in the HTML formatter's @inline_tags list,
    # so a normal ~H would get reformatted with an injected newline around
    # the child. The "noformat" sigil modifier exempts this template from
    # that reformatting instead.
    ~H"""
    <svg viewBox="0 0 200 48" width={@size} height={@height} role="img" aria-label="arbiter" class={@class} {@rest}><path d="M38 7 H28 V41 H38" fill="none" stroke={@colors.bracket} stroke-width={@stroke} stroke-linecap="square" /><path d="M162 7 H172 V41 H162" fill="none" stroke={@colors.bracket} stroke-width={@stroke} stroke-linecap="square" /><text x="100" y="33" text-anchor="middle" font-family="Geist Mono, ui-monospace, SFMono-Regular, Menlo, monospace" font-weight="500" font-size="26" letter-spacing="-0.035em" fill={@colors.content} style={content_style(@colors.content_opacity)}>arbiter</text></svg>
    """noformat
  end

  # Below 16px the brackets stop resolving — fall back to the tile+slash
  # favicon geometry regardless of requested tone.
  defp icon(%{size: size} = assigns) when size < 16 do
    colors = tone_colors(assigns.tone)
    assigns = assign(assigns, :colors, colors)

    ~H"""
    <svg
      viewBox="0 0 64 64"
      width={@size}
      height={@size}
      role="img"
      aria-label="Arbiter"
      class={@class}
      {@rest}
    >
      <rect
        :if={@colors.tile_bg}
        width="64"
        height="64"
        rx="8"
        fill={@colors.tile_bg}
      /><path
        d="M25 47 L39 17"
        fill="none"
        stroke={@colors.content}
        stroke-width="8"
        stroke-linecap="butt"
      />
    </svg>
    """
  end

  defp icon(%{tone: "tile"} = assigns) do
    colors = tone_colors(assigns.tone)
    assigns = assign(assigns, :colors, colors)

    ~H"""
    <svg
      viewBox="0 0 64 64"
      width={@size}
      height={@size}
      role="img"
      aria-label="Arbiter"
      class={@class}
      {@rest}
    >
      <rect
        width="64"
        height="64"
        rx="8"
        fill={@colors.tile_bg}
      /><path
        d="M25 17 H18 V47 H25"
        fill="none"
        stroke={@colors.bracket}
        stroke-width="6"
        stroke-linecap="square"
      /><path
        d="M39 17 H46 V47 H39"
        fill="none"
        stroke={@colors.bracket}
        stroke-width="6"
        stroke-linecap="square"
      /><path
        d="M28 43 L36 21"
        fill="none"
        stroke={@colors.bracket}
        stroke-width="6"
        stroke-linecap="butt"
      />
    </svg>
    """
  end

  defp icon(%{size: size} = assigns) when size < 32 do
    colors = tone_colors(assigns.tone)
    assigns = assign(assigns, :colors, colors)

    ~H"""
    <svg
      viewBox="0 0 64 64"
      width={@size}
      height={@size}
      role="img"
      aria-label="Arbiter"
      class={@class}
      {@rest}
    >
      <path
        d="M23 12 H14 V52 H23"
        fill="none"
        stroke={@colors.bracket}
        stroke-width="9"
        stroke-linecap="square"
      /><path
        d="M41 12 H50 V52 H41"
        fill="none"
        stroke={@colors.bracket}
        stroke-width="9"
        stroke-linecap="square"
      /><path
        d="M27 46 L37 18"
        fill="none"
        stroke={@colors.content}
        stroke-width="9"
        stroke-linecap="butt"
        style={content_style(@colors.content_opacity)}
      />
    </svg>
    """
  end

  defp icon(assigns) do
    colors = tone_colors(assigns.tone)
    assigns = assign(assigns, :colors, colors)

    ~H"""
    <svg
      viewBox="0 0 64 64"
      width={@size}
      height={@size}
      role="img"
      aria-label="Arbiter"
      class={@class}
      {@rest}
    >
      <path
        d="M22 10 H12 V54 H22"
        fill="none"
        stroke={@colors.bracket}
        stroke-width="7"
        stroke-linecap="square"
      /><path
        d="M42 10 H52 V54 H42"
        fill="none"
        stroke={@colors.bracket}
        stroke-width="7"
        stroke-linecap="square"
      /><path
        d="M27 46 L37 18"
        fill="none"
        stroke={@colors.content}
        stroke-width="7"
        stroke-linecap="butt"
        style={content_style(@colors.content_opacity)}
      />
    </svg>
    """
  end

  defp tone_colors("accent"),
    do: %{
      bracket: "var(--arb-live)",
      content: "var(--arb-text-primary)",
      content_opacity: nil,
      tile_bg: nil
    }

  defp tone_colors("inverse"),
    do: %{
      bracket: "var(--arb-live-ink)",
      content: "var(--arb-live-ink)",
      content_opacity: "0.55",
      tile_bg: nil
    }

  defp tone_colors("mono"),
    do: %{bracket: "currentColor", content: "currentColor", content_opacity: "0.5", tile_bg: nil}

  defp tone_colors("tile"),
    do: %{
      bracket: "var(--arb-live-ink)",
      content: "var(--arb-live-ink)",
      content_opacity: nil,
      tile_bg: "var(--arb-live)"
    }

  defp content_style(nil), do: nil
  defp content_style(opacity), do: "opacity: #{opacity}"
end
