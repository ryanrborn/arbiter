defmodule ArbiterWeb.Layouts do
  @moduledoc """
  This module holds layouts and related functionality
  used by your application.
  """
  use ArbiterWeb, :html
  import ArbiterWeb.QuotaHelpers

  # Embed all files in layouts/* within this module.
  # The default root.html.heex file contains the HTML
  # skeleton of your application, namely HTML headers
  # and other static content.
  embed_templates("layouts/*")

  @doc """
  Renders your app layout.

  This function is typically invoked from every template,
  and it often contains your application menu, sidebar,
  or similar.

  ## Examples

      <Layouts.app flash={@flash}>
        <h1>Content</h1>
      </Layouts.app>

  """
  attr(:flash, :map, required: true, doc: "the map of flash messages")

  attr(:current_path, :string,
    default: nil,
    doc: "request path of the current page, used to highlight the active nav link"
  )

  attr(:quotas, :list, default: [], doc: "One AnthropicQuota struct per tracked provider")

  attr(:quota_on_exhaustion, :any,
    default: nil,
    doc: "override for tests/specimens; real callers omit it and get the installation default"
  )

  slot(:inner_block, required: true)

  def app(assigns) do
    # Fetched once per render rather than threaded through every LiveView's
    # `<Layouts.app quotas={@quotas} ...>` call site (bd-l4epbc) — the quota
    # bars only ever show the installation default workspace regardless of
    # which page is open, same as `@quotas` itself (`ArbiterWeb.LiveHooks`).
    # `quota_on_exhaustion` defaults to nil via `attr/3`, so a real caller
    # (who never passes it) still falls through to the DB-backed default;
    # only tests/specimens override it to dodge the DB round-trip.
    assigns =
      assign(
        assigns,
        :quota_on_exhaustion,
        assigns.quota_on_exhaustion || Arbiter.Quota.default_workspace_on_exhaustion()
      )

    assigns = assign(assigns, :nav_items, nav_items())

    ~H"""
    <.top_nav items={@nav_items} current_path={@current_path}>
      <:right>
        <div :for={quota <- @quotas} class="max-lg:hidden flex flex-col gap-[3px]">
          <span class="text-[9.5px] uppercase tracking-[0.08em] leading-none text-[var(--text-label)] font-[family-name:var(--font-mono)]">
            {quota_provider_label(quota.provider)}
          </span>
          <div class="flex items-center gap-3">
            <.quota_bar
              provider={quota.provider}
              show_label={false}
              window="5h"
              utilization={quota.utilization_5h}
              reset_at={quota.reset_5h_at}
              overage_status={quota.overage_status}
              representative_claim={quota.representative_claim}
              on_exhaustion={@quota_on_exhaustion}
            />
            <.quota_bar
              provider={quota.provider}
              show_label={false}
              window="7d"
              utilization={quota.utilization_7d}
              reset_at={quota.reset_7d_at}
              overage_status={quota.overage_status}
              representative_claim={quota.representative_claim}
              on_exhaustion={@quota_on_exhaustion}
            />
          </div>
        </div>
        <ArbiterWeb.CoreComponents.Feedback.live_badge id="appshell-live" />
        <.theme_toggle />
      </:right>
    </.top_nav>

    <main>
      {render_slot(@inner_block)}
    </main>

    <.toast_group flash={@flash} />
    """
  end

  # Board/Issues/Workers/Merge queue/Workspaces/Skills/Loop/Usage/Audit — the
  # global-chrome nav order (bd-53pfbg). Dashboard renamed to Board, "Loop
  # queue" to Loop, "Audit log" to Audit; About drops out of the nav (it's
  # still reachable at ~p"/about" directly).
  defp nav_items do
    [
      %{label: "Board", href: ~p"/"},
      %{label: cap_plural("issue"), href: ~p"/tasks"},
      %{label: cap_plural("worker"), href: ~p"/workers"},
      %{label: cap_plural("merge queue"), href: ~p"/merge_queue"},
      %{label: cap_plural("workspace"), href: ~p"/workspaces"},
      %{label: cap_plural("skill"), href: ~p"/skills"},
      %{label: "Loop", href: ~p"/loop"},
      %{label: "Usage", href: ~p"/usage"},
      %{label: "Audit", href: ~p"/audit"}
    ]
  end

  @doc """
  Shows the flash group with standard titles and content.

  ## Examples

      <.flash_group flash={@flash} />
  """
  attr(:flash, :map, required: true, doc: "the map of flash messages")
  attr(:id, :string, default: "flash-group", doc: "the optional id of flash container")

  def flash_group(assigns) do
    ~H"""
    <div id={@id} aria-live="polite">
      <.flash kind={:info} flash={@flash} />
      <.flash kind={:error} flash={@flash} />

      <.flash
        id="client-error"
        kind={:error}
        title={gettext("We can't find the internet")}
        phx-disconnected={show(".phx-client-error #client-error") |> JS.remove_attribute("hidden")}
        phx-connected={hide("#client-error") |> JS.set_attribute({"hidden", ""})}
        hidden
      >
        {gettext("Attempting to reconnect")}
        <ArbiterWeb.CoreComponents.icon
          name="hero-arrow-path"
          class="ml-1 size-3 motion-safe:animate-spin"
        />
      </.flash>

      <.flash
        id="server-error"
        kind={:error}
        title={gettext("Something went wrong!")}
        phx-disconnected={show(".phx-server-error #server-error") |> JS.remove_attribute("hidden")}
        phx-connected={hide("#server-error") |> JS.set_attribute({"hidden", ""})}
        hidden
      >
        {gettext("Attempting to reconnect")}
        <ArbiterWeb.CoreComponents.icon
          name="hero-arrow-path"
          class="ml-1 size-3 motion-safe:animate-spin"
        />
      </.flash>
    </div>
    """
  end

  @doc """
  Provides dark vs light theme toggle based on themes defined in app.css.

  See <head> in root.html.heex which applies the theme before page load.
  """
  def theme_toggle(assigns) do
    ~H"""
    <div class="relative flex items-center rounded-[var(--radius-pill)] border border-solid border-[var(--border-default)] bg-[var(--surface-chrome)]">
      <div class="absolute inset-y-[2px] left-[2px] w-[calc(33.333%-2px)] rounded-[var(--radius-pill)] bg-[var(--surface-card)] transition-[left] duration-200 [[data-theme=light]_&]:left-[calc(33.333%+1px)] [[data-theme=dark]_&]:left-[calc(66.666%-1px)]" />

      <button
        class="relative flex p-[7px] cursor-pointer w-1/3 justify-center"
        phx-click={JS.dispatch("phx:set-theme")}
        data-phx-theme="system"
        aria-label="Match system theme"
      >
        <ArbiterWeb.CoreComponents.Core.icon
          name="hero-computer-desktop-micro"
          color="var(--text-secondary)"
        />
      </button>

      <button
        class="relative flex p-[7px] cursor-pointer w-1/3 justify-center"
        phx-click={JS.dispatch("phx:set-theme")}
        data-phx-theme="light"
        aria-label="Light theme"
      >
        <ArbiterWeb.CoreComponents.Core.icon name="hero-sun-micro" color="var(--text-secondary)" />
      </button>

      <button
        class="relative flex p-[7px] cursor-pointer w-1/3 justify-center"
        phx-click={JS.dispatch("phx:set-theme")}
        data-phx-theme="dark"
        aria-label="Dark theme"
      >
        <ArbiterWeb.CoreComponents.Core.icon name="hero-moon-micro" color="var(--text-secondary)" />
      </button>
    </div>
    """
  end
end
