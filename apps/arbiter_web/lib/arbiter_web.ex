defmodule ArbiterWeb do
  @moduledoc """
  The entrypoint for defining your web interface, such
  as controllers, components, channels, and so on.

  This can be used in your application as:

      use ArbiterWeb, :controller
      use ArbiterWeb, :html

  The definitions below will be executed for every controller,
  component, etc, so keep them short and clean, focused
  on imports, uses and aliases.

  Do NOT define functions inside the quoted expressions
  below. Instead, define additional modules and import
  those modules here.
  """

  def static_paths, do: ~w(assets fonts images favicon.svg robots.txt)

  def router do
    quote do
      use Phoenix.Router, helpers: false

      # Import common connection and controller functions to use in pipelines
      import Plug.Conn
      import Phoenix.Controller
      import Phoenix.LiveView.Router
    end
  end

  def channel do
    quote do
      use Phoenix.Channel
    end
  end

  def controller do
    quote do
      use Phoenix.Controller, formats: [:html, :json]

      use Gettext, backend: ArbiterWeb.Gettext

      import Plug.Conn

      unquote(verified_routes())
    end
  end

  def live_view do
    quote do
      use Phoenix.LiveView

      unquote(html_helpers())
    end
  end

  def live_component do
    quote do
      use Phoenix.LiveComponent

      unquote(html_helpers())
    end
  end

  def html do
    quote do
      use Phoenix.Component

      # Import convenience functions from controllers
      import Phoenix.Controller,
        only: [get_csrf_token: 0, view_module: 1, view_template: 1]

      # Include general helpers for rendering HTML
      unquote(html_helpers())
    end
  end

  defp html_helpers do
    quote do
      # Translation
      use Gettext, backend: ArbiterWeb.Gettext

      # HTML escaping functionality
      import Phoenix.HTML
      # Core UI components
      import ArbiterWeb.CoreComponents
      import ArbiterWeb.CoreComponents.Brandmark
      # Data-display primitives (tags, chips, meter, list/table)
      import ArbiterWeb.CoreComponents.Data
      # Design-handoff core primitives (Button, Icon, KeyHint, Toggle, Panel).
      # icon/1 and button/1 are excluded: CoreComponents already defines both,
      # and hundreds of existing call sites depend on that shape (e.g. icon/1
      # sized via a Tailwind `size-N` class, which the handoff Icon's explicit
      # inline width/height would silently override). Reach the handoff
      # versions as `ArbiterWeb.CoreComponents.Core.icon/1` /
      # `ArbiterWeb.CoreComponents.Core.button/1` until a follow-up ticket
      # migrates call sites and retires the old ones.
      import ArbiterWeb.CoreComponents.Core, except: [icon: 1, button: 1]
      # Shared list / index / detail building blocks
      import ArbiterWeb.ListComponents
      # Label pluralization (plural/1, cap_plural/1)
      import ArbiterWeb.Labels

      # Common modules used in templates
      alias Phoenix.LiveView.JS
      alias ArbiterWeb.Layouts

      # Routes generation with the ~p sigil
      unquote(verified_routes())
    end
  end

  def verified_routes do
    quote do
      use Phoenix.VerifiedRoutes,
        endpoint: ArbiterWeb.Endpoint,
        router: ArbiterWeb.Router,
        statics: ArbiterWeb.static_paths()
    end
  end

  @doc """
  When used, dispatch to the appropriate controller/view/etc.
  """
  defmacro __using__(which) when is_atom(which) do
    apply(__MODULE__, which, [])
  end
end
