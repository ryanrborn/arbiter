defmodule ArbiterWeb.CoreComponents.ProviderIcon do
  @moduledoc """
  Renders the logo of the AI provider (Claude / OpenAI / Antigravity) a worker is
  running on.

  This is the single place in the codebase that maps a provider string to a
  logo or a display name — every caller (the board's Running column, the
  workers index, worker detail) passes the plain string from
  `Arbiter.Worker.provider/1` and never branches on its value itself. When a
  fuller provider-adapter model lands, only `@providers` below has to change.
  """
  use Phoenix.Component

  @fallback_name "Unknown provider"

  # Sourcing and licensing notes:
  # - Claude: Official brand mark from Anthropic PBC. Sourced via Wikimedia Commons / simple-icons.
  #   Full-colour terracotta/coral (#d97757). Nominative use to identify the Claude provider.
  # - Codex / OpenAI: Official symbol mark from OpenAI. Sourced via Wikimedia Commons.
  #   Monochrome mark switching black on light theme, white on dark theme via `text-[var(--text-title)]`.
  #   Nominative use to identify the OpenAI/Codex provider.
  # - Antigravity (Gemini): Official "Icon - Full Color" PNG asset from Google's Antigravity
  #   press kit (antigravity.google/press), downloaded unmodified from
  #   antigravity.google/assets/image/brand/antigravity-icon__full-color.png and embedded
  #   as-is at priv/static/images/provider-icons/antigravity-icon-full-color.png.
  #   Nominative use to identify Google Antigravity.
  # - Ollama: Placeholder slot for future Ollama adapter (bd-942qbz).

  @providers %{
    "claude" => %{
      name: "Claude",
      view_box: "0 0 24 24"
    },
    "codex" => %{
      name: "Codex",
      view_box: "1.68 1.75 16.65 16.5"
    },
    "gemini" => %{
      name: "Antigravity",
      view_box: "0 0 112 112"
    },
    "ollama" => %{
      name: "Ollama",
      view_box: "0 0 24 24"
    }
  }

  @doc """
  Renders the provider's logo as an inline SVG.

  - Claude renders the official full-colour terracotta/coral mark (`#d97757`).
  - Gemini family renders the official Google Antigravity mark, labelled Antigravity.
  - OpenAI/Codex renders its official mark, switching black/white with the app theme
    (`text-[var(--text-title)]` which resolves to oklch 22% on light, 96% on dark).
  - Unknown or `nil` providers get a generic fallback icon.

  Every rendering carries a `title` and `aria-label` naming the provider (or "Unknown
  provider" for the fallback), so the icon is identifiable without relying on
  shape alone.
  """
  attr :provider, :string,
    default: nil,
    doc: ~s(e.g. "claude", "codex", "gemini", "ollama", or nil)

  attr :class, :any, default: "size-4"
  attr :rest, :global

  def provider_icon(%{provider: "claude"} = assigns) do
    # Claude / Anthropic: official terracotta/coral mark (#d97757)
    ~H"""
    <svg
      viewBox="0 0 24 24"
      fill="#d97757"
      role="img"
      aria-label="Claude"
      class={@class}
      {@rest}
    >
      <title>Claude</title>
      <path d="m4.7144 15.9555 4.7174-2.6471.079-.2307-.079-.1275h-.2307l-.7893-.0486-2.6956-.0729-2.3375-.0971-2.2646-.1214-.5707-.1215-.5343-.7042.0546-.3522.4797-.3218.686.0608 1.5179.1032 2.2767.1578 1.6514.0972 2.4468.255h.3886l.0546-.1579-.1336-.0971-.1032-.0972L6.973 9.8356l-2.55-1.6879-1.3356-.9714-.7225-.4918-.3643-.4614-.1578-1.0078.6557-.7225.8803.0607.2246.0607.8925.686 1.9064 1.4754 2.4893 1.8336.3643.3035.1457-.1032.0182-.0728-.164-.2733-1.3539-2.4467-1.445-2.4893-.6435-1.032-.17-.6194c-.0607-.255-.1032-.4674-.1032-.7285L6.287.1335 6.6997 0l.9957.1336.419.3642.6192 1.4147 1.0018 2.2282 1.5543 3.0296.4553.8985.2429.8318.091.255h.1579v-.1457l.1275-1.706.2368-2.0947.2307-2.6957.0789-.7589.3764-.9107.7468-.4918.5828.2793.4797.686-.0668.4433-.2853 1.8517-.5586 2.9021-.3643 1.9429h.2125l.2429-.2429.9835-1.3053 1.6514-2.0643.7286-.8196.85-.9046.5464-.4311h1.0321l.759 1.1293-.34 1.1657-1.0625 1.3478-.8804 1.1414-1.2628 1.7-.7893 1.36.0729.1093.1882-.0183 2.8535-.607 1.5421-.2794 1.8396-.3157.8318.3886.091.3946-.3278.8075-1.967.4857-2.3072.4614-3.4364.8136-.0425.0304.0486.0607 1.5482.1457.6618.0364h1.621l3.0175.2247.7892.522.4736.6376-.079.4857-1.2142.6193-1.6393-.3886-3.825-.9107-1.3113-.3279h-.1822v.1093l1.0929 1.0686 2.0035 1.8092 2.5075 2.3314.1275.5768-.3218.4554-.34-.0486-2.2039-1.6575-.85-.7468-1.9246-1.621h-.1275v.17l.4432.6496 2.3436 3.5214.1214 1.0807-.17.3521-.6071.2125-.6679-.1214-1.3721-1.9246L14.38 17.959l-1.1414-1.9428-.1397.079-.674 7.2552-.3156.3703-.7286.2793-.6071-.4614-.3218-.7468.3218-1.4753.3886-1.9246.3157-1.53.2853-1.9004.17-.6314-.0121-.0425-.1397.0182-1.4328 1.9672-2.1796 2.9446-1.7243 1.8456-.4128.164-.7164-.3704.0667-.6618.4008-.5889 2.386-3.0357 1.4389-1.882.929-1.0868-.0062-.1579h-.0546l-6.3385 4.1164-1.1293.1457-.4857-.4554.0608-.7467.2307-.2429 1.9064-1.3114Z" />
    </svg>
    """
  end

  def provider_icon(%{provider: "codex"} = assigns) do
    # OpenAI / Codex: official monochrome mark, theme-aware black on light, white on dark
    ~H"""
    <svg
      viewBox="1.68 1.75 16.65 16.5"
      fill="currentColor"
      role="img"
      aria-label="Codex"
      class={["text-[var(--text-title)]", @class]}
      {@rest}
    >
      <title>Codex</title>
      <path d="M11.248 18.25q-.825 0-1.568-.314a4.3 4.3 0 0 1-1.32-.874 4 4 0 0 1-1.304.214 4 4 0 0 1-2.046-.544 4.27 4.27 0 0 1-1.518-1.485 4 4 0 0 1-.56-2.095q0-.48.131-1.04A4.4 4.4 0 0 1 2.04 10.71a4.07 4.07 0 0 1 .017-3.4 4.2 4.2 0 0 1 1.056-1.418 3.8 3.8 0 0 1 1.6-.842 3.9 3.9 0 0 1 .76-1.683q.593-.759 1.451-1.188a4.04 4.04 0 0 1 1.832-.429q.825 0 1.567.313.742.314 1.32.875a4 4 0 0 1 1.304-.215q1.106 0 2.046.545a4.14 4.14 0 0 1 1.501 1.485q.578.941.578 2.095 0 .48-.132 1.04.66.61 1.023 1.419.363.792.363 1.666 0 .892-.38 1.717a4.3 4.3 0 0 1-1.072 1.435 3.8 3.8 0 0 1-1.584.825 3.8 3.8 0 0 1-.775 1.683 4.06 4.06 0 0 1-1.436 1.188 4.04 4.04 0 0 1-1.832.429m-4.076-2.062q.825 0 1.435-.347l3.103-1.782a.36.36 0 0 0 .164-.313v-1.42L7.881 14.62a.67.67 0 0 1-.726 0l-3.118-1.798a.5.5 0 0 1-.017.115v.198q0 .841.396 1.551.413.693 1.139 1.089a3.2 3.2 0 0 0 1.617.412m.165-2.69a.4.4 0 0 0 .181.05q.083 0 .165-.05l1.238-.71-3.977-2.31a.7.7 0 0 1-.363-.643v-3.58q-.825.362-1.32 1.122a2.9 2.9 0 0 0-.495 1.65q0 .809.413 1.55.412.743 1.072 1.123zm3.91 3.663q.875 0 1.585-.396a2.96 2.96 0 0 0 1.534-2.64v-3.564a.32.32 0 0 0-.165-.297l-1.254-.726v4.604a.7.7 0 0 1-.363.643l-3.119 1.799a3 3 0 0 0 1.783.577m.627-6.039V8.878L10.01 7.822 8.129 8.878v2.244l1.881 1.056zM7.057 5.859a.7.7 0 0 1 .363-.644l3.119-1.798a3 3 0 0 0-1.782-.578q-.874 0-1.584.396A2.96 2.96 0 0 0 6.05 4.324a3.07 3.07 0 0 0-.396 1.551v3.547q0 .199.165.314l1.237.726zm8.383 7.887q.825-.364 1.303-1.123.495-.758.495-1.65a3.15 3.15 0 0 0-.412-1.55q-.413-.743-1.073-1.123l-3.086-1.782q-.099-.065-.181-.049a.3.3 0 0 0-.165.05l-1.238.692 3.993 2.327a.6.6 0 0 1 .264.264.64.64 0 0 1 .1.363zm-3.317-8.382a.63.63 0 0 1 .726 0l3.135 1.831v-.297q0-.792-.396-1.501a2.86 2.86 0 0 0-1.105-1.155q-.71-.43-1.65-.43-.825 0-1.436.347L8.294 5.941a.36.36 0 0 0-.165.314v1.418z" />
    </svg>
    """
  end

  def provider_icon(%{provider: "gemini"} = assigns) do
    # Google Antigravity: official "Icon - Full Color" PNG, embedded unmodified
    # (see sourcing note above). The single full-colour gradient reads on both
    # light and dark card surfaces, so no separate theme variant is needed.
    ~H"""
    <svg viewBox="0 0 112 112" role="img" aria-label="Antigravity" class={@class} {@rest}>
      <title>Antigravity</title>
      <image
        href="/images/provider-icons/antigravity-icon-full-color.png"
        width="112"
        height="112"
      />
    </svg>
    """
  end

  def provider_icon(%{provider: "ollama"} = assigns) do
    # Ollama slot (bd-942qbz)
    ~H"""
    <svg
      viewBox="0 0 24 24"
      fill="none"
      stroke="currentColor"
      stroke-width="1.5"
      stroke-linecap="round"
      stroke-linejoin="round"
      role="img"
      aria-label="Ollama"
      class={@class}
      {@rest}
    >
      <title>Ollama</title>
      <circle cx="12" cy="12" r="8.5" />
      <path d="M12 8v4" />
      <path d="M12 16h.01" />
    </svg>
    """
  end

  def provider_icon(assigns) do
    # Fallback for nil or unknown provider
    assigns = assign_new(assigns, :fallback_name, fn -> @fallback_name end)

    ~H"""
    <svg
      viewBox="0 0 24 24"
      fill="none"
      stroke="currentColor"
      stroke-width="1.5"
      stroke-linecap="round"
      stroke-linejoin="round"
      role="img"
      aria-label={@fallback_name}
      class={@class}
      {@rest}
    >
      <title>{@fallback_name}</title>
      <circle cx="12" cy="12" r="8.5" />
      <path d="M12 15.5v.01" />
      <path d="M9.7 9.3a2.3 2.3 0 1 1 3.4 2c-.7.5-1.1 1-1.1 2" />
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
