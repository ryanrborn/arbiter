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
      # Core UI components. icon/1 and button/1 are excluded: the
      # design-handoff Core module below now owns the unqualified
      # `<.icon>`/`<.button>` names. Any remaining call site that needs the
      # old daisyUI-flavored shape (e.g. icon/1 sized via a Tailwind
      # `size-N` class, or button/1's `<.link>`-when-`href`/`navigate`
      # behavior) reaches it fully qualified as
      # `ArbiterWeb.CoreComponents.icon/1` / `ArbiterWeb.CoreComponents.button/1`.
      import ArbiterWeb.CoreComponents, except: [icon: 1, button: 1]
      import ArbiterWeb.CoreComponents.Brandmark
      # Data-display primitives (tags, chips, meter, list/table)
      import ArbiterWeb.CoreComponents.Data
      # Design-handoff core primitives (Button, Icon, KeyHint, Toggle, Panel).
      import ArbiterWeb.CoreComponents.Core
      # Design-handoff navigation primitives (TopNav, FilterTabs,
      # SegmentedControl, Pager, SeeAllLink, BackLink). filter_tabs/1,
      # pager/1, see_all_link/1, and back_link/1 are excluded: ListComponents
      # already defines all four with a different attr contract (route-fn
      # `tab_path`/`page_path` callbacks instead of a plain `href`/`event`),
      # and existing index/dashboard templates depend on that shape. Reach
      # the handoff versions as `ArbiterWeb.CoreComponents.Navigation.filter_tabs/1`
      # etc. until a follow-up ticket migrates call sites and retires the old
      # ones.
      import ArbiterWeb.CoreComponents.Navigation,
        except: [filter_tabs: 1, pager: 1, see_all_link: 1, back_link: 1]

      # Form primitives (Input, Select, Textarea, Checkbox) — not imported directly
      # to avoid shadowing the existing input/1, select/1, textarea/1, checkbox/1 in
      # CoreComponents. Call them fully-qualified: ArbiterWeb.CoreComponents.Forms.input/1
      # until a follow-up ticket migrates call sites and retires the old ones.
      # Design-handoff feedback primitives (LiveBadge, QuotaBar, WorkerFlow, Toast, EmptyState).
      # live_badge/1 and empty_state/1 are excluded: ArbiterWeb.ListComponents
      # already defines both with a different shape (live_badge/1: a required
      # `live` boolean, no `id`, daisyUI badge markup; empty_state/1: no
      # `detail` slot, daisyUI dashed-box markup), and existing call sites
      # (skill_index_live, run_index_live, worker_index_live,
      # merge_queue_index_live, loop_proposal_index_live) depend on them.
      # Reach the handoff versions as
      # `ArbiterWeb.CoreComponents.Feedback.live_badge/1` /
      # `ArbiterWeb.CoreComponents.Feedback.empty_state/1` until a follow-up
      # ticket migrates call sites and retires the old ones.
      import ArbiterWeb.CoreComponents.Feedback, except: [live_badge: 1, empty_state: 1]
      # Design-handoff domain primitives (TaskCard, RunRow, LogStream, StatCard,
      # IndexHeader). index_header/1 is excluded: ListComponents already
      # defines one that every index page calls unqualified, and importing
      # both would make `<.index_header>` ambiguous at every call site. Reach
      # the handoff version as
      # `ArbiterWeb.CoreComponents.Domain.index_header/1` until a follow-up
      # ticket migrates those call sites and retires the old one.
      import ArbiterWeb.CoreComponents.Domain, except: [index_header: 1]
      # Shared list / index / detail building blocks
      import ArbiterWeb.ListComponents
      # Label pluralization (plural/1, cap_plural/1)
      import ArbiterWeb.Labels

      # Common modules used in templates
      alias ArbiterWeb.Layouts
      alias Phoenix.LiveView.JS

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
