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

  attr(:quota, :any, default: nil, doc: "AnthropicQuota struct for the topbar widget, or nil")

  slot(:inner_block, required: true)

  def app(assigns) do
    ~H"""
    <header class="navbar bg-base-200 border-b border-base-300 px-4 sm:px-6 lg:px-8 min-h-12 py-1">
      <div class="flex-1">
        <.link navigate={~p"/"} class="flex items-center gap-2" aria-label="Arbiter">
          <img src="/images/arbiter-wordmark.png" alt="Arbiter" class="h-7 w-auto" />
        </.link>
      </div>

      <%!-- Desktop nav: lg and above --%>
      <nav class="flex max-lg:hidden flex-none">
        <ul class="menu menu-horizontal gap-1 text-sm p-0">
          <li>
            <.link navigate={~p"/"} class={nav_class(@current_path, "/")}>
              Dashboard
            </.link>
          </li>
          <li>
            <.link navigate={~p"/tasks"} class={nav_class(@current_path, "/tasks")}>
              {cap_plural("issue")}
            </.link>
          </li>
          <li>
            <.link navigate={~p"/workers"} class={nav_class(@current_path, "/workers")}>
              {cap_plural("worker")}
            </.link>
          </li>
          <li>
            <.link navigate={~p"/merge_queue"} class={nav_class(@current_path, "/merge_queue")}>
              {cap_plural("merge queue")}
            </.link>
          </li>
          <li>
            <.link navigate={~p"/workspaces"} class={nav_class(@current_path, "/workspaces")}>
              {cap_plural("workspace")}
            </.link>
          </li>
          <li>
            <.link navigate={~p"/audit"} class={nav_class(@current_path, "/audit")}>
              Audit log
            </.link>
          </li>
          <li>
            <.link navigate={~p"/usage"} class={nav_class(@current_path, "/usage")}>
              Usage
            </.link>
          </li>
          <li>
            <.link href={~p"/about"} class={nav_class(@current_path, "/about")}>
              About
            </.link>
          </li>
        </ul>
      </nav>
      <%!-- Quota widget: lg+ topbar; compact version also shown in mobile hamburger --%>
      <div
        class="flex max-lg:hidden flex-col gap-0.5 text-xs font-mono select-none ml-4 mr-2"
        title="Anthropic quota"
      >
        <div class="flex items-center gap-1.5">
          <span class="text-base-content/40 w-4 shrink-0">5h</span>
          <div class="relative w-24 h-1.5 rounded-full bg-base-content/10 overflow-hidden">
            <div
              :if={@quota && @quota.utilization_5h}
              class="absolute inset-y-0 left-0 rounded-full transition-all duration-500"
              style={"width: #{quota_pct(@quota.utilization_5h)}%; background-color: #{quota_color(@quota.utilization_5h, @quota.overage_status)};"}
            />
          </div>
          <span class="text-base-content/60 tabular-nums w-12">
            {quota_reset_label(@quota && @quota.reset_5h_at)}
          </span>
        </div>
        <div class="flex items-center gap-1.5">
          <span class="text-base-content/40 w-4 shrink-0">7d</span>
          <div class="relative w-24 h-1.5 rounded-full bg-base-content/10 overflow-hidden">
            <div
              :if={@quota && @quota.utilization_7d}
              class="absolute inset-y-0 left-0 rounded-full transition-all duration-500"
              style={"width: #{quota_pct(@quota.utilization_7d)}%; background-color: #{quota_color(@quota.utilization_7d, @quota.overage_status)};"}
            />
          </div>
          <span class="text-base-content/60 tabular-nums w-12">
            {quota_reset_label(@quota && @quota.reset_7d_at)}
          </span>
        </div>
      </div>

      <div class="flex-none ml-2 flex items-center gap-2">
        <.theme_toggle />

        <%!-- Mobile hamburger: below lg --%>
        <details id="mobile-nav" class="dropdown dropdown-end lg:hidden" phx-hook="DetailsPreserve">
          <summary class="btn btn-ghost btn-sm px-2" aria-label="Open navigation">
            <.icon name="hero-bars-3" class="size-5" />
          </summary>
          <ul class="dropdown-content menu bg-base-200 border border-base-300 rounded-box shadow-lg z-[100] w-48 p-2 gap-0.5 mt-1 text-sm">
            <li>
              <.link
                navigate={~p"/"}
                class={nav_class(@current_path, "/")}
                phx-click={JS.remove_attribute("open", to: "#mobile-nav")}
              >
                Dashboard
              </.link>
            </li>
            <li>
              <.link
                navigate={~p"/tasks"}
                class={nav_class(@current_path, "/tasks")}
                phx-click={JS.remove_attribute("open", to: "#mobile-nav")}
              >
                {cap_plural("issue")}
              </.link>
            </li>
            <li>
              <.link
                navigate={~p"/workers"}
                class={nav_class(@current_path, "/workers")}
                phx-click={JS.remove_attribute("open", to: "#mobile-nav")}
              >
                {cap_plural("worker")}
              </.link>
            </li>
            <li>
              <.link
                navigate={~p"/merge_queue"}
                class={nav_class(@current_path, "/merge_queue")}
                phx-click={JS.remove_attribute("open", to: "#mobile-nav")}
              >
                {cap_plural("merge queue")}
              </.link>
            </li>
            <li>
              <.link
                navigate={~p"/workspaces"}
                class={nav_class(@current_path, "/workspaces")}
                phx-click={JS.remove_attribute("open", to: "#mobile-nav")}
              >
                {cap_plural("workspace")}
              </.link>
            </li>
            <li>
              <.link
                navigate={~p"/audit"}
                class={nav_class(@current_path, "/audit")}
                phx-click={JS.remove_attribute("open", to: "#mobile-nav")}
              >
                Audit log
              </.link>
            </li>
            <li>
              <.link
                navigate={~p"/usage"}
                class={nav_class(@current_path, "/usage")}
                phx-click={JS.remove_attribute("open", to: "#mobile-nav")}
              >
                Usage
              </.link>
            </li>
            <li>
              <.link
                href={~p"/about"}
                class={nav_class(@current_path, "/about")}
                phx-click={JS.remove_attribute("open", to: "#mobile-nav")}
              >
                About
              </.link>
            </li>
            <li :if={@quota} class="border-t border-base-300 mt-0.5 pt-0.5 pointer-events-none">
              <div class="flex flex-col gap-0.5 px-2 py-1 text-xs font-mono select-none w-full items-stretch">
                <div class="flex items-center gap-1.5">
                  <span class="text-base-content/40 w-4 shrink-0">5h</span>
                  <div class="relative flex-1 h-1.5 rounded-full bg-base-content/10 overflow-hidden">
                    <div
                      :if={@quota.utilization_5h}
                      class="absolute inset-y-0 left-0 rounded-full transition-all duration-500"
                      style={"width: #{quota_pct(@quota.utilization_5h)}%; background-color: #{quota_color(@quota.utilization_5h, @quota.overage_status)};"}
                    />
                  </div>
                  <span class="text-base-content/60 tabular-nums w-12 text-right">
                    {quota_reset_label(@quota.reset_5h_at)}
                  </span>
                </div>
                <div class="flex items-center gap-1.5">
                  <span class="text-base-content/40 w-4 shrink-0">7d</span>
                  <div class="relative flex-1 h-1.5 rounded-full bg-base-content/10 overflow-hidden">
                    <div
                      :if={@quota.utilization_7d}
                      class="absolute inset-y-0 left-0 rounded-full transition-all duration-500"
                      style={"width: #{quota_pct(@quota.utilization_7d)}%; background-color: #{quota_color(@quota.utilization_7d, @quota.overage_status)};"}
                    />
                  </div>
                  <span class="text-base-content/60 tabular-nums w-12 text-right">
                    {quota_reset_label(@quota.reset_7d_at)}
                  </span>
                </div>
              </div>
            </li>
          </ul>
        </details>
      </div>
    </header>

    <main>
      {render_slot(@inner_block)}
    </main>

    <.flash_group flash={@flash} />
    """
  end

  # Matches the current path against a nav target. The dashboard ("/") only
  # matches exactly so it doesn't claim every page; other entries match the
  # path prefix so sub-pages (e.g. /workspace/:id/settings/...) still light up
  # the relevant top-level entry if we add one later.
  defp nav_class(current, "/"), do: nav_class_for(current == "/")

  defp nav_class(nil, _target), do: nav_class_for(false)

  defp nav_class(current, target) do
    nav_class_for(current == target or String.starts_with?(current, target <> "/"))
  end

  defp nav_class_for(true), do: "menu-active font-semibold"
  defp nav_class_for(false), do: ""

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
        <.icon name="hero-arrow-path" class="ml-1 size-3 motion-safe:animate-spin" />
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
        <.icon name="hero-arrow-path" class="ml-1 size-3 motion-safe:animate-spin" />
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
    <div class="card relative flex flex-row items-center border-2 border-base-300 bg-base-300 rounded-full">
      <div class="absolute w-1/3 h-full rounded-full border-1 border-base-200 bg-base-100 brightness-200 left-0 [[data-theme=light]_&]:left-1/3 [[data-theme=dark]_&]:left-2/3 transition-[left]" />

      <button
        class="flex p-2 cursor-pointer w-1/3"
        phx-click={JS.dispatch("phx:set-theme")}
        data-phx-theme="system"
      >
        <.icon name="hero-computer-desktop-micro" class="size-4 opacity-75 hover:opacity-100" />
      </button>

      <button
        class="flex p-2 cursor-pointer w-1/3"
        phx-click={JS.dispatch("phx:set-theme")}
        data-phx-theme="light"
      >
        <.icon name="hero-sun-micro" class="size-4 opacity-75 hover:opacity-100" />
      </button>

      <button
        class="flex p-2 cursor-pointer w-1/3"
        phx-click={JS.dispatch("phx:set-theme")}
        data-phx-theme="dark"
      >
        <.icon name="hero-moon-micro" class="size-4 opacity-75 hover:opacity-100" />
      </button>
    </div>
    """
  end
end
