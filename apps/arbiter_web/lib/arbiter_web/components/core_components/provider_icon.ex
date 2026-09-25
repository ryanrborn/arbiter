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
  # - Antigravity (Gemini): Official brand mark for Google Antigravity from Google LLC.
  #   Sourced via Wikimedia Commons (Google Antigravity Logo.svg).
  #   Full-colour Google gradient on blue arch. Nominative use to identify Google Antigravity.
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
    # Google Antigravity: official full-colour mark
    ~H"""
    <svg
      viewBox="0 0 112 112"
      fill="none"
      role="img"
      aria-label="Antigravity"
      class={@class}
      {@rest}
    >
      <title>Antigravity</title>
      <defs>
        <filter
          id="ag-f0"
          x="2.49348"
          y="-26.5423"
          width="69.0899"
          height="61.2525"
          filterUnits="userSpaceOnUse"
          color-interpolation-filters="sRGB"
        >
          <feFlood flood-opacity="0" result="BackgroundImageFix" />
          <feBlend mode="normal" in="SourceGraphic" in2="BackgroundImageFix" result="shape" />
          <feGaussianBlur stdDeviation="3.89034" />
        </filter>
        <filter
          id="ag-f1"
          x="28.7524"
          y="-32.0333"
          width="135.477"
          height="134.313"
          filterUnits="userSpaceOnUse"
          color-interpolation-filters="sRGB"
        >
          <feFlood flood-opacity="0" result="BackgroundImageFix" />
          <feBlend mode="normal" in="SourceGraphic" in2="BackgroundImageFix" result="shape" />
          <feGaussianBlur stdDeviation="18.8078" />
        </filter>
        <filter
          id="ag-f2"
          x="-62.2884"
          y="-21.9253"
          width="142.637"
          height="127.18"
          filterUnits="userSpaceOnUse"
          color-interpolation-filters="sRGB"
        >
          <feFlood flood-opacity="0" result="BackgroundImageFix" />
          <feBlend mode="normal" in="SourceGraphic" in2="BackgroundImageFix" result="shape" />
          <feGaussianBlur stdDeviation="15.9884" />
        </filter>
        <filter
          id="ag-f3"
          x="-62.2884"
          y="-21.9253"
          width="142.637"
          height="127.18"
          filterUnits="userSpaceOnUse"
          color-interpolation-filters="sRGB"
        >
          <feFlood flood-opacity="0" result="BackgroundImageFix" />
          <feBlend mode="normal" in="SourceGraphic" in2="BackgroundImageFix" result="shape" />
          <feGaussianBlur stdDeviation="15.9884" />
        </filter>
        <filter
          id="ag-f4"
          x="-52.5697"
          y="-20.8346"
          width="127.582"
          height="127.452"
          filterUnits="userSpaceOnUse"
          color-interpolation-filters="sRGB"
        >
          <feFlood flood-opacity="0" result="BackgroundImageFix" />
          <feBlend mode="normal" in="SourceGraphic" in2="BackgroundImageFix" result="shape" />
          <feGaussianBlur stdDeviation="15.9884" />
        </filter>
        <filter
          id="ag-f5"
          x="17.3619"
          y="45.4646"
          width="116.786"
          height="118.715"
          filterUnits="userSpaceOnUse"
          color-interpolation-filters="sRGB"
        >
          <feFlood flood-opacity="0" result="BackgroundImageFix" />
          <feBlend mode="normal" in="SourceGraphic" in2="BackgroundImageFix" result="shape" />
          <feGaussianBlur stdDeviation="15.1937" />
        </filter>
        <filter
          id="ag-f6"
          x="-7.44765"
          y="-60.4737"
          width="125.303"
          height="122.858"
          filterUnits="userSpaceOnUse"
          color-interpolation-filters="sRGB"
        >
          <feFlood flood-opacity="0" result="BackgroundImageFix" />
          <feBlend mode="normal" in="SourceGraphic" in2="BackgroundImageFix" result="shape" />
          <feGaussianBlur stdDeviation="13.7698" />
        </filter>
        <filter
          id="ag-f7"
          x="-27.7086"
          y="13.3597"
          width="157.119"
          height="162.029"
          filterUnits="userSpaceOnUse"
          color-interpolation-filters="sRGB"
        >
          <feFlood flood-opacity="0" result="BackgroundImageFix" />
          <feBlend mode="normal" in="SourceGraphic" in2="BackgroundImageFix" result="shape" />
          <feGaussianBlur stdDeviation="12.297" />
        </filter>
        <filter
          id="ag-f8"
          x="50.4638"
          y="16.981"
          width="87.3973"
          height="83.7738"
          filterUnits="userSpaceOnUse"
          color-interpolation-filters="sRGB"
        >
          <feFlood flood-opacity="0" result="BackgroundImageFix" />
          <feBlend mode="normal" in="SourceGraphic" in2="BackgroundImageFix" result="shape" />
          <feGaussianBlur stdDeviation="11.0036" />
        </filter>
        <filter
          id="ag-f9"
          x="34.2604"
          y="-28.457"
          width="116.701"
          height="104.506"
          filterUnits="userSpaceOnUse"
          color-interpolation-filters="sRGB"
        >
          <feFlood flood-opacity="0" result="BackgroundImageFix" />
          <feBlend mode="normal" in="SourceGraphic" in2="BackgroundImageFix" result="shape" />
          <feGaussianBlur stdDeviation="9.29385" />
        </filter>
        <filter
          id="ag-f10"
          x="-15.1522"
          y="-15.9493"
          width="77.2941"
          height="91.076"
          filterUnits="userSpaceOnUse"
          color-interpolation-filters="sRGB"
        >
          <feFlood flood-opacity="0" result="BackgroundImageFix" />
          <feBlend mode="normal" in="SourceGraphic" in2="BackgroundImageFix" result="shape" />
          <feGaussianBlur stdDeviation="11.5027" />
        </filter>
        <mask
          id="ag-mask"
          maskUnits="userSpaceOnUse"
          x="13"
          y="18"
          width="85"
          height="78"
          style="mask-type: alpha;"
        >
          <path
            d="M89.6992 93.695C94.3659 97.195 101.366 94.8617 94.9492 88.445C75.6992 69.7783 79.7825 18.445 55.8659 18.445C31.9492 18.445 36.0325 69.7783 16.7825 88.445C9.78251 95.445 17.3658 97.195 22.0325 93.695C40.1159 81.445 38.9492 59.8617 55.8659 59.8617C72.7825 59.8617 71.6159 81.445 89.6992 93.695Z"
            fill="black"
          />
        </mask>
      </defs>
      <path
        d="M89.6992 93.695C94.3659 97.195 101.366 94.8617 94.9492 88.445C75.6992 69.7783 79.7825 18.445 55.8659 18.445C31.9492 18.445 36.0325 69.7783 16.7825 88.445C9.78251 95.445 17.3658 97.195 22.0325 93.695C40.1159 81.445 38.9492 59.8617 55.8659 59.8617C72.7825 59.8617 71.6159 81.445 89.6992 93.695Z"
        fill="#3186FF"
      />
      <g mask="url(#ag-mask)">
        <g filter="url(#ag-f0)">
          <ellipse
            cx="22.7873"
            cy="26.8098"
            rx="22.7873"
            ry="26.8098"
            transform="matrix(-0.112784 0.99362 -0.99362 -0.112781 66.2473 -15.5344)"
            fill="#FFE432"
          />
        </g>
        <g filter="url(#ag-f1)">
          <ellipse
            cx="96.491"
            cy="35.1231"
            rx="29.5007"
            ry="30.1492"
            transform="rotate(76.9243 96.491 35.1231)"
            fill="#FC413D"
          />
        </g>
        <g filter="url(#ag-f2)">
          <ellipse
            cx="9.02988"
            cy="41.6647"
            rx="30.832"
            ry="39.9417"
            transform="rotate(74.1257 9.02988 41.6647)"
            fill="#00B95C"
          />
        </g>
        <g filter="url(#ag-f3)">
          <ellipse
            cx="9.02988"
            cy="41.6647"
            rx="30.832"
            ry="39.9417"
            transform="rotate(74.1257 9.02988 41.6647)"
            fill="#00B95C"
          />
        </g>
        <g filter="url(#ag-f4)">
          <ellipse
            cx="11.2212"
            cy="42.8915"
            rx="30.22"
            ry="33.2695"
            transform="rotate(45.6065 11.2212 42.8915)"
            fill="#00B95C"
          />
        </g>
        <g filter="url(#ag-f5)">
          <ellipse
            cx="75.7546"
            cy="104.822"
            rx="29.0177"
            ry="27.943"
            transform="rotate(76.9243 75.7546 104.822)"
            fill="#3186FF"
          />
        </g>
        <g filter="url(#ag-f6)">
          <ellipse
            cx="33.5661"
            cy="35.4043"
            rx="33.5661"
            ry="35.4043"
            transform="matrix(-0.409539 0.912293 -0.912294 -0.409537 101.25 -15.1674)"
            fill="#FBBC04"
          />
        </g>
        <g filter="url(#ag-f7)">
          <path
            d="M2.56802 149.695C-15.8116 142.48 15.5987 83.1163 23.4093 63.2203C31.22 43.3244 52.4514 33.0447 70.831 40.26C89.2107 47.4753 110.996 87.2162 103.185 107.112C95.3742 127.008 20.9477 156.91 2.56802 149.695Z"
            fill="#3186FF"
          />
        </g>
        <g filter="url(#ag-f8)">
          <path
            d="M113.934 75.8079C109.013 81.5509 96.1724 78.6224 85.253 69.2667C74.3335 59.911 69.4704 47.6711 74.391 41.928C79.3116 36.185 92.1525 39.1136 103.072 48.4692C113.991 57.8249 118.855 70.0648 113.934 75.8079Z"
            fill="#749BFF"
          />
        </g>
        <g filter="url(#ag-f9)">
          <ellipse
            cx="92.611"
            cy="23.7962"
            rx="44.2411"
            ry="27.5016"
            transform="rotate(34.0763 92.611 23.7962)"
            fill="#FC413D"
          />
        </g>
        <g filter="url(#ag-f10)">
          <ellipse
            cx="23.4949"
            cy="29.5887"
            rx="23.7071"
            ry="13.7869"
            transform="rotate(112.516 23.4949 29.5887)"
            fill="#FFEE48"
          />
        </g>
      </g>
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
