defmodule ArbiterWeb.SkillIndexLive do
  @moduledoc """
  Skill registry management at `/skills` — the operator's authoring UI for the
  system-wide, user-authored worker skill library (epic bd-xfc55c, child
  bd-cj6i08), redesigned per the operator-console handoff, README §7
  (bd-ahuwj5).

  List + detail split: the left list shows every skill with its
  materialized/invoked counts; the right pane shows the selected skill's
  detail, including two `Toggle`s that write through to the skill
  record — `auto-invoke` (`activation_mode`) and `code-producing tasks only`
  (`code_only`) — each carrying its one-line consequence. A skill that has
  never been invoked shows an `EmptyState` explaining the loop pass will
  propose retiring it.

  Full CRUD remains: an inline create/edit form built around a plain
  **textarea** to write or paste a skill body, plus delete, both reachable
  from the detail pane's `Edit`/`Delete` actions (and `New skill` in the
  header).

  Author-time guardrail: when the entered name collides with a bundled skill
  (spike bd-5tc1s0 finding #3 — workers always see the ~20 built-ins) a warning
  is shown, but saving is still allowed.
  """

  use ArbiterWeb, :live_view

  require Ash.Query

  alias Arbiter.Skills

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(:live, connected?(socket))
     |> assign(:selected_id, nil)
     # editing: nil = form closed, :new = create, %Skill{} = editing that row
     |> assign(:editing, nil)
     |> assign(:form_name, "")
     |> assign(:form_body, "")
     |> assign(:form_metadata, "")
     |> assign(:form_activation, "situational")
     |> assign(:form_code_only, false)
     |> assign(:form_error, nil)
     |> assign(:name_warning, nil)
     |> refresh()}
  end

  @impl true
  def handle_event("select", %{"id" => id}, socket) do
    {:noreply, assign(socket, :selected_id, id)}
  end

  def handle_event("new", _params, socket) do
    {:noreply,
     socket
     |> assign(:editing, :new)
     |> assign(
       form_name: "",
       form_body: "",
       form_metadata: "",
       form_activation: "situational",
       form_code_only: false,
       form_error: nil,
       name_warning: nil
     )}
  end

  def handle_event("edit", %{"id" => id}, socket) do
    case Skills.get_skill(id) do
      {:ok, skill} ->
        {:noreply,
         socket
         |> assign(:editing, skill)
         |> assign(
           form_name: skill.name,
           form_body: skill.body,
           form_metadata: metadata_to_text(skill.metadata),
           form_activation: to_string(skill.activation_mode),
           form_code_only: skill.code_only == true,
           form_error: nil,
           name_warning: Skills.bundled_collision(skill.name)
         )}

      {:error, :not_found} ->
        {:noreply, put_flash(socket, :error, "Skill not found.")}
    end
  end

  def handle_event("cancel", _params, socket) do
    {:noreply, assign(socket, editing: nil, form_error: nil, name_warning: nil)}
  end

  # Live name-collision feedback as the operator types.
  def handle_event("validate", %{"skill" => params}, socket) do
    name = params["name"] |> to_string() |> String.trim()

    {:noreply,
     assign(socket,
       form_name: name,
       form_body: params["body"] || "",
       form_metadata: params["metadata"] || "",
       form_activation: params["activation_mode"] || "situational",
       form_code_only: params["code_only"] == "true",
       name_warning: Skills.bundled_collision(name)
     )}
  end

  def handle_event("save", %{"skill" => params}, socket) do
    name = params["name"] |> to_string() |> String.trim()
    body = params["body"] |> to_string()
    metadata_text = params["metadata"] |> to_string() |> String.trim()
    activation = params["activation_mode"] |> to_string()
    code_only = params["code_only"] == "true"

    with {:ok, metadata} <- parse_metadata(metadata_text) do
      attrs = %{
        name: name,
        body: body,
        metadata: metadata,
        activation_mode: activation,
        code_only: code_only
      }

      persist(socket, socket.assigns.editing, attrs)
    else
      {:error, msg} ->
        {:noreply,
         assign(socket,
           form_name: name,
           form_body: body,
           form_metadata: metadata_text,
           form_activation: activation,
           form_code_only: code_only,
           form_error: msg
         )}
    end
  end

  def handle_event("delete", %{"id" => id}, socket) do
    case Skills.delete_skill(id) do
      :ok ->
        {:noreply,
         socket
         |> put_flash(:info, "Deleted skill.")
         |> assign(editing: nil, selected_id: nil)
         |> refresh()}

      {:error, _} ->
        {:noreply, put_flash(socket, :error, "Could not delete skill.")}
    end
  end

  def handle_event("toggle_auto_invoke", %{"id" => id}, socket) do
    toggle_skill(socket, id, fn skill ->
      new_mode = if skill.activation_mode == :always_on, do: :situational, else: :always_on
      %{activation_mode: new_mode}
    end)
  end

  def handle_event("toggle_code_only", %{"id" => id}, socket) do
    toggle_skill(socket, id, fn skill -> %{code_only: !skill.code_only} end)
  end

  defp toggle_skill(socket, id, attrs_fun) do
    case Skills.get_skill(id) do
      {:ok, skill} ->
        case Skills.update_skill(skill, attrs_fun.(skill)) do
          {:ok, _updated} -> {:noreply, refresh(socket)}
          {:error, _} -> {:noreply, put_flash(socket, :error, "Could not update skill.")}
        end

      {:error, :not_found} ->
        {:noreply, put_flash(socket, :error, "Skill not found.")}
    end
  end

  # ---- persistence -------------------------------------------------------

  defp persist(socket, :new, attrs) do
    case Skills.create_skill(attrs) do
      {:ok, skill} -> saved(socket, skill, "Created")
      {:error, err} -> form_failed(socket, attrs, err)
    end
  end

  defp persist(socket, %Skills.Skill{} = skill, attrs) do
    case Skills.update_skill(skill, attrs) do
      {:ok, updated} -> saved(socket, updated, "Updated")
      {:error, err} -> form_failed(socket, attrs, err)
    end
  end

  defp saved(socket, skill, verb) do
    flash =
      case Skills.bundled_collision(skill.name) do
        nil -> "#{verb} skill #{skill.name}."
        warning -> "#{verb} skill #{skill.name}. Note: #{warning}"
      end

    {:noreply,
     socket
     |> assign(editing: nil, form_error: nil, name_warning: nil, selected_id: skill.id)
     |> put_flash(:info, flash)
     |> refresh()}
  end

  defp form_failed(socket, attrs, err) do
    {:noreply,
     assign(socket,
       form_name: attrs.name,
       form_body: attrs.body,
       form_metadata: metadata_to_text(attrs.metadata),
       form_activation: to_string(attrs.activation_mode),
       form_code_only: attrs.code_only == true,
       form_error: error_message(err)
     )}
  end

  defp refresh(socket) do
    skills = Skills.list_skills()

    socket
    |> assign(:skills, skills)
    |> assign(:usage_by_skill_id, load_usage_by_skill_id())
    |> assign(:selected_id, reselect(socket.assigns[:selected_id], skills))
  end

  defp reselect(selected_id, skills) do
    if Enum.any?(skills, &(&1.id == selected_id)) do
      selected_id
    else
      case skills do
        [first | _] -> first.id
        [] -> nil
      end
    end
  end

  # Load every skill's usage row in one query, indexed by skill_id — avoids an
  # N-query fan-out per row on every render (mount, and every LiveView
  # event/PubSub update thereafter).
  defp load_usage_by_skill_id do
    Arbiter.Skills.Usage
    |> Ash.read!()
    |> Map.new(&{&1.skill_id, &1})
  rescue
    _ -> %{}
  end

  # ---- helpers -----------------------------------------------------------

  defp parse_metadata(""), do: {:ok, %{}}

  defp parse_metadata(text) do
    case Jason.decode(text) do
      {:ok, map} when is_map(map) -> {:ok, map}
      {:ok, _} -> {:error, "Metadata must be a JSON object."}
      {:error, _} -> {:error, "Metadata must be valid JSON (or blank)."}
    end
  end

  defp metadata_to_text(m) when is_map(m) and map_size(m) > 0, do: Jason.encode!(m)
  defp metadata_to_text(_), do: ""

  defp metadata_gist(m) when is_map(m) and map_size(m) > 0 do
    case Map.get(m, "description") do
      d when is_binary(d) and d != "" -> d
      _ -> Jason.encode!(m)
    end
  end

  defp metadata_gist(_), do: nil

  defp error_message(%Ash.Error.Invalid{errors: errors}) do
    errors |> Enum.map(&Exception.message/1) |> Enum.join("; ")
  end

  defp error_message(err) when is_exception(err), do: Exception.message(err)
  defp error_message(err), do: inspect(err)

  # Read usage counts for a skill out of the preloaded @usage_by_skill_id map
  # (see refresh/1); returns 0 if the skill has no usage row yet.
  defp materialize_count(usage_by_skill_id, skill) do
    case Map.get(usage_by_skill_id, skill.id) do
      nil -> 0
      usage -> usage.materialize_count
    end
  end

  defp invoke_count(usage_by_skill_id, skill) do
    case Map.get(usage_by_skill_id, skill.id) do
      nil -> 0
      usage -> usage.invoke_count
    end
  end

  defp invoke_rate(usage_by_skill_id, skill) do
    materialized = materialize_count(usage_by_skill_id, skill)
    invoked = invoke_count(usage_by_skill_id, skill)

    if materialized > 0 do
      "#{round(invoked / materialized * 100)}%"
    else
      "0%"
    end
  end

  defp scope_label(%{code_only: true}), do: "feature · bug · chore"
  defp scope_label(_), do: "all task types"

  defp selected_skill(skills, selected_id) do
    Enum.find(skills, fn skill -> skill.id == selected_id end) || List.first(skills)
  end

  @impl true
  def render(assigns) do
    assigns = assign(assigns, :selected, selected_skill(assigns.skills, assigns.selected_id))

    ~H"""
    <Layouts.app flash={@flash} current_path={@current_path} quotas={@quotas}>
      <div class="p-4 sm:p-6 max-w-7xl mx-auto space-y-6">
        <ArbiterWeb.CoreComponents.Domain.index_header
          icon="hero-clipboard-document-list"
          title="Skills"
          count={length(@skills)}
          subtitle="System-wide, user-authored worker skill library. Materialized into worker worktrees at dispatch."
        >
          <:actions>
            <div class="flex items-center gap-2">
              <ArbiterWeb.CoreComponents.Feedback.live_badge id="skills-live" live={@live} />
              <ArbiterWeb.CoreComponents.Core.button
                :if={@editing == nil}
                phx-click="new"
                variant="primary"
                size="sm"
              >
                <:icon><ArbiterWeb.CoreComponents.Core.icon name="hero-plus" size={13} /></:icon>
                New skill
              </ArbiterWeb.CoreComponents.Core.button>
            </div>
          </:actions>
        </ArbiterWeb.CoreComponents.Domain.index_header>

        <section :if={@editing != nil} class="card bg-base-200 border border-base-300 shadow-sm">
          <div class="card-body p-4 gap-3">
            <h2 class="font-semibold text-sm">
              {if @editing == :new, do: "Create a skill", else: "Edit skill"}
            </h2>
            <.form for={%{}} as={:skill} phx-submit="save" phx-change="validate" class="space-y-2">
              <.input
                name="skill[name]"
                label="Name (kebab-case — becomes the /name slash command)"
                value={@form_name}
                required
                placeholder="test-driven-development"
              />

              <p :if={@name_warning} class="text-xs text-warning flex items-start gap-1">
                <ArbiterWeb.CoreComponents.Core.icon
                  name="hero-exclamation-triangle"
                  size={14}
                  class="shrink-0"
                />
                <span>{@name_warning}</span>
              </p>

              <.input
                type="textarea"
                name="skill[body]"
                label="Body (Markdown — written to .claude/skills/<name>/SKILL.md)"
                value={@form_body}
                rows="16"
                class="w-full textarea font-mono text-sm"
                required
                placeholder="# When to use&#10;..."
              />

              <.input
                name="skill[metadata]"
                label="Metadata (optional JSON object, e.g. {&quot;description&quot;: &quot;...&quot;, &quot;tags&quot;: [&quot;tdd&quot;]})"
                value={@form_metadata}
                placeholder={~s({"description": "..."})}
              />

              <div class="flex flex-wrap items-end gap-4">
                <.input
                  type="select"
                  name="skill[activation_mode]"
                  label="Activation"
                  value={@form_activation}
                  options={[
                    {"Situational — advertised, agent decides", "situational"},
                    {"Always-on — auto-invoke /name in the worker prompt", "always_on"}
                  ]}
                />
                <.input
                  type="checkbox"
                  name="skill[code_only]"
                  label="Code-only (skip decision/task/epic)"
                  checked={@form_code_only}
                />
              </div>

              <p :if={@form_error} class="text-sm text-error">{@form_error}</p>

              <div class="flex gap-2 mt-1">
                <ArbiterWeb.CoreComponents.Core.button type="submit" variant="primary" size="sm">
                  {if @editing == :new, do: "Create", else: "Save"}
                </ArbiterWeb.CoreComponents.Core.button>
                <ArbiterWeb.CoreComponents.Core.button
                  type="button"
                  variant="ghost"
                  size="sm"
                  phx-click="cancel"
                >
                  Cancel
                </ArbiterWeb.CoreComponents.Core.button>
              </div>
            </.form>
          </div>
        </section>

        <ArbiterWeb.CoreComponents.Feedback.empty_state :if={@skills == []} icon="hero-sparkles">
          No skills yet. Create one to build the worker skill library.
        </ArbiterWeb.CoreComponents.Feedback.empty_state>

        <div
          :if={@skills != []}
          class="grid grid-cols-[minmax(0,320px)_minmax(0,1fr)] gap-px bg-[var(--arb-line)] border border-[var(--arb-line)] rounded-[4px] overflow-hidden"
        >
          <ul
            id="skills-list"
            class="bg-[var(--arb-panel)] p-[10px] flex flex-col gap-1.5 list-none m-0"
          >
            <li
              :for={skill <- @skills}
              id={"skill-row-#{skill.id}"}
              phx-click="select"
              phx-value-id={skill.id}
              class={[
                "px-[11px] py-[9px] rounded-[3px] cursor-pointer border border-transparent",
                @selected && @selected.id == skill.id &&
                  "bg-[var(--arb-raised)] border-[var(--arb-line-strong)] border-l-2 border-l-[var(--accent-primary)]",
                !(@selected && @selected.id == skill.id) && "hover:bg-[var(--arb-raised-hover)]"
              ]}
            >
              <div class="flex items-center gap-1.5">
                <span class="font-medium text-[12px] font-[family-name:var(--font-mono)] text-[var(--arb-text-body)]">
                  {skill.name}
                </span>
                <ArbiterWeb.CoreComponents.Core.icon
                  :if={Skills.bundled_skill?(skill.name)}
                  name="hero-exclamation-triangle"
                  size={10}
                  color="var(--arb-attention)"
                  title="Collides with a bundled skill name"
                />
                <span
                  class={[
                    "ml-auto text-[10px] font-[family-name:var(--font-mono)] tabular-nums whitespace-nowrap",
                    invoke_count(@usage_by_skill_id, skill) == 0 && "text-[var(--arb-text-ghost)]",
                    invoke_count(@usage_by_skill_id, skill) > 0 && "text-[var(--text-label)]"
                  ]}
                  title="Materialized / Invoked"
                >
                  {materialize_count(@usage_by_skill_id, skill)} / {invoke_count(
                    @usage_by_skill_id,
                    skill
                  )}
                </span>
              </div>
              <div class="flex items-center gap-1 flex-wrap mt-1">
                <.type_tag :if={skill.activation_mode == :always_on} type="auto" />
                <.type_tag :if={skill.code_only} type="code only" />
                <.type_tag
                  :if={invoke_count(@usage_by_skill_id, skill) == 0}
                  type="never invoked"
                  dashed
                />
              </div>
            </li>
          </ul>

          <div
            :if={@selected}
            id="skill-detail"
            class="bg-[var(--arb-chrome)] p-[18px] pb-[22px] flex flex-col gap-4"
          >
            <div class="flex items-start justify-between gap-3">
              <div class="min-w-0">
                <h2 class="font-medium text-[15px] font-[family-name:var(--font-mono)] text-[var(--arb-text-body)] m-0">
                  {@selected.name}
                </h2>
                <p
                  :if={metadata_gist(@selected.metadata)}
                  class="mt-1 text-[12.5px] leading-[1.6] font-[family-name:var(--font-sans)] text-[var(--text-secondary)] max-w-[62ch]"
                >
                  {metadata_gist(@selected.metadata)}
                </p>
              </div>
              <div class="flex items-center gap-2 flex-none">
                <ArbiterWeb.CoreComponents.Core.button
                  variant="secondary"
                  size="sm"
                  phx-click="edit"
                  phx-value-id={@selected.id}
                >
                  Edit
                </ArbiterWeb.CoreComponents.Core.button>
                <ArbiterWeb.CoreComponents.Core.button
                  variant="danger"
                  size="sm"
                  phx-click="delete"
                  phx-value-id={@selected.id}
                  data-confirm={"Delete skill #{@selected.name}?"}
                >
                  Delete
                </ArbiterWeb.CoreComponents.Core.button>
              </div>
            </div>

            <.data_list>
              <:item label="materialized">{materialize_count(@usage_by_skill_id, @selected)}</:item>
              <:item label="invoked">{invoke_count(@usage_by_skill_id, @selected)}</:item>
              <:item label="invoke rate">{invoke_rate(@usage_by_skill_id, @selected)}</:item>
              <:item label="scope">{scope_label(@selected)}</:item>
            </.data_list>

            <div class="border-t border-[var(--arb-line)] pt-4 flex flex-col gap-4">
              <.toggle
                id="toggle-auto-invoke"
                checked={@selected.activation_mode == :always_on}
                label="Auto-invoke"
                hint="added to every worker prompt where it applies"
                phx-click="toggle_auto_invoke"
                phx-value-id={@selected.id}
              />
              <.toggle
                id="toggle-code-only"
                checked={@selected.code_only == true}
                label="Code-producing tasks only"
                hint="skipped on decision and epic types"
                phx-click="toggle_code_only"
                phx-value-id={@selected.id}
              />
            </div>

            <ArbiterWeb.CoreComponents.Feedback.empty_state
              :if={invoke_count(@usage_by_skill_id, @selected) == 0}
              icon="hero-exclamation-triangle"
              detail={"materialized #{materialize_count(@usage_by_skill_id, @selected)} times, invoked 0"}
            >
              This skill has never been invoked. The loop pass will propose retiring it.
            </ArbiterWeb.CoreComponents.Feedback.empty_state>
          </div>
        </div>

        <ArbiterWeb.CoreComponents.Navigation.back_link />
      </div>
    </Layouts.app>
    """
  end
end
