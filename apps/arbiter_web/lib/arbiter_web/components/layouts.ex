defmodule ArbiterWeb.Layouts do
  @moduledoc """
  This module holds layouts and related functionality
  used by your application.
  """
  use ArbiterWeb, :html
  import ArbiterWeb.QuotaHelpers

  alias Arbiter.Messages.Message

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

  attr(:live, :boolean,
    default: false,
    doc:
      "socket-connected state from ArbiterWeb.LiveHooks' :live on_mount; false (never live) for dead controller renders that skip the hook"
  )

  attr(:quota_on_exhaustion, :any,
    default: nil,
    doc: "override for tests/specimens; real callers omit it and get the installation default"
  )

  attr(:coordinator_inbox, :list,
    default: [],
    doc: "unread mailbox-family messages addressed to the coordinator (ArbiterWeb.LiveHooks)"
  )

  attr(:coordinator_outstanding_count, :integer,
    default: 0,
    doc: "seen-but-not-cleared coordinator messages — the triage queue"
  )

  attr(:coordinator_inbox_now, DateTime,
    default: nil,
    doc: "drives the drawer's relative timestamps (ArbiterWeb.LiveHooks)"
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

    assigns =
      assign(assigns, :coordinator_inbox_now, assigns.coordinator_inbox_now || DateTime.utc_now())

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
        <ArbiterWeb.CoreComponents.Feedback.live_badge id="appshell-live" live={@live} />
        <.coordinator_inbox_trigger unread={length(@coordinator_inbox)} />
        <.theme_toggle />
      </:right>
    </.top_nav>

    <main>
      {render_slot(@inner_block)}
    </main>

    <.coordinator_inbox_drawer
      inbox={@coordinator_inbox}
      outstanding_count={@coordinator_outstanding_count}
      now={@coordinator_inbox_now}
    />

    <.toast_group flash={@flash} />
    """
  end

  attr(:unread, :integer, required: true)

  defp coordinator_inbox_trigger(assigns) do
    ~H"""
    <button
      type="button"
      id="coordinator-inbox-trigger"
      aria-label="Coordinator mailbox"
      phx-click={
        JS.toggle(to: "#coordinator-drawer-backdrop")
        |> JS.toggle(to: "#coordinator-drawer", display: "flex")
      }
      class="relative flex items-center justify-center size-[30px] rounded-[var(--radius-pill)] border border-solid border-[var(--border-default)] bg-[var(--surface-chrome)] cursor-pointer"
    >
      <ArbiterWeb.CoreComponents.Core.icon name="hero-inbox-micro" color="var(--text-secondary)" />
      <span
        :if={@unread > 0}
        id="coordinator-inbox-unread-badge"
        class="absolute -top-1 -right-1 min-w-[16px] h-[16px] px-1 rounded-[var(--radius-pill)] bg-[var(--arb-attention)] text-[9.5px] leading-[16px] text-center font-[family-name:var(--font-mono)] text-[var(--surface-chrome)]"
      >
        {@unread}
      </span>
    </button>
    """
  end

  attr(:inbox, :list, required: true)
  attr(:outstanding_count, :integer, required: true)
  attr(:now, DateTime, required: true)

  # The coordinator's mailbox — the upward channel of `arb inbox` / `arb msg`,
  # live — as an AppShell drawer rather than a board-only panel (bd-3kgb0e).
  # It is not scoped to any one screen because none of the mail in it is
  # scoped to any one screen either.
  defp coordinator_inbox_drawer(assigns) do
    ~H"""
    <div
      id="coordinator-drawer-backdrop"
      class="hidden fixed inset-0 bg-black/30 z-40"
      phx-click={JS.hide(to: "#coordinator-drawer-backdrop") |> JS.hide(to: "#coordinator-drawer")}
    >
    </div>

    <aside
      id="coordinator-drawer"
      class="hidden fixed right-0 top-0 h-full w-full max-w-sm z-50 flex flex-col border-l border-solid border-[var(--border-default)] bg-[var(--surface-card)] shadow-xl"
    >
      <div class="flex items-center justify-between gap-2 px-4 h-[var(--toolbar-height)] border-b border-solid border-[var(--border-default)] bg-[var(--arb-canvas-sunken)]">
        <h2 class="flex items-center gap-2 text-[12.5px] font-medium text-[var(--text-title)]">
          Coordinator Mailbox
          <span class="text-[10.5px] font-[family-name:var(--font-mono)] text-[var(--arb-attention)]">
            {length(@inbox)} unread
          </span>
          <span
            id="coordinator-mailbox-outstanding"
            title="Seen but not yet cleared — the triage queue"
            class="text-[10.5px] font-[family-name:var(--font-mono)] text-[var(--text-label)]"
          >
            {@outstanding_count} outstanding
          </span>
        </h2>
        <div class="flex items-center gap-3 shrink-0">
          <button
            type="button"
            phx-click="coordinator_clear"
            title="Soft-clear the outstanding tail — already-read mail is marked cleared (retained), unread is kept"
            class="text-[10.5px] font-[family-name:var(--font-mono)] text-[var(--text-link)] cursor-pointer"
          >
            clear read
          </button>
          <button
            type="button"
            aria-label="Close mailbox"
            phx-click={
              JS.hide(to: "#coordinator-drawer-backdrop") |> JS.hide(to: "#coordinator-drawer")
            }
            class="cursor-pointer"
          >
            <ArbiterWeb.CoreComponents.Core.icon
              name="hero-x-mark-micro"
              color="var(--text-secondary)"
            />
          </button>
        </div>
      </div>

      <div :if={@inbox == []} id="coordinator-mailbox-empty" class="p-4">
        <ArbiterWeb.CoreComponents.Feedback.empty_state
          icon="hero-inbox"
          detail="worker completions, failures and escalations land here in real time"
        >
          Inbox clear.
        </ArbiterWeb.CoreComponents.Feedback.empty_state>
      </div>

      <ul
        :if={@inbox != []}
        id="coordinator-mailbox-list"
        class="flex flex-col gap-2 p-3 overflow-y-auto"
      >
        <li
          :for={m <- @inbox}
          class={[
            "rounded-[var(--radius-field)] border border-solid border-[var(--arb-line-strong)]",
            "border-l-[length:var(--border-accent-width)] px-3 py-2 bg-[var(--arb-panel-alt)]",
            mailbox_border(m.kind)
          ]}
        >
          <div class="flex items-baseline justify-between gap-2">
            <div class="flex items-baseline gap-2 flex-wrap min-w-0">
              <span class="text-[10px] uppercase tracking-[0.08em] font-[family-name:var(--font-mono)] text-[var(--text-label)]">
                {m.kind}
              </span>
              <span class="text-[10.5px] font-[family-name:var(--font-mono)] text-[var(--text-secondary)]">
                from {m.from_ref || "?"}
              </span>
              <.link
                :if={Message.task_ref(m)}
                navigate={~p"/tasks/#{Message.task_ref(m)}"}
                class="text-[10.5px] font-[family-name:var(--font-mono)] text-[var(--text-link)]"
              >
                {Message.task_ref(m)}
              </.link>
              <span :if={m.subject} class="text-[12.5px] font-medium text-[var(--text-title)]">
                {m.subject}
              </span>
            </div>
            <div class="flex items-center gap-2 shrink-0">
              <span class="text-[10px] font-[family-name:var(--font-mono)] text-[var(--text-label)]">
                {relative(m.inserted_at, @now)}
              </span>
              <button
                type="button"
                phx-click="coordinator_mark_read"
                phx-value-id={m.id}
                class="text-[10.5px] font-[family-name:var(--font-mono)] text-[var(--text-link)] cursor-pointer"
              >
                mark read
              </button>
            </div>
          </div>
          <p
            :if={m.body not in [nil, ""]}
            class="mt-1.5 text-[12px] whitespace-pre-wrap text-[var(--text-secondary)]"
          >
            {m.body}
          </p>
        </li>
      </ul>
    </aside>
    """
  end

  defp mailbox_border(:escalation), do: "border-l-[color:var(--arb-fail)]"
  defp mailbox_border(:failure), do: "border-l-[color:var(--arb-fail)]"
  defp mailbox_border(:completion), do: "border-l-[color:var(--arb-live)]"
  defp mailbox_border(:direction), do: "border-l-[color:var(--arb-attention)]"
  defp mailbox_border(:flag), do: "border-l-[color:var(--arb-attention)]"
  defp mailbox_border(_), do: "border-l-[color:var(--arb-info)]"

  defp relative(%DateTime{} = ts, %DateTime{} = now), do: "#{elapsed(ts, now)} ago"
  defp relative(_, _), do: ""

  defp elapsed(%DateTime{} = since, %DateTime{} = now) do
    seconds = DateTime.diff(now, since)

    cond do
      seconds < 60 -> "#{seconds}s"
      seconds < 3600 -> "#{div(seconds, 60)}m"
      seconds < 86_400 -> "#{div(seconds, 3600)}h"
      true -> "#{div(seconds, 86_400)}d"
    end
  end

  # Board/Issues/Workers/Merge queue/Workspaces/Skills/Loop/Usage/Audit — the
  # global-chrome nav order (bd-53pfbg). Dashboard renamed to Board, "Loop
  # queue" to Loop, "Audit log" to Audit; About drops out of the nav (it's
  # still reachable at ~p"/about" directly). Reviews (bd-amtjxk) sits between
  # Usage and Audit — cross-cutting operator visibility, like both neighbors.
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
      %{label: "Reviews", href: ~p"/reviews"},
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
