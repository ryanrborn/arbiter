defmodule ArbiterWeb.ProvidersLive do
  @moduledoc """
  Provider accounts at `/providers` (bd-cb86s4): one card per
  `Arbiter.Accounts.ProviderAccount`, read from `Arbiter.Accounts.Overview`.

  Each card shows the provider, the account's name and attached workspaces;
  every quota pool's utilization against its pace — `QuotaHelpers.quota_pace/3`
  under the account's `Arbiter.Quota.gate_policy/2`, which is the paced
  dispatch gate's own `Arbiter.Quota.Gate.pace/6`; the account concurrency
  ceiling against its registry-derived live count; credential health
  (`AuthHold` / `CredentialWatchdog` for the provider's adapter, the active
  credentials by fingerprint, the last probe); and the last 30 days of usage
  and cost — `n/a` for a provider whose usage cannot be priced.

  ## Actions

  Create an account, add or rotate a credential, attach or detach a
  workspace. They exist only while `Arbiter.Accounts.enabled?/0` is true:
  with the flag off the page is read-only under an explicit notice, and every
  action handler refuses server-side too, so a hand-crafted event cannot
  write through a page that shows no buttons.

  ## The secret

  The credential form's secret is a `type="password"` input whose rendered
  `value` is always empty, on no `phx-change` — it crosses the socket once,
  on submit, straight into `Arbiter.Accounts.rotate_credential/2` (the
  ash_cloak-encrypted `ProviderCredential`), and is never assigned, echoed
  back into the form, or flashed. `secret` is in `:phoenix,
  :filter_parameters`, so LiveView's event logging prints it `[FILTERED]`.
  """

  use ArbiterWeb, :live_view

  import ArbiterWeb.QuotaHelpers,
    only: [quota_pace: 2, quota_pct: 1, quota_provider_label: 1, quota_windows: 1]

  alias Arbiter.Accounts
  alias Arbiter.Accounts.Overview

  @refresh_ms 15_000

  @providers [
    {"Claude", "claude"},
    {"Codex", "codex"},
    {"Gemini CLI", "gemini_cli"},
    {"Antigravity", "antigravity"}
  ]

  @kinds [
    {"OAuth token", "oauth_token"},
    {"API key", "api_key"},
    {"CLI credentials file", "cli_credentials_file"}
  ]

  # What a fresh credential form pre-fills per provider — the env var a
  # worker of that provider reads (`Arbiter.Accounts.Census`'s known set).
  @credential_defaults %{
    claude: %{"kind" => "oauth_token", "env_var" => "CLAUDE_CODE_OAUTH_TOKEN"},
    codex: %{"kind" => "api_key", "env_var" => "OPENAI_API_KEY"},
    gemini_cli: %{"kind" => "api_key", "env_var" => "GEMINI_API_KEY"},
    antigravity: %{"kind" => "api_key", "env_var" => "ANTIGRAVITY_API_KEY"}
  }

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket), do: :timer.send_interval(@refresh_ms, :refresh)

    {:ok,
     socket
     |> assign(:page_title, "Providers")
     |> assign(:creating?, false)
     |> assign(:account_form, account_form())
     |> assign(:account_error, nil)
     |> assign(:credential_for, nil)
     |> assign(:credential_form, nil)
     |> assign(:credential_error, nil)
     |> assign(:attach_for, nil)
     |> assign(:attach_form, nil)
     |> assign(:attach_error, nil)
     |> refresh()}
  end

  @impl true
  def handle_info(:refresh, socket), do: {:noreply, refresh(socket)}

  # ---- events ---------------------------------------------------------------

  @impl true
  def handle_event(event, params, socket) do
    if Accounts.enabled?() do
      action(event, params, socket)
    else
      {:noreply,
       socket
       |> refresh()
       |> put_flash(:error, "Accounts are not enabled on this install — this page is read-only.")}
    end
  end

  defp action("new_account", _params, socket),
    do:
      {:noreply,
       assign(socket, creating?: true, account_form: account_form(), account_error: nil)}

  defp action("cancel_account", _params, socket),
    do: {:noreply, assign(socket, creating?: false, account_error: nil)}

  defp action("create_account", %{"account" => params}, socket) do
    with {:ok, attrs} <- account_attrs(params),
         {:ok, account} <- Accounts.create_account(attrs) do
      {:noreply,
       socket
       |> assign(creating?: false, account_error: nil)
       |> put_flash(:info, "Created #{account.provider}:#{account.slug}.")
       |> refresh()}
    else
      {:error, error} ->
        {:noreply,
         assign(socket,
           creating?: true,
           account_form: account_form(params),
           account_error: error_message(error)
         )}
    end
  end

  defp action("open_credential", %{"id" => id}, socket) do
    defaults =
      case find_row(socket, id) do
        %{account: account} -> Map.get(@credential_defaults, account.provider, %{})
        nil -> %{}
      end

    {:noreply,
     assign(socket,
       credential_for: id,
       credential_form: credential_form(defaults),
       credential_error: nil
     )}
  end

  defp action("cancel_credential", _params, socket),
    do: {:noreply, assign(socket, credential_for: nil, credential_error: nil)}

  defp action(
         "rotate_credential",
         %{"account_id" => id, "credential" => params},
         socket
       ) do
    secret = params |> Map.get("secret", "") |> to_string() |> String.trim()
    # Everything the form re-renders with — never the secret.
    echo = Map.take(params, ["kind", "env_var"])

    result =
      if secret == "" do
        {:error, {:missing, :secret}}
      else
        Accounts.rotate_credential(id, %{
          "kind" => Map.get(params, "kind"),
          "env_var" => params |> Map.get("env_var", "") |> to_string() |> String.trim(),
          "secret" => secret
        })
      end

    case result do
      {:ok, credential} ->
        {:noreply,
         socket
         |> assign(credential_for: nil, credential_form: nil, credential_error: nil)
         |> put_flash(
           :info,
           "Stored #{credential.env_var} (#{String.slice(credential.fingerprint, 0, 12)}…)."
         )
         |> refresh()}

      {:error, error} ->
        {:noreply,
         assign(socket,
           credential_for: id,
           credential_form: credential_form(echo),
           credential_error: error_message(error)
         )}
    end
  end

  defp action("open_attach", %{"id" => id}, socket),
    do: {:noreply, assign(socket, attach_for: id, attach_form: attach_form(), attach_error: nil)}

  defp action("cancel_attach", _params, socket),
    do: {:noreply, assign(socket, attach_for: nil, attach_error: nil)}

  defp action("attach", %{"account_id" => id, "attach" => params}, socket) do
    with %{account: account} <- find_row(socket, id) || {:error, :not_found},
         {:ok, opts} <- share_opts(Map.get(params, "share")),
         {:ok, _link} <-
           Accounts.attach_workspace(
             Map.get(params, "workspace_id", ""),
             account.provider,
             account.id,
             opts
           ) do
      {:noreply,
       socket
       |> assign(attach_for: nil, attach_form: nil, attach_error: nil)
       |> put_flash(:info, "Attached to #{account.provider}:#{account.slug}.")
       |> refresh()}
    else
      {:error, error} ->
        {:noreply,
         assign(socket,
           attach_for: id,
           attach_form: attach_form(params),
           attach_error: error_message(error)
         )}
    end
  end

  defp action("detach", %{"account" => account_id, "workspace" => workspace_id}, socket) do
    case Accounts.detach_workspace(workspace_id, account_id) do
      {:ok, _link} ->
        {:noreply, socket |> put_flash(:info, "Detached.") |> refresh()}

      {:error, error} ->
        {:noreply, socket |> put_flash(:error, error_message(error)) |> refresh()}
    end
  end

  defp action(_event, _params, socket), do: {:noreply, socket}

  # ---- state ----------------------------------------------------------------

  defp refresh(socket) do
    socket
    |> assign(:enabled?, Accounts.enabled?())
    |> assign(:rows, Overview.list())
    |> assign(:workspace_options, Overview.workspace_options())
  end

  defp find_row(socket, id), do: Enum.find(socket.assigns.rows, &(&1.account.id == id))

  defp account_form(params \\ %{"provider" => "claude"}), do: to_form(params, as: :account)
  defp credential_form(params), do: to_form(params, as: :credential)
  defp attach_form(params \\ %{}), do: to_form(params, as: :attach)

  defp account_attrs(params) do
    with {:ok, max_concurrent} <- optional_int(Map.get(params, "max_concurrent"), :max_concurrent) do
      attrs =
        params
        |> Map.take(["provider", "slug", "label", "plan"])
        |> Map.reject(fn {_k, v} -> v in [nil, ""] end)
        |> Map.put("max_concurrent", max_concurrent)

      {:ok, attrs}
    end
  end

  defp share_opts(value) do
    case optional_int(value, :share) do
      {:ok, nil} -> {:ok, []}
      {:ok, share} -> {:ok, [share: share]}
      error -> error
    end
  end

  defp optional_int(value, _field) when value in [nil, ""], do: {:ok, nil}

  defp optional_int(value, field) when is_binary(value) do
    case Integer.parse(String.trim(value)) do
      {n, ""} when n >= 0 -> {:ok, n}
      _ -> {:error, {:not_a_count, field}}
    end
  end

  defp error_message(%Ash.Error.Invalid{errors: errors}),
    do: Enum.map_join(errors, "; ", &Exception.message/1)

  defp error_message(error) when is_exception(error), do: Exception.message(error)
  defp error_message({:missing, :secret}), do: "Paste the secret to store."
  defp error_message({:missing, field}), do: "#{humanize(field)} is required."
  defp error_message({:invalid_kind, _}), do: "Pick a credential kind."
  defp error_message({:not_a_count, field}), do: "#{humanize(field)} must be a whole number ≥ 0."
  defp error_message({:merged_away, _}), do: "This account was merged into another one."

  defp error_message({:provider_mismatch, provider}),
    do: "That account is a #{provider} account."

  defp error_message(:not_found), do: "Not found — pick a workspace."
  defp error_message(:not_attached), do: "That workspace is no longer attached to this account."
  defp error_message(:ambiguous), do: "That account reference is ambiguous."
  defp error_message(other), do: inspect(other)

  defp humanize(field),
    do: field |> to_string() |> String.replace("_", " ") |> String.capitalize()

  # ---- view helpers ---------------------------------------------------------

  defp account_name(account), do: account.label || account.slug

  # `provider_icon/1` knows the three agent logos; both Google surfaces share
  # Gemini's.
  defp icon_provider(:gemini_cli), do: "gemini"
  defp icon_provider(:antigravity), do: "gemini"
  defp icon_provider(provider), do: Atom.to_string(provider)

  # One row per pool window: the bar plus the pace readout, both read from
  # the paced gate's verdict.
  defp pools(view) do
    for bar <- quota_windows(view) do
      bar =
        Map.merge(bar, %{
          provider: view.provider,
          overage_status: view[:overage_status]
        })

      Map.put(bar, :pace, quota_pace(bar, view.gate_policy))
    end
  end

  defp pace_text(%{utilization: nil}), do: "no reading"

  defp pace_text(%{utilization: u, pace: %{elapsed: elapsed, ceiling: ceiling, mode: mode}}) do
    used = "#{quota_pct(u)}% used"
    pace = if is_number(elapsed), do: "#{round(elapsed * 100)}% pace", else: "pace n/a"
    ceiling = "#{if mode == :paced, do: "paced ", else: ""}ceiling #{round(ceiling * 100)}%"
    Enum.join([used, pace, ceiling], " · ")
  end

  defp verdict_class(:holding), do: "text-[var(--arb-fail-text)]"
  defp verdict_class(:approaching), do: "text-[var(--arb-attention-ink)]"
  defp verdict_class(_), do: "text-[var(--arb-text-muted)]"

  defp verdict_label(:holding), do: "holding"
  defp verdict_label(:approaching), do: "approaching"
  defp verdict_label(:sampling), do: "sampling"
  defp verdict_label(:ok), do: "on pace"

  defp concurrency_text(%{live_count: live, max_concurrent: nil}), do: "#{live} live · no cap"
  defp concurrency_text(%{live_count: live, max_concurrent: cap}), do: "#{live} / #{cap}"

  defp concurrency_pct(%{max_concurrent: cap}) when cap in [nil, 0], do: 0

  defp concurrency_pct(%{live_count: live, max_concurrent: cap}),
    do: min(100, round(live / cap * 100))

  defp health_label(%{state: :ok}), do: "healthy"
  defp health_label(%{state: :no_credential}), do: "no credential"
  defp health_label(%{state: :expired}), do: "credential expired"
  defp health_label(%{state: :auth_hold, auth_hold: %{deaths: d}}), do: "auth hold · #{d} deaths"
  defp health_label(%{state: :auth_hold}), do: "auth hold"

  defp health_class(:ok),
    do: "bg-[var(--arb-live-wash)] text-[var(--arb-live-ink)] border-[var(--arb-live-edge)]"

  defp health_class(:no_credential),
    do:
      "bg-[var(--arb-attention-wash)] text-[var(--arb-attention-ink)] border-[var(--arb-attention-edge)]"

  defp health_class(_),
    do: "bg-[var(--arb-fail-wash)] text-[var(--arb-fail-ink)] border-[var(--arb-fail-edge)]"

  defp health_title(account),
    do:
      "Auth hold and watchdog state are per #{quota_provider_label(Atom.to_string(account.provider))} CLI adapter — shared by every account on this provider."

  defp usage_rows_text(1), do: "1 usage event"
  defp usage_rows_text(n), do: "#{n} usage events"

  defp cost_text(%{cost_usd: nil}), do: "n/a"
  defp cost_text(%{cost_usd: cost}), do: format_usd(cost)

  defp ago(nil), do: "never"

  defp ago(%DateTime{} = at) do
    secs = max(DateTime.diff(DateTime.utc_now(), at), 0)

    cond do
      secs < 60 -> "just now"
      secs < 3600 -> "#{div(secs, 60)}m ago"
      secs < 86_400 -> "#{div(secs, 3600)}h ago"
      true -> "#{div(secs, 86_400)}d ago"
    end
  end

  defp attachable(options, row) do
    attached = MapSet.new(row.workspaces, & &1.workspace_id)
    Enum.reject(options, fn {_name, id} -> MapSet.member?(attached, id) end)
  end

  # ---- render ---------------------------------------------------------------

  @impl true
  def render(assigns) do
    assigns =
      assigns
      |> assign(:providers, @providers)
      |> assign(:kinds, @kinds)
      |> assign(:window_days, Overview.usage_window_days())

    ~H"""
    <Layouts.app
      flash={@flash}
      current_path={@current_path}
      quotas={@quotas}
      live={@live}
      coordinator_inbox={@coordinator_inbox}
      coordinator_outstanding_count={@coordinator_outstanding_count}
      coordinator_inbox_now={@coordinator_inbox_now}
    >
      <div id="providers-page" class="p-4 sm:p-6 max-w-7xl mx-auto flex flex-col gap-4">
        <ArbiterWeb.CoreComponents.Domain.index_header
          icon="hero-key"
          title="Providers"
          count={length(@rows)}
          subtitle="Provider accounts: quota pools against pace, concurrency, credential health and cost. Credentials, quota and the concurrency ceiling hang off the account, not the workspace."
        >
          <:actions>
            <ArbiterWeb.CoreComponents.Core.button
              :if={@enabled? and not @creating?}
              id="new-account-button"
              phx-click="new_account"
              variant="primary"
              size="sm"
            >
              <:icon><ArbiterWeb.CoreComponents.Core.icon name="hero-plus" size={13} /></:icon>
              New account
            </ArbiterWeb.CoreComponents.Core.button>
          </:actions>
        </ArbiterWeb.CoreComponents.Domain.index_header>

        <div
          :if={not @enabled?}
          id="accounts-disabled-notice"
          role="status"
          class="flex items-start gap-3 rounded-[var(--radius-panel)] border border-[var(--arb-attention-edge)] bg-[var(--arb-attention-wash)] px-4 py-3 text-[13px] text-[var(--arb-attention-ink)]"
        >
          <ArbiterWeb.CoreComponents.Core.icon
            name="hero-lock-closed"
            size={16}
            class="mt-0.5 shrink-0"
          />
          <div class="flex flex-col gap-0.5">
            <span class="font-medium">Accounts not enabled on this install</span>
            <span class="text-[12px] opacity-90">
              <code class="font-[family-name:var(--font-mono)]">:provider_accounts_enabled</code>
              is off, so workers still take credentials from each workspace's worker env. This page is read-only until it is turned on.
            </span>
          </div>
        </div>

        <ArbiterWeb.CoreComponents.Core.panel
          :if={@enabled? and @creating?}
          id="new-account-panel"
          title="New provider account"
          meta="no credential needed yet"
        >
          <.form
            for={@account_form}
            id="account-form"
            phx-submit="create_account"
            class="grid grid-cols-1 sm:grid-cols-2 lg:grid-cols-5 gap-3 items-end"
          >
            <.input
              field={@account_form[:provider]}
              type="select"
              label="Provider"
              options={@providers}
            />
            <.input field={@account_form[:slug]} label="Slug" placeholder="work-max" required />
            <.input field={@account_form[:label]} label="Label" placeholder="Work Max plan" />
            <.input field={@account_form[:plan]} label="Plan" placeholder="max_20x" />
            <.input
              field={@account_form[:max_concurrent]}
              type="number"
              min="0"
              label="Concurrency cap"
              placeholder="none"
            />
            <p
              :if={@account_error}
              id="account-form-error"
              class="sm:col-span-2 lg:col-span-5 text-[12px] text-[var(--arb-fail-text)]"
            >
              {@account_error}
            </p>
            <div class="sm:col-span-2 lg:col-span-5 flex gap-2">
              <ArbiterWeb.CoreComponents.Core.button type="submit" variant="primary" size="sm">
                Create account
              </ArbiterWeb.CoreComponents.Core.button>
              <ArbiterWeb.CoreComponents.Core.button
                type="button"
                variant="ghost"
                size="sm"
                phx-click="cancel_account"
              >
                Cancel
              </ArbiterWeb.CoreComponents.Core.button>
            </div>
          </.form>
        </ArbiterWeb.CoreComponents.Core.panel>

        <div :if={@rows == []} id="providers-empty">
          <ArbiterWeb.CoreComponents.Feedback.empty_state
            icon="hero-key"
            detail="arb account create <provider> <slug>, or New account above"
          >
            No provider accounts yet.
          </ArbiterWeb.CoreComponents.Feedback.empty_state>
        </div>

        <div id="provider-accounts" class="flex flex-col gap-3">
          <article
            :for={row <- @rows}
            id={"account-#{row.account.id}"}
            class="rounded-[var(--radius-panel)] border border-[var(--border-default)] bg-[var(--surface-panel)] overflow-hidden transition-shadow duration-150 hover:shadow-sm"
          >
            <header class="flex flex-wrap items-center gap-3 px-[18px] py-3 border-b border-[var(--border-default)]">
              <span
                id={"account-#{row.account.id}-provider"}
                class="inline-flex size-8 items-center justify-center rounded-[var(--radius-box)] bg-[var(--surface-card)] text-[var(--text-title)]"
              >
                <.provider_icon provider={icon_provider(row.account.provider)} class="size-4" />
              </span>
              <div class="flex flex-col min-w-0">
                <span
                  id={"account-#{row.account.id}-name"}
                  class="font-medium text-[14px] text-[var(--text-title)] truncate"
                >
                  {account_name(row.account)}
                </span>
                <span class="text-[11px] text-[var(--text-label)] font-[family-name:var(--font-mono)]">
                  {row.account.provider}:{row.account.slug}<span :if={row.account.plan}> · {row.account.plan}</span>
                </span>
              </div>
              <span
                :if={not row.account.enabled}
                class="text-[11px] px-2 py-0.5 rounded-[var(--radius-chip)] border border-[var(--border-default)] text-[var(--arb-text-muted)]"
              >
                parked
              </span>
              <span
                id={"account-#{row.account.id}-health"}
                data-health={row.health.state}
                title={health_title(row.account)}
                class={[
                  "ml-auto text-[11px] font-medium px-2 py-0.5 rounded-[var(--radius-chip)] border",
                  health_class(row.health.state)
                ]}
              >
                {health_label(row.health)}
              </span>
            </header>

            <div class="grid grid-cols-1 md:grid-cols-2 xl:grid-cols-[minmax(0,1.6fr)_minmax(0,0.8fr)_minmax(0,1.2fr)_minmax(0,0.8fr)] gap-px bg-[var(--arb-line-soft)]">
              <section
                id={"account-#{row.account.id}-quota"}
                class="bg-[var(--surface-panel)] px-[18px] py-3 flex flex-col gap-2"
              >
                <h3 class="text-[11px] uppercase tracking-wide text-[var(--text-label)]">Pools</h3>
                <p :if={row.quotas == []} class="text-[12px] text-[var(--arb-text-muted)]">
                  No quota snapshot yet.
                </p>
                <div :for={view <- row.quotas} class="flex flex-col gap-1.5">
                  <div :for={pool <- pools(view)} class="flex flex-col gap-0.5">
                    <.quota_bar
                      provider={view.provider}
                      window={pool.window}
                      label={pool.label}
                      utilization={pool.utilization}
                      reset_at={pool.reset_at}
                      overage_status={pool.overage_status}
                      gate_policy={view.gate_policy}
                      stale_message={view[:message]}
                      width={160}
                      label_width={52}
                    />
                    <span
                      id={"account-#{row.account.id}-pace-#{pool.window}"}
                      data-pace-verdict={pool.pace.verdict}
                      class="text-[11px] font-[family-name:var(--font-mono)] text-[var(--arb-text-muted)]"
                    >
                      {pace_text(pool)} ·
                      <span class={verdict_class(pool.pace.verdict)}>
                        {verdict_label(pool.pace.verdict)}
                      </span>
                    </span>
                  </div>
                </div>
              </section>

              <section class="bg-[var(--surface-panel)] px-[18px] py-3 flex flex-col gap-2">
                <h3 class="text-[11px] uppercase tracking-wide text-[var(--text-label)]">
                  Concurrency
                </h3>
                <span
                  id={"account-#{row.account.id}-concurrency"}
                  class="text-[18px] font-medium tabular-nums text-[var(--text-title)]"
                >
                  {concurrency_text(row)}
                </span>
                <div
                  :if={row.max_concurrent}
                  class="h-1.5 w-full rounded-[var(--radius-pill)] bg-[var(--surface-card)] overflow-hidden"
                >
                  <div
                    class="h-full bg-[var(--arb-live)] transition-[width] duration-300"
                    style={"width: #{concurrency_pct(row)}%"}
                  />
                </div>
                <span class="text-[11px] text-[var(--arb-text-muted)]">
                  workers live across every attached workspace
                </span>
              </section>

              <section class="bg-[var(--surface-panel)] px-[18px] py-3 flex flex-col gap-2">
                <div class="flex items-center justify-between gap-2">
                  <h3 class="text-[11px] uppercase tracking-wide text-[var(--text-label)]">
                    Credential
                  </h3>
                  <ArbiterWeb.CoreComponents.Core.button
                    :if={@enabled? and @credential_for != row.account.id}
                    id={"account-#{row.account.id}-credential-button"}
                    phx-click="open_credential"
                    phx-value-id={row.account.id}
                    variant="ghost"
                    size="sm"
                  >
                    {if row.credentials == [], do: "Add", else: "Rotate"}
                  </ArbiterWeb.CoreComponents.Core.button>
                </div>
                <ul
                  id={"account-#{row.account.id}-credentials"}
                  class="flex flex-col gap-1 list-none m-0 p-0"
                >
                  <li :if={row.credentials == []} class="text-[12px] text-[var(--arb-text-muted)]">
                    No active credential.
                  </li>
                  <li
                    :for={credential <- row.credentials}
                    class="flex flex-wrap items-baseline gap-x-2 text-[12px] font-[family-name:var(--font-mono)]"
                  >
                    <span class="text-[var(--text-title)]">{credential.env_var}</span>
                    <span class="text-[var(--arb-text-muted)]">{credential.kind}</span>
                    <span class="text-[var(--arb-text-faint)]" title="sha256 fingerprint prefix">
                      {credential.fingerprint}…
                    </span>
                  </li>
                </ul>
                <span class="text-[11px] text-[var(--arb-text-muted)]">
                  last probe
                  <span id={"account-#{row.account.id}-last-probe"} class="text-[var(--text-body)]">
                    {ago(row.health.last_probe_at)}
                  </span>
                </span>

                <.form
                  :if={@enabled? and @credential_for == row.account.id}
                  for={@credential_form}
                  id={"credential-form-#{row.account.id}"}
                  phx-submit="rotate_credential"
                  autocomplete="off"
                  class="flex flex-col gap-2 pt-2 border-t border-[var(--arb-line-soft)]"
                >
                  <input type="hidden" name="account_id" value={row.account.id} />
                  <div class="grid grid-cols-2 gap-2">
                    <.input
                      field={@credential_form[:kind]}
                      type="select"
                      label="Kind"
                      options={@kinds}
                    />
                    <.input field={@credential_form[:env_var]} label="Env var" required />
                  </div>
                  <.input
                    id={"credential-form-#{row.account.id}-secret"}
                    name="credential[secret]"
                    type="password"
                    value=""
                    label="Secret"
                    autocomplete="new-password"
                    placeholder="pasted once, stored encrypted, never shown again"
                    required
                  />
                  <p
                    :if={@credential_error}
                    id={"credential-form-#{row.account.id}-error"}
                    class="text-[12px] text-[var(--arb-fail-text)]"
                  >
                    {@credential_error}
                  </p>
                  <div class="flex gap-2">
                    <ArbiterWeb.CoreComponents.Core.button type="submit" variant="primary" size="sm">
                      Store credential
                    </ArbiterWeb.CoreComponents.Core.button>
                    <ArbiterWeb.CoreComponents.Core.button
                      type="button"
                      variant="ghost"
                      size="sm"
                      phx-click="cancel_credential"
                    >
                      Cancel
                    </ArbiterWeb.CoreComponents.Core.button>
                  </div>
                </.form>
              </section>

              <section class="bg-[var(--surface-panel)] px-[18px] py-3 flex flex-col gap-1">
                <h3 class="text-[11px] uppercase tracking-wide text-[var(--text-label)]">
                  Last {@window_days} days
                </h3>
                <span
                  id={"account-#{row.account.id}-cost"}
                  title={if row.usage.cost_usd == nil, do: "usage on this provider cannot be priced"}
                  class="text-[18px] font-medium tabular-nums text-[var(--text-title)]"
                >
                  {cost_text(row.usage)}
                </span>
                <span class="text-[11px] text-[var(--arb-text-muted)] tabular-nums">
                  {format_tokens(row.usage.tokens)} tokens · {usage_rows_text(row.usage.rows)}
                </span>
              </section>
            </div>

            <footer class="flex flex-wrap items-center gap-2 px-[18px] py-2.5 border-t border-[var(--border-default)] bg-[var(--surface-chrome)]">
              <span class="text-[11px] uppercase tracking-wide text-[var(--text-label)] mr-1">
                Workspaces
              </span>
              <span :if={row.workspaces == []} class="text-[12px] text-[var(--arb-text-muted)]">
                none attached
              </span>
              <span
                :for={link <- row.workspaces}
                id={"account-#{row.account.id}-ws-#{link.workspace_id}"}
                class="inline-flex items-center gap-1 rounded-[var(--radius-chip)] border border-[var(--border-default)] bg-[var(--surface-card)] pl-2 pr-1 py-0.5 text-[12px]"
              >
                <.link navigate={~p"/workspaces/#{link.workspace_id}"} class="hover:underline">
                  {link.workspace_name}
                </.link>
                <span
                  :if={link.share}
                  class="text-[var(--arb-text-muted)] font-[family-name:var(--font-mono)]"
                  title="this workspace's cap on the account's concurrency"
                >
                  ≤{link.share}
                </span>
                <button
                  :if={@enabled?}
                  type="button"
                  id={"detach-#{row.account.id}-#{link.workspace_id}"}
                  phx-click="detach"
                  phx-value-account={row.account.id}
                  phx-value-workspace={link.workspace_id}
                  data-confirm={"Detach #{link.workspace_name} from #{row.account.slug}?"}
                  aria-label={"Detach #{link.workspace_name}"}
                  class="inline-flex size-4 items-center justify-center rounded-full text-[var(--arb-text-muted)] transition-colors hover:bg-[var(--arb-fail-wash)] hover:text-[var(--arb-fail-text)]"
                >
                  <ArbiterWeb.CoreComponents.Core.icon name="hero-x-mark" size={11} />
                </button>
              </span>
              <ArbiterWeb.CoreComponents.Core.button
                :if={@enabled? and @attach_for != row.account.id}
                id={"account-#{row.account.id}-attach-button"}
                phx-click="open_attach"
                phx-value-id={row.account.id}
                variant="ghost"
                size="sm"
                class="ml-auto"
              >
                <:icon><ArbiterWeb.CoreComponents.Core.icon name="hero-link" size={13} /></:icon>
                Attach workspace
              </ArbiterWeb.CoreComponents.Core.button>

              <.form
                :if={@enabled? and @attach_for == row.account.id}
                for={@attach_form}
                id={"attach-form-#{row.account.id}"}
                phx-submit="attach"
                class="basis-full flex flex-wrap items-end gap-2 pt-2"
              >
                <input type="hidden" name="account_id" value={row.account.id} />
                <.input
                  field={@attach_form[:workspace_id]}
                  type="select"
                  label="Workspace"
                  prompt="Pick a workspace"
                  options={attachable(@workspace_options, row)}
                />
                <.input
                  field={@attach_form[:share]}
                  type="number"
                  min="0"
                  label="Share (optional cap)"
                  placeholder="none"
                />
                <ArbiterWeb.CoreComponents.Core.button type="submit" variant="primary" size="sm">
                  Attach
                </ArbiterWeb.CoreComponents.Core.button>
                <ArbiterWeb.CoreComponents.Core.button
                  type="button"
                  variant="ghost"
                  size="sm"
                  phx-click="cancel_attach"
                >
                  Cancel
                </ArbiterWeb.CoreComponents.Core.button>
                <p
                  :if={@attach_error}
                  id={"attach-form-#{row.account.id}-error"}
                  class="basis-full text-[12px] text-[var(--arb-fail-text)]"
                >
                  {@attach_error}
                </p>
              </.form>
            </footer>
          </article>
        </div>
      </div>
    </Layouts.app>
    """
  end
end
