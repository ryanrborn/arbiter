defmodule ArbiterWeb.Layouts do
  @moduledoc """
  This module holds layouts and related functionality
  used by your application.
  """
  use ArbiterWeb, :html

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

  slot(:inner_block, required: true)

  def app(assigns) do
    ~H"""
    <header class="navbar bg-base-200 border-b border-base-300 px-4 sm:px-6 lg:px-8 min-h-12 py-1">
      <div class="flex-1">
        <.link navigate={~p"/"} class="flex items-center gap-2" aria-label="Arbiter">
          <img src="/images/arbiter-wordmark.png" alt="Arbiter" class="h-7 w-auto" />
        </.link>
      </div>
      <nav class="flex-none">
        <ul class="menu menu-horizontal gap-1 text-sm p-0">
          <li>
            <.link navigate={~p"/"} class={nav_class(@current_path, "/")}>
              Dashboard
            </.link>
          </li>
          <li>
            <.link navigate={~p"/beads"} class={nav_class(@current_path, "/beads")}>
              {cap_plural("issue")}
            </.link>
          </li>
          <li>
            <.link navigate={~p"/polecats"} class={nav_class(@current_path, "/polecats")}>
              {cap_plural("worker")}
            </.link>
          </li>
          <li>
            <.link navigate={~p"/merge_queue"} class={nav_class(@current_path, "/merge_queue")}>
              {cap_plural("merge queue")}
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
      <div class="flex-none ml-2">
        <.theme_toggle />
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
