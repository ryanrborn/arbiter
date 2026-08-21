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

  import ArbiterWeb.WorkspaceDetail.Shared

  alias Arbiter.Agents.SecurityPolicy
  alias Arbiter.Tasks.Workspace.Changes.PatchConfig

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
    <section id={@id} class="card bg-base-200 border-2 border-warning/40 shadow-sm">
      <div class="card-body p-4 gap-3">
        <h2 class="font-semibold flex items-center gap-2">
          <.icon name="hero-shield-exclamation" class="size-5 text-warning" />
          Advanced — worker security
        </h2>
        <p class="text-xs text-base-content/50 -mt-1">
          <code>agent.security.*</code>
          controls the filesystem, network and destructive-action guardrails applied to every
          worker this workspace dispatches on this machine. Weakening a guard needs an explicit
          confirmation.
        </p>

        <div class="rounded-box border border-base-300 bg-base-100 px-3 py-2">
          <p class="text-xs uppercase tracking-wide text-base-content/50">
            Effective workspace-wide posture right now
          </p>
          <p class="font-mono text-sm mt-0.5">{security_summary(@security_policy)}</p>
          <div class="flex flex-wrap gap-1 mt-2">
            <span class="badge badge-sm badge-outline font-mono">
              mode={@security_policy.permissions.mode}
            </span>
            <span class={[
              "badge badge-sm font-mono",
              if(@security_policy.sandbox.enabled, do: "badge-success", else: "badge-error")
            ]}>
              sandbox={if @security_policy.sandbox.enabled, do: "on", else: "OFF"}
            </span>
            <span class={[
              "badge badge-sm font-mono",
              if(@security_policy.sandbox.filesystem == :worktree,
                do: "badge-success",
                else: "badge-error"
              )
            ]}>
              fs={@security_policy.sandbox.filesystem}
            </span>
            <span class="badge badge-sm badge-outline font-mono">
              net={if @security_policy.sandbox.network, do: "on", else: "tools-off"}
            </span>
            <span class={[
              "badge badge-sm font-mono",
              if(
                length(@security_policy.permissions.safe_defaults) ==
                  length(@safe_default_categories),
                do: "badge-success",
                else: "badge-warning"
              )
            ]}>
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
            <p class="text-xs uppercase tracking-wide text-base-content/50">
              Per-repo overrides (<code>agent.security.repos.*</code>) — applied on top of the
              line above; edit via <code>arb config</code>
            </p>
            <ul class="mt-1 flex flex-col gap-0.5">
              <li
                :for={{repo, policy} <- @security_repo_postures}
                class="font-mono text-xs flex flex-wrap gap-x-2"
              >
                <span class="text-base-content/60">{repo}:</span>
                <span>{security_summary(policy)}</span>
              </li>
            </ul>
          </div>
        </div>

        <details class="collapse collapse-arrow border border-base-300 bg-base-100">
          <summary class="collapse-title text-sm font-medium">
            Edit security posture
          </summary>
          <div class="collapse-content">
            <.form
              for={%{}}
              as={:security}
              phx-submit="save_security"
              phx-target={@myself}
              class="space-y-3"
            >
              <div class="grid sm:grid-cols-2 gap-x-4">
                <.input
                  type="select"
                  name="security[mode]"
                  label="Permission mode (permissions.mode)"
                  options={Enum.map(@security_modes, &{Atom.to_string(&1), Atom.to_string(&1)})}
                  value={Atom.to_string(@security_policy.permissions.mode)}
                />
                <.input
                  type="select"
                  name="security[sandbox_filesystem]"
                  label="Filesystem scope (sandbox.filesystem)"
                  options={Enum.map(@security_filesystems, &{Atom.to_string(&1), Atom.to_string(&1)})}
                  value={Atom.to_string(@security_policy.sandbox.filesystem)}
                />
                <label class="fieldset flex items-center gap-2 mt-2">
                  <input type="hidden" name="security[sandbox_enabled]" value="false" />
                  <input
                    type="checkbox"
                    name="security[sandbox_enabled]"
                    value="true"
                    checked={@security_policy.sandbox.enabled}
                    class="toggle toggle-sm toggle-primary"
                  />
                  <span class="text-sm">Sandbox enabled (sandbox.enabled)</span>
                </label>
                <label class="fieldset flex items-center gap-2 mt-2">
                  <input type="hidden" name="security[sandbox_network]" value="false" />
                  <input
                    type="checkbox"
                    name="security[sandbox_network]"
                    value="true"
                    checked={@security_policy.sandbox.network}
                    class="toggle toggle-sm toggle-primary"
                  />
                  <span class="text-sm">Network egress allowed (sandbox.network)</span>
                </label>
              </div>

              <fieldset class="fieldset">
                <legend class="label">Safe-default guards (permissions.safe_defaults)</legend>
                <p class="text-xs text-base-content/50">
                  The baseline destructive-op categories every adapter denies. Unchecking one
                  requires confirmation.
                </p>
                <div class="flex flex-wrap gap-x-4 gap-y-1 mt-1">
                  <label
                    :for={category <- @safe_default_categories}
                    class="flex items-center gap-2 text-sm cursor-pointer"
                  >
                    <input type="hidden" name={"security[safe_defaults][#{category}]"} value="false" />
                    <input
                      type="checkbox"
                      name={"security[safe_defaults][#{category}]"}
                      value="true"
                      checked={category in @security_policy.permissions.safe_defaults}
                      class="checkbox checkbox-sm"
                    />
                    <code>{category}</code>
                  </label>
                </div>
              </fieldset>

              <div class="grid sm:grid-cols-2 gap-x-4">
                <.input
                  type="textarea"
                  name="security[allow]"
                  label="Allow rules (permissions.allow) — one per line"
                  value={rules_text(@security_policy.permissions.allow)}
                  rows="4"
                />
                <.input
                  type="textarea"
                  name="security[deny]"
                  label="Deny rules (permissions.deny) — one per line"
                  value={rules_text(@security_policy.permissions.deny)}
                  rows="4"
                />
              </div>

              <div class="flex items-center gap-3">
                <.button type="submit" class="btn btn-sm btn-warning">
                  Review security changes
                </.button>
                <p :if={@security_error} class="text-sm text-error">{@security_error}</p>
              </div>
            </.form>
          </div>
        </details>

        <%!-- Security-downgrade confirmation. The plain submit above never
             writes when a guard is being removed; this is the only path that
             applies such a change, and it names each guard explicitly. --%>
        <div :if={@security_confirm} class="modal modal-open" id="security-confirm-modal">
          <div class="modal-box border-2 border-error/50">
            <h3 class="font-semibold text-lg mb-1 flex items-center gap-2">
              <.icon name="hero-shield-exclamation" class="size-5 text-error" />
              Weaken this workspace's security posture?
            </h3>
            <p class="text-sm text-base-content/70">
              These changes remove guardrails from every worker this workspace dispatches on this
              machine:
            </p>
            <ul class="list-disc list-inside text-sm text-error mt-2 space-y-1">
              <li :for={downgrade <- @security_confirm.downgrades}>{downgrade}</li>
            </ul>
            <p class="text-xs text-base-content/50 mt-3">
              Resulting workspace-wide posture:
              <span class="font-mono">{@security_confirm.posture}</span>
            </p>
            <p :if={@security_repo_postures != []} class="text-xs text-warning mt-1">
              {length(@security_repo_postures)} per-repo override(s) still layer on top of this — see
              <code>agent.security.repos.*</code>
              in the posture panel.
            </p>
            <div class="modal-action">
              <.button
                type="button"
                phx-click="cancel_security"
                phx-target={@myself}
                class="btn btn-sm btn-ghost"
              >
                Cancel
              </.button>
              <.button
                type="button"
                phx-click="confirm_security"
                phx-target={@myself}
                class="btn btn-sm btn-error"
              >
                I understand — weaken the posture
              </.button>
            </div>
          </div>
          <div class="modal-backdrop" phx-click="cancel_security" phx-target={@myself}></div>
        </div>
      </div>
    </section>
    """
  end
end
