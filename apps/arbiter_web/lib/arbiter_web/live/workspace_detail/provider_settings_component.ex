defmodule ArbiterWeb.WorkspaceDetail.ProviderSettingsComponent do
  @moduledoc """
  The workspace's provider settings (bd-64apru): which provider accounts each
  role may use, in what preference order, and this workspace's concurrency
  share of each account (`docs/provider-account-design.md` §4.3).

  Everything reads and writes through `Arbiter.Accounts.ProviderSettings`, the
  same model provider routing reads, so what this pane shows as **effective**
  is exactly the candidate set a dispatch selects from — including the
  fallback when a role has no account attached.

  With nothing attached, a role resolves from `agent.type` /
  `review_agent.type`, and the pane shows that hand-written precedence list as
  the role's fallback editor. Once an account is attached, the key is written
  *from* the account list on every change, so the hand editor goes away.

  Like the other list editors on this page, each click is its own write.
  """
  use ArbiterWeb, :live_component

  import ArbiterWeb.WorkspaceDetail.Rows
  import ArbiterWeb.WorkspaceDetail.Shared

  alias Arbiter.Accounts
  alias Arbiter.Accounts.ProviderSettings
  alias Arbiter.Tasks.Workspace
  alias ArbiterWeb.CoreComponents.Core
  alias ArbiterWeb.CoreComponents.Forms

  @roles [
    {:implementer, "agent", "Implementer",
     "the worker, its resumes and every fix pass draw on these accounts, first preferred"},
    {:reviewer, "review_agent", "Reviewer",
     "the ReviewGate reviewer draws on these; leave empty to review on the implementer's set"}
  ]

  @role_names %{"implementer" => :implementer, "reviewer" => :reviewer}

  @impl true
  def mount(socket), do: {:ok, assign(socket, :provider_error, nil)}

  @impl true
  def update(assigns, socket) do
    {:ok, socket |> assign(assigns) |> load()}
  end

  defp load(%{assigns: %{workspace: ws, agent_types: agent_types}} = socket) do
    socket
    |> assign(:roles, Enum.map(@roles, &role_view(ws, &1)))
    |> assign(:attachments, ProviderSettings.attachments(ws))
    |> assign(:accounts, Enum.filter(Accounts.list_accounts(), & &1.enabled))
    |> assign(:account_labels, account_labels(ws, agent_types))
  end

  defp role_view(ws, {role, config_key, label, consequence}) do
    resolved = ProviderSettings.effective(ws, role)

    %{
      role: role,
      config_key: config_key,
      label: label,
      consequence: consequence,
      resolved: resolved,
      attached: if(resolved.source == :attached, do: resolved.candidates, else: []),
      adoptable?:
        resolved.source != :attached and Enum.any?(resolved.candidates, &(not is_nil(&1.account)))
    }
  end

  # ---- per-role account lists ----

  @impl true
  def handle_event("add_role_account", %{"role" => role, "account" => id}, socket) do
    write(socket, &ProviderSettings.add(&1, @role_names[role], id))
  end

  def handle_event("remove_role_account", %{"role" => role, "account" => id}, socket) do
    write(socket, &ProviderSettings.remove(&1, @role_names[role], id))
  end

  def handle_event("move_role_account", %{"role" => role, "account" => id, "dir" => dir}, socket)
      when dir in ["up", "down"] do
    write(socket, &ProviderSettings.move(&1, @role_names[role], id, String.to_existing_atom(dir)))
  end

  def handle_event("adopt_role", %{"role" => role}, socket) do
    write(socket, &ProviderSettings.adopt(&1, @role_names[role]))
  end

  def handle_event("set_share", %{"account" => id, "share" => raw}, socket) do
    with {:ok, share} <- parse_share(raw),
         {:ok, _link} <- ProviderSettings.set_share(socket.assigns.workspace, id, share) do
      {:noreply, socket |> assign(:provider_error, nil) |> load()}
    else
      {:error, reason} -> {:noreply, assign(socket, :provider_error, describe(reason))}
    end
  end

  # ---- fallback: the agent.type / review_agent.type precedence list ----

  def handle_event("add_agent_type", %{"role" => role, "type" => type}, socket) do
    update_agent_types(socket, role, fn list ->
      if type in list, do: list, else: list ++ [type]
    end)
  end

  def handle_event("remove_agent_type", %{"role" => role, "type" => type}, socket) do
    update_agent_types(socket, role, &List.delete(&1, type))
  end

  def handle_event("move_agent_type", %{"role" => role, "type" => type, "dir" => dir}, socket) do
    update_agent_types(socket, role, &move_type(&1, type, dir))
  end

  defp write(socket, fun) do
    case fun.(socket.assigns.workspace) do
      {:ok, %Workspace{} = ws} ->
        {:noreply, socket |> apply_workspace(ws) |> assign(:provider_error, nil) |> load()}

      {:error, reason} ->
        {:noreply, assign(socket, :provider_error, describe(reason))}
    end
  end

  defp update_agent_types(socket, role, fun) do
    ws = socket.assigns.workspace
    new_list = ws |> agent_type_list(role) |> fun.() |> Enum.uniq()
    default = if role == "agent", do: "claude", else: nil

    {patch, unset_paths} =
      case type_value(new_list, default) do
        nil -> {%{}, ["#{role}.type"]}
        value -> {%{role => %{"type" => value}}, []}
      end

    case patch_config(ws, patch, unset_paths) do
      {:ok, updated} ->
        {:noreply, socket |> apply_workspace(updated) |> assign(:provider_error, nil) |> load()}

      {:error, msg} ->
        {:noreply, assign(socket, :provider_error, msg)}
    end
  end

  defp move_type(list, type, "up") do
    case Enum.find_index(list, &(&1 == type)) do
      nil -> list
      0 -> list
      idx -> swap(list, idx, idx - 1)
    end
  end

  defp move_type(list, type, "down") do
    case Enum.find_index(list, &(&1 == type)) do
      nil -> list
      idx when idx == length(list) - 1 -> list
      idx -> swap(list, idx, idx + 1)
    end
  end

  defp swap(list, i, j) do
    a = Enum.at(list, i)
    b = Enum.at(list, j)
    list |> List.replace_at(i, b) |> List.replace_at(j, a)
  end

  # Collapse a selection back to the config shape: a single provider saves as
  # a scalar string (matching existing single-provider workspaces), several
  # as a pool list. An empty selection falls back to `default` (nil = unset).
  defp type_value([], default), do: default
  defp type_value([single], _default), do: single
  defp type_value(many, _default) when is_list(many), do: many

  defp agent_type_list(ws, role) do
    case cfg(ws, [role, "type"]) do
      t when is_binary(t) -> [t]
      types when is_list(types) -> types
      _ -> []
    end
  end

  # P10 (`docs/provider-account-design.md` §8, bd-icwk2k): which account a
  # fallback type is metered under, `%{"claude" => "personal-max"}`. A plain
  # read of the link, so — like `Usage`/`Quota`'s own account reads — it needs
  # no `Accounts.enabled?/0` gate: that flag guards the *credential* path.
  defp account_labels(%Workspace{id: ws_id}, agent_types) do
    for provider <- agent_types,
        account = Arbiter.Accounts.Resolver.account(ws_id, provider),
        not is_nil(account),
        into: %{} do
      {provider, account.slug}
    end
  end

  defp parse_share(raw) do
    case blank_to_nil(raw) do
      nil ->
        {:ok, nil}

      text ->
        case Integer.parse(text) do
          {n, ""} when n >= 0 -> {:ok, n}
          _ -> {:error, :invalid_share}
        end
    end
  end

  defp describe({:provider_taken, account}),
    do:
      "This workspace already uses #{ref(account)} for #{account.provider}, in another role — " <>
        "one account per provider per workspace. Remove it there first."

  defp describe(:disabled), do: "That account is disabled; enable it on the Providers page first."

  defp describe({:merged_away, _}),
    do: "That account was merged into another; attach the surviving account instead."

  defp describe(:nothing_to_adopt),
    do: "None of the configured types is linked to an account yet."

  defp describe(:invalid_share), do: "Share must be a whole number of slots, 0 or more."
  defp describe(:not_attached), do: "That account is not attached to this workspace."
  defp describe(:not_found), do: "No such account."
  defp describe(%{__exception__: true} = err), do: error_message(err)
  defp describe(other), do: inspect(other)

  defp ref(account), do: "#{account.provider}:#{account.slug}"

  # ---- render ----

  @source_labels %{
    attached: "attached accounts",
    agent_type: "fallback · agent.type",
    review_agent_type: "fallback · review_agent.type",
    implementer: "fallback · implementer's set",
    default: "fallback · default"
  }

  defp source_label(source), do: Map.fetch!(@source_labels, source)

  defp addable(accounts, attached) do
    ids = MapSet.new(attached, & &1.account.id)
    Enum.reject(accounts, &MapSet.member?(ids, &1.id))
  end

  defp cap_text(nil), do: "∞"
  defp cap_text(n), do: Integer.to_string(n)

  defp roles_of(link) do
    [
      link.implementer_position && "implementer",
      link.reviewer_position && "reviewer"
    ]
    |> Enum.filter(& &1)
    |> case do
      [] -> "metering only"
      roles -> Enum.join(roles, " · ")
    end
  end

  attr :resolved, :map, required: true

  defp effective_line(assigns) do
    ~H"""
    <div
      id={"provider-effective-#{@resolved.role}"}
      data-source={@resolved.source}
      class="flex flex-wrap items-center gap-1.5 rounded-[var(--radius-field)] bg-[var(--arb-raised)] px-2 py-1.5"
    >
      <span class="font-[family-name:var(--font-mono)] text-[10px] uppercase tracking-[0.06em] text-[var(--text-label)]">
        effective
      </span>
      <span class={[
        "rounded-[var(--radius-chip)] px-[6px] py-[1px] font-[family-name:var(--font-mono)] text-[10px]",
        if(@resolved.source == :attached,
          do: "bg-[var(--arb-live-wash)] text-[var(--arb-live)]",
          else: "bg-[var(--arb-attention-wash)] text-[var(--arb-attention)]"
        )
      ]}>
        {source_label(@resolved.source)}
      </span>
      <span
        :for={{c, idx} <- Enum.with_index(@resolved.candidates)}
        data-candidate={c.agent_type}
        class={[value_chip(), "gap-1"]}
      >
        <span class="text-[var(--text-label)]">{idx + 1}</span>
        <.provider_icon provider={c.agent_type} class="size-3" />
        <%= if c.account do %>
          {c.account.slug}
          <span class="text-[var(--text-label)]">cap {cap_text(c.cap)}</span>
        <% else %>
          {c.agent_type} <span class="text-[var(--text-label)]">· no linked account</span>
        <% end %>
      </span>
    </div>
    """
  end

  attr :role, :map, required: true
  attr :accounts, :list, required: true
  attr :target, :any, required: true

  defp role_accounts(assigns) do
    assigns = assign(assigns, :addable, addable(assigns.accounts, assigns.role.attached))

    ~H"""
    <ol id={"provider-role-#{@role.role}"} class="m-0 flex flex-col gap-1 p-0">
      <li
        :for={{c, idx} <- Enum.with_index(@role.attached)}
        id={"provider-role-#{@role.role}-#{c.account.id}"}
        class="flex items-center gap-2 rounded-[var(--radius-field)] border border-solid border-[var(--border-default)] bg-[var(--surface-card)] px-2 py-1 font-[family-name:var(--font-mono)] text-[11.5px] transition-colors duration-150 hover:border-[var(--border-strong)]"
      >
        <span class="w-4 text-[var(--text-label)]">{idx + 1}</span>
        <.provider_icon provider={c.agent_type} class="size-3.5" />
        <span class="flex-1 truncate text-[var(--arb-text-body)]">
          {c.account.label || c.account.slug}
          <span class="text-[var(--text-label)]">{c.provider}:{c.account.slug}</span>
        </span>
        <span class="text-[10px] text-[var(--text-label)]" title="min(account ceiling, share)">
          cap {cap_text(c.cap)}
        </span>
        <button
          type="button"
          phx-target={@target}
          phx-click="move_role_account"
          phx-value-role={@role.role}
          phx-value-account={c.account.id}
          phx-value-dir="up"
          disabled={idx == 0}
          class={icon_button()}
          aria-label={"Prefer #{c.account.slug}"}
        >
          <Core.icon name="hero-chevron-up" size={12} />
        </button>
        <button
          type="button"
          phx-target={@target}
          phx-click="move_role_account"
          phx-value-role={@role.role}
          phx-value-account={c.account.id}
          phx-value-dir="down"
          disabled={idx == length(@role.attached) - 1}
          class={icon_button()}
          aria-label={"Demote #{c.account.slug}"}
        >
          <Core.icon name="hero-chevron-down" size={12} />
        </button>
        <button
          type="button"
          phx-target={@target}
          phx-click="remove_role_account"
          phx-value-role={@role.role}
          phx-value-account={c.account.id}
          class={icon_button(:danger)}
          aria-label={"Remove #{c.account.slug} from #{@role.label}"}
        >
          <Core.icon name="hero-x-mark" size={12} />
        </button>
      </li>
      <li
        :if={@role.attached == []}
        class="font-[family-name:var(--font-mono)] text-[11px] text-[var(--text-label)]"
      >
        No accounts attached — resolving from config below.
      </li>
    </ol>
    <div :if={@addable != [] or @role.adoptable?} class="mt-1 flex flex-wrap gap-1">
      <button
        :if={@role.adoptable?}
        id={"adopt-#{@role.role}"}
        type="button"
        phx-target={@target}
        phx-click="adopt_role"
        phx-value-role={@role.role}
        class={[
          value_chip(),
          "cursor-pointer gap-1 border-[var(--accent-primary)] text-[var(--accent-primary)] hover:bg-[var(--arb-raised)]"
        ]}
        title="Attach the accounts the config fallback already resolves to, in the same order"
      >
        <Core.icon name="hero-arrow-down-on-square" size={11} /> adopt current setting
      </button>
      <button
        :for={account <- @addable}
        type="button"
        phx-target={@target}
        phx-click="add_role_account"
        phx-value-role={@role.role}
        phx-value-account={account.id}
        class={[
          value_chip(),
          "cursor-pointer gap-1 transition-colors duration-150 hover:border-[var(--accent-primary)] hover:text-[var(--text-body)]"
        ]}
      >
        <Core.icon name="hero-plus" size={11} />
        <.provider_icon provider={ProviderSettings.agent_type(account.provider)} class="size-3" />
        {account.provider}:{account.slug}
      </button>
    </div>
    """
  end

  attr :role, :string, required: true
  attr :label, :string, required: true
  attr :consequence, :string, required: true
  attr :selected, :list, required: true
  attr :available, :list, required: true
  attr :target, :any, required: true
  attr :account_labels, :map, default: %{}

  defp agent_type_editor(assigns) do
    ~H"""
    <.setting_row name={@label} consequence={@consequence}>
      <:below>
        <ol class="m-0 flex flex-col gap-1 p-0">
          <li
            :for={{type, idx} <- Enum.with_index(@selected)}
            class="flex items-center gap-2 rounded-[var(--radius-field)] border border-solid border-[var(--border-default)] bg-[var(--surface-card)] px-2 py-1 font-[family-name:var(--font-mono)] text-[11.5px]"
          >
            <span class="w-4 text-[var(--text-label)]">{idx + 1}</span>
            <span class="flex-1 text-[var(--arb-text-body)]">{type}</span>
            <span
              :if={Map.get(@account_labels, type)}
              class="text-[9.5px] text-[var(--text-label)]"
              title={"Provider account this workspace's #{type} is metered under"}
            >
              account: {Map.get(@account_labels, type)}
            </span>
            <button
              type="button"
              phx-target={@target}
              phx-click="move_agent_type"
              phx-value-role={@role}
              phx-value-type={type}
              phx-value-dir="up"
              disabled={idx == 0}
              class={icon_button()}
              aria-label={"Move #{type} up"}
            >
              <Core.icon name="hero-chevron-up" size={12} />
            </button>
            <button
              type="button"
              phx-target={@target}
              phx-click="move_agent_type"
              phx-value-role={@role}
              phx-value-type={type}
              phx-value-dir="down"
              disabled={idx == length(@selected) - 1}
              class={icon_button()}
              aria-label={"Move #{type} down"}
            >
              <Core.icon name="hero-chevron-down" size={12} />
            </button>
            <button
              type="button"
              phx-target={@target}
              phx-click="remove_agent_type"
              phx-value-role={@role}
              phx-value-type={type}
              class={icon_button(:danger)}
              aria-label={"Remove #{type}"}
            >
              <Core.icon name="hero-x-mark" size={12} />
            </button>
          </li>
          <li
            :if={@selected == []}
            class="font-[family-name:var(--font-mono)] text-[11px] text-[var(--text-label)]"
          >
            None selected.
          </li>
        </ol>
        <div :if={@available != []} class="mt-1 flex flex-wrap gap-1">
          <button
            :for={type <- @available}
            type="button"
            phx-target={@target}
            phx-click="add_agent_type"
            phx-value-role={@role}
            phx-value-type={type}
            class={[
              value_chip(),
              "cursor-pointer gap-1 hover:border-[var(--accent-primary)] hover:text-[var(--text-body)]"
            ]}
          >
            <Core.icon name="hero-plus" size={11} /> {type}
          </button>
        </div>
      </:below>
    </.setting_row>
    """
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div id="provider-settings" class={pane_class("providers", @section)}>
      <.rows>
        <%= for role <- @roles do %>
          <.setting_row
            name={"#{role.label} accounts"}
            consequence={"#{role.config_key}.type is written from this list — #{role.consequence}"}
          >
            <:below>
              <div class="flex flex-col gap-2">
                <.effective_line resolved={role.resolved} />
                <.role_accounts role={role} accounts={@accounts} target={@myself} />
              </div>
            </:below>
          </.setting_row>

          <.agent_type_editor
            :if={role.attached == []}
            role={role.config_key}
            target={@myself}
            label={"#{role.label} fallback"}
            consequence={
              if role.role == :implementer,
                do:
                  "agent.type — used while no account is attached; dispatch takes the first type that is installed and under quota",
                else:
                  "review_agent.type — used while no account is attached; leave empty and reviews run on the implementer's set"
            }
            selected={agent_type_list(@workspace, role.config_key)}
            available={@agent_types -- agent_type_list(@workspace, role.config_key)}
            account_labels={@account_labels}
          />
        <% end %>

        <.setting_row
          name="Concurrency share"
          consequence="per account, this workspace's cap on the account's ceiling (§4.3) — a cap, not a reservation; blank = no workspace cap"
        >
          <:below>
            <ul :if={@attachments != []} id="provider-shares" class={list_class()}>
              <.list_row :for={link <- @attachments} id={"share-row-#{link.provider_account_id}"}>
                <.provider_icon
                  provider={ProviderSettings.agent_type(link.provider)}
                  class="size-3.5"
                />
                <span class="flex-1 truncate">
                  {link.provider}:{link.provider_account.slug}
                  <span class="text-[10px] text-[var(--text-label)]">{roles_of(link)}</span>
                </span>
                <span class="text-[10px] text-[var(--text-label)]">
                  ceiling {cap_text(link.provider_account.max_concurrent)}
                </span>
                <.form
                  for={%{}}
                  id={"share-form-#{link.provider_account_id}"}
                  phx-submit="set_share"
                  phx-target={@myself}
                  class="flex items-center gap-1"
                >
                  <input type="hidden" name="account" value={link.provider_account_id} />
                  <Forms.input
                    name="share"
                    value={link.share}
                    size="sm"
                    inputmode="numeric"
                    placeholder="none"
                    class="w-[64px]"
                    aria-label={"Share of #{link.provider_account.slug}"}
                  />
                  <Core.button type="submit" size="sm">Set</Core.button>
                </.form>
                <span
                  id={"share-cap-#{link.provider_account_id}"}
                  class="w-[52px] text-right text-[10.5px] text-[var(--text-secondary)]"
                  title="effective cap = min(account ceiling, share)"
                >
                  cap {cap_text(
                    ProviderSettings.cap(link.provider_account.max_concurrent, link.share)
                  )}
                </span>
              </.list_row>
            </ul>
            <p
              :if={@attachments == []}
              class="m-0 font-[family-name:var(--font-mono)] text-[11px] text-[var(--text-label)]"
            >
              No accounts linked to this workspace yet.
            </p>
          </:below>
        </.setting_row>
      </.rows>

      <p
        :if={@provider_error}
        id="provider-settings-error"
        class="m-0 text-[11px] text-[var(--arb-fail-text)]"
      >
        {@provider_error}
      </p>
    </div>
    """
  end
end
