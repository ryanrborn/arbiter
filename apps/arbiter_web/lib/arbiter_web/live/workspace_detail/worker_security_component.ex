defmodule ArbiterWeb.WorkspaceDetail.WorkerSecurityComponent do
  @moduledoc """
  `agent.security.*` — the filesystem, network and destructive-action
  guardrails applied to every worker this workspace dispatches on this machine.

  Deliberately its own section rather than one more toggle beside the routine
  merge/review switches, because these fields decide what a dispatched worker
  may do to this host. The *resolved* posture (what actually applies after the
  base → install → workspace layering in `Arbiter.Agents.SecurityPolicy`) is
  shown above the editor, and any submit that would strip a guard — a
  `safe_defaults` category, the sandbox, worktree filesystem scoping, an
  operator deny rule, or the network cut-off — is refused on first submit and
  re-presented as an explicit confirmation naming exactly what is being given
  up. Only the confirm click writes. See `security_downgrades/2`.
  """
  use ArbiterWeb, :live_component

  import ArbiterWeb.WorkspaceDetail.Rows
  import ArbiterWeb.WorkspaceDetail.Shared

  alias Arbiter.Agents.SecurityPolicy
  alias Arbiter.Tasks.Workspace.Changes.PatchConfig
  alias ArbiterWeb.CoreComponents.Core
  alias ArbiterWeb.CoreComponents.Forms

  @impl true
  def mount(socket), do: {:ok, assign(socket, security_error: nil, security_confirm: nil)}

  @impl true
  def update(assigns, socket) do
    socket = assign(socket, assigns)
    {:ok, load_derived(socket)}
  end

  defp load_derived(%{assigns: %{workspace: ws}} = socket) do
    socket
    |> assign(:security_policy, SecurityPolicy.resolve(ws))
    |> assign(:security_repo_postures, security_repo_postures(ws))
  end

  # `agent.security.repos.<repo>` is a whole extra layer applied on top of the
  # workspace-wide posture for dispatches against that repo, so the resolved
  # workspace line alone can misrepresent what a worker actually gets (a repo
  # can, say, turn the sandbox back off). Resolved through the same
  # `SecurityPolicy.resolve/3` path and listed read-only under the posture
  # panel; this form edits the workspace layer only, that one stays CLI-owned.
  defp security_repo_postures(ws) do
    case cfg(ws, ["agent", "security", "repos"]) do
      %{} = repos ->
        repos
        |> Map.keys()
        |> Enum.filter(&is_binary/1)
        |> Enum.sort()
        |> Enum.map(&{&1, SecurityPolicy.resolve(ws, %{}, &1)})

      _ ->
        []
    end
  end

  @impl true
  def handle_event("save_security", %{"security" => params}, socket) do
    ws = socket.assigns.workspace

    case validate_security_params(params) do
      {:error, msg} ->
        {:noreply, socket |> assign(:security_error, msg) |> assign(:security_confirm, nil)}

      :ok ->
        block = security_block(params, socket.assigns.safe_default_categories)

        current = SecurityPolicy.resolve(ws)
        proposed = SecurityPolicy.resolve(%{config: security_preview_config(ws, block)})

        case security_downgrades(current, proposed) do
          [] ->
            {:noreply, apply_security(socket, block)}

          downgrades ->
            # Refuse the plain save: the operator has to look at the list of
            # guards they are giving up and click through, mirroring how
            # destructive operations elsewhere are gated behind an explicit
            # acknowledgement rather than a single submit.
            {:noreply,
             socket
             |> assign(:security_error, nil)
             |> assign(:security_confirm, %{
               block: block,
               downgrades: downgrades,
               posture: SecurityPolicy.one_line(proposed)
             })}
        end
    end
  end

  def handle_event("confirm_security", _params, socket) do
    case socket.assigns.security_confirm do
      %{block: block} -> {:noreply, apply_security(socket, block)}
      _ -> {:noreply, socket}
    end
  end

  def handle_event("cancel_security", _params, socket) do
    {:noreply, assign(socket, security_confirm: nil, security_error: nil)}
  end

  defp apply_security(socket, block) do
    case patch_config(socket.assigns.workspace, %{"agent" => %{"security" => block}}, []) do
      {:ok, ws} ->
        socket
        |> apply_workspace(ws, "Security posture saved.")
        |> assign(:security_error, nil)
        |> assign(:security_confirm, nil)
        |> load_derived()

      {:error, msg} ->
        socket |> assign(:security_error, msg) |> assign(:security_confirm, nil)
    end
  end

  # `mode` and `sandbox.filesystem` are the two enum fields the form writes
  # verbatim into config, and `ValidateConfig` has no `agent.security` branch
  # to catch a bad one. An unrecognized value is not inert: `SecurityPolicy`
  # reads config leniently, so `parse_mode/2` would silently fall back to the
  # *base* default (`:bypass`) — a workspace pinned at `:strict` would be
  # quietly downgraded while `arb config get agent.security` still showed the
  # junk string. Reject it instead, the way `add_provider_override` checks its
  # provider/tier against fixed lists.
  defp validate_security_params(params) do
    mode = params["mode"]
    filesystem = params["sandbox_filesystem"]
    valid_modes = Enum.map(SecurityPolicy.valid_modes(), &Atom.to_string/1)
    valid_filesystems = Enum.map(SecurityPolicy.valid_filesystems(), &Atom.to_string/1)

    cond do
      mode not in valid_modes ->
        {:error,
         "Unknown permission mode #{inspect(mode)} — expected one of #{Enum.join(valid_modes, ", ")}."}

      filesystem not in valid_filesystems ->
        {:error,
         "Unknown filesystem scope #{inspect(filesystem)} — expected one of #{Enum.join(valid_filesystems, ", ")}."}

      true ->
        :ok
    end
  end

  # Normalizes the security form params into an `agent.security` config block.
  # Written whole (rather than field-by-field) so the resolved posture the
  # operator confirmed is exactly what lands. `mode` / `sandbox_filesystem`
  # are pre-validated by `validate_security_params/1`.
  defp security_block(params, categories) do
    safe_defaults = params["safe_defaults"] || %{}

    %{
      "permissions" => %{
        "mode" => params["mode"],
        "allow" => rule_list(params["allow"]),
        "deny" => rule_list(params["deny"]),
        "safe_defaults" =>
          categories
          |> Enum.map(&Atom.to_string/1)
          |> Enum.filter(&(Map.get(safe_defaults, &1) == "true"))
      },
      "sandbox" => %{
        "enabled" => params["sandbox_enabled"] == "true",
        "filesystem" => params["sandbox_filesystem"],
        "network" => params["sandbox_network"] == "true"
      }
    }
  end

  # The config the workspace *would* have, used to resolve the proposed
  # posture through the same layering as the live one — so the confirmation
  # compares effective postures, not raw config fragments.
  defp security_preview_config(ws, block) do
    PatchConfig.deep_merge(ws.config || %{}, %{"agent" => %{"security" => block}})
  end

  # Every way the proposed posture gives up ground relative to the current
  # one, as operator-readable strings. Tightenings (stricter mode, network
  # cut, added deny rules) are deliberately absent — they need no gate.
  #
  # `mode` counts: the deny list is a hard block in every mode
  # (`Claude.Security.settings_argv/1` is emitted even for `:bypass`), but
  # that is not the whole guard. `:strict` maps to `--permission-mode default`
  # / `"defaultMode" => "default"`, under which only allow-listed tools run;
  # `:auto` keeps the interactive classifier; `:bypass`
  # (`--dangerously-skip-permissions`) drops both, so anything not explicitly
  # denied runs. Loosening the mode is therefore the widest-blast-radius
  # control on this form and gets the same confirm step as the rest.
  @mode_strictness %{strict: 2, auto: 1, bypass: 0}

  defp security_downgrades(current, proposed) do
    mode =
      if mode_rank(proposed.permissions.mode) < mode_rank(current.permissions.mode) do
        [
          "Loosens the permission mode (#{current.permissions.mode} → #{proposed.permissions.mode}) — " <>
            mode_loss(proposed.permissions.mode)
        ]
      else
        []
      end

    removed_guards =
      Enum.map(
        current.permissions.safe_defaults -- proposed.permissions.safe_defaults,
        &"Removes the #{&1} safe-default guard"
      )

    removed_denies =
      Enum.map(
        current.permissions.deny -- proposed.permissions.deny,
        &"Removes the deny rule #{&1}"
      )

    sandbox =
      [
        {current.sandbox.enabled and not proposed.sandbox.enabled,
         "Disables the sandbox entirely (sandbox.enabled true → false)"},
        {current.sandbox.filesystem == :worktree and proposed.sandbox.filesystem != :worktree,
         "Widens filesystem access beyond the worktree (sandbox.filesystem worktree → #{proposed.sandbox.filesystem})"},
        {not current.sandbox.network and proposed.sandbox.network,
         "Restores worker network egress (sandbox.network false → true)"}
      ]
      |> Enum.filter(&elem(&1, 0))
      |> Enum.map(&elem(&1, 1))

    mode ++ removed_guards ++ sandbox ++ removed_denies
  end

  defp mode_rank(mode), do: Map.get(@mode_strictness, mode, 0)

  defp mode_loss(:bypass),
    do: "tools are no longer restricted to the allow list and the classifier is skipped"

  defp mode_loss(:auto), do: "tools are no longer restricted to the allow list"
  defp mode_loss(mode), do: "the #{mode} mode is looser"

  # allow/deny rules are entered one per line; blanks are dropped so a
  # trailing newline doesn't become an empty rule.
  defp rule_list(nil), do: []

  defp rule_list(text) when is_binary(text) do
    text |> String.split("\n") |> Enum.map(&String.trim/1) |> Enum.reject(&(&1 == ""))
  end

  defp rule_list(_), do: []

  # The form is seeded from the *resolved* posture, not the raw config block:
  # what the operator sees is what a worker dispatched right now would get,
  # and saving pins exactly that.
  defp rules_text(rules), do: Enum.join(rules, "\n")

  defp security_summary(policy), do: SecurityPolicy.one_line(policy)

  @impl true
  def render(assigns) do
    ~H"""
    <div id={@id} class={pane_class("security", @section)}>
      <div class="rounded-[var(--radius-panel)] border border-solid border-[var(--border-default)] bg-[var(--arb-raised)] px-3 py-[10px]">
        <p class="m-0 font-[family-name:var(--font-mono)] text-[10.5px] tracking-[0.06em] text-[var(--text-label)] uppercase">
          Effective workspace-wide posture right now
        </p>
        <p class="mt-[3px] mb-0 font-[family-name:var(--font-mono)] text-[12px] text-[var(--text-body)]">
          {security_summary(@security_policy)}
        </p>
        <div class="mt-2 flex flex-wrap gap-1">
          <span class={posture_chip(nil)}>mode={@security_policy.permissions.mode}</span>
          <span class={posture_chip(@security_policy.sandbox.enabled)}>
            sandbox={if @security_policy.sandbox.enabled, do: "on", else: "OFF"}
          </span>
          <span class={posture_chip(@security_policy.sandbox.filesystem == :worktree)}>
            fs={@security_policy.sandbox.filesystem}
          </span>
          <span class={posture_chip(nil)}>
            net={if @security_policy.sandbox.network, do: "on", else: "tools-off"}
          </span>
          <span class={
            posture_chip(
              length(@security_policy.permissions.safe_defaults) ==
                length(@safe_default_categories)
            )
          }>
            safe_defaults={length(@security_policy.permissions.safe_defaults)}/{length(
              @safe_default_categories
            )}
          </span>
        </div>

        <%!-- agent.security.repos.<repo> layers on top of the line above
             for dispatches against that repo, so the workspace-wide
             posture is not the whole story. Read-only: the form below
             edits the workspace layer only. --%>
        <div :if={@security_repo_postures != []} id="security-repo-postures" class="mt-3">
          <p class="m-0 font-[family-name:var(--font-mono)] text-[10.5px] tracking-[0.06em] text-[var(--text-label)] uppercase">
            Per-repo overrides (agent.security.repos.*) — applied on top of the line above; edit via
            <code>arb config</code>
          </p>
          <ul class="mt-1 flex list-none flex-col gap-[2px] p-0">
            <li
              :for={{repo, policy} <- @security_repo_postures}
              class="flex flex-wrap gap-x-2 font-[family-name:var(--font-mono)] text-[11px] text-[var(--text-secondary)]"
            >
              <span class="text-[var(--text-label)]">{repo}:</span>
              <span>{security_summary(policy)}</span>
            </li>
          </ul>
        </div>
      </div>

      <.form for={%{}} as={:security} phx-submit="save_security" phx-target={@myself}>
        <.rows>
          <.setting_row
            name="Permission mode"
            consequence="permissions.mode — how a worker's tool calls are gated; bypass runs every call unprompted, so nothing but the deny rules stops it"
          >
            <:control>
              <Forms.select
                name="security[mode]"
                options={Enum.map(@security_modes, &{Atom.to_string(&1), Atom.to_string(&1)})}
                value={Atom.to_string(@security_policy.permissions.mode)}
                size="sm"
                class="w-[180px]"
              />
            </:control>
          </.setting_row>

          <.setting_row
            name="Filesystem scope"
            consequence="sandbox.filesystem — worktree confines writes to the worker's own checkout; anything else lets a worker write outside it and corrupt sibling workers"
          >
            <:control>
              <Forms.select
                name="security[sandbox_filesystem]"
                options={Enum.map(@security_filesystems, &{Atom.to_string(&1), Atom.to_string(&1)})}
                value={Atom.to_string(@security_policy.sandbox.filesystem)}
                size="sm"
                class="w-[180px]"
              />
            </:control>
          </.setting_row>

          <.toggle_row
            name="Sandbox enabled"
            consequence="sandbox.enabled — off runs every worker directly on this host with no filesystem or network containment at all"
            field="security[sandbox_enabled]"
            checked={@security_policy.sandbox.enabled}
          />

          <.toggle_row
            name="Network egress allowed"
            consequence="sandbox.network — off cuts a worker's outbound network, so it cannot fetch dependencies or reach a forge"
            field="security[sandbox_network]"
            checked={@security_policy.sandbox.network}
          />

          <.setting_row
            name="Safe-default guards"
            consequence="permissions.safe_defaults — the destructive-op categories every adapter denies outright; unchecking one hands that class of command to every worker"
          >
            <:below>
              <div class="flex flex-wrap gap-x-4 gap-y-1">
                <label
                  :for={category <- @safe_default_categories}
                  class="flex cursor-pointer items-center gap-[7px] font-[family-name:var(--font-mono)] text-[11.5px] text-[var(--text-body)]"
                >
                  <input type="hidden" name={"security[safe_defaults][#{category}]"} value="false" />
                  <input
                    type="checkbox"
                    name={"security[safe_defaults][#{category}]"}
                    value="true"
                    checked={category in @security_policy.permissions.safe_defaults}
                    class="peer sr-only"
                  />
                  <%!-- The tick is transparent until the box is ticked: on this
                       screen a checkmark means "this destructive-op guard is
                       on", so an unchecked guard must not show one. --%>
                  <span class="inline-flex size-[14px] flex-none items-center justify-center rounded-[var(--radius-chip)] border border-solid border-[var(--border-strong)] text-[9px] text-transparent peer-checked:border-[var(--accent-primary)] peer-checked:bg-[var(--accent-primary)] peer-checked:text-[var(--accent-primary-ink)]">
                    ✓
                  </span>
                  {category}
                </label>
              </div>
            </:below>
          </.setting_row>

          <.setting_row
            name="Allow rules"
            consequence="permissions.allow — one rule per line, each pre-approving a tool call a worker would otherwise be stopped on"
          >
            <:below>
              <Forms.textarea
                name="security[allow]"
                value={rules_text(@security_policy.permissions.allow)}
                rows={4}
                placeholder="Bash(mix test:*)"
              />
            </:below>
          </.setting_row>

          <.setting_row
            name="Deny rules"
            consequence="permissions.deny — one rule per line; a matching call is refused even in bypass mode, so this is the last guard that still holds"
          >
            <:below>
              <Forms.textarea
                name="security[deny]"
                value={rules_text(@security_policy.permissions.deny)}
                rows={4}
                placeholder="Bash(rm -rf:*)"
              />
            </:below>
          </.setting_row>
        </.rows>

        <div class="mt-3 flex items-center gap-3">
          <Core.button type="submit" variant="danger" size="sm">
            Review security changes
          </Core.button>
          <p :if={@security_error} class="m-0 text-[11px] text-[var(--arb-fail-text)]">
            {@security_error}
          </p>
        </div>
      </.form>

      <%!-- Security-downgrade confirmation. The plain submit above never
           writes when a guard is being removed; this is the only path that
           applies such a change, and it names each guard explicitly. --%>
      <div :if={@security_confirm} class="modal modal-open" id="security-confirm-modal">
        <div class="modal-box border border-solid border-[var(--arb-fail)] bg-[var(--surface-chrome)]">
          <h3 class="m-0 flex items-center gap-2 text-[14px] font-medium text-[var(--text-title)]">
            <Core.icon name="hero-shield-exclamation" size={16} class="text-[var(--arb-fail-text)]" />
            Weaken this workspace's security posture?
          </h3>
          <p class="mt-1 mb-0 text-[12px] text-[var(--text-secondary)]">
            These changes remove guardrails from every worker this workspace dispatches on this
            machine:
          </p>
          <ul class="mt-2 flex list-disc flex-col gap-1 pl-5 text-[12px] text-[var(--arb-fail-text)]">
            <li :for={downgrade <- @security_confirm.downgrades}>{downgrade}</li>
          </ul>
          <p class="mt-3 mb-0 text-[11px] text-[var(--text-label)]">
            Resulting workspace-wide posture:
            <span class="font-[family-name:var(--font-mono)]">{@security_confirm.posture}</span>
          </p>
          <p
            :if={@security_repo_postures != []}
            class="mt-1 mb-0 text-[11px] text-[var(--arb-attention)]"
          >
            {length(@security_repo_postures)} per-repo override(s) still layer on top of this — see
            <code>agent.security.repos.*</code>
            in the posture panel.
          </p>
          <div class="modal-action">
            <Core.button type="button" size="sm" phx-click="cancel_security" phx-target={@myself}>
              Cancel
            </Core.button>
            <Core.button
              type="button"
              variant="danger"
              size="sm"
              phx-click="confirm_security"
              phx-target={@myself}
            >
              I understand — weaken the posture
            </Core.button>
          </div>
        </div>
        <div class="modal-backdrop" phx-click="cancel_security" phx-target={@myself}></div>
      </div>
    </div>
    """
  end

  # A guard that is on reads as pass, off as fail; the two informational chips
  # (mode, net) are neutral because neither value is by itself a weakening.
  defp posture_chip(state) do
    [
      "inline-flex items-center rounded-[var(--radius-chip)] border border-solid px-[6px] py-[1px] font-[family-name:var(--font-mono)] text-[10.5px]",
      case state do
        true -> "border-[var(--arb-live)] text-[var(--arb-live)]"
        false -> "border-[var(--arb-fail)] text-[var(--arb-fail-text)]"
        nil -> "border-[var(--border-default)] text-[var(--text-secondary)]"
      end
    ]
  end
end
