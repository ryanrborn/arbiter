defmodule ArbiterWeb.SkillIndexLive do
  @moduledoc """
  Skill registry management at `/skills` — the operator's authoring UI for the
  system-wide, user-authored worker skill library (epic bd-xfc55c, child
  bd-cj6i08).

  Full CRUD in one page: lists every skill, with an inline create/edit form
  built around a plain **textarea** to write or paste a skill body, plus delete.
  Skills are system-wide (not workspace-scoped) — one definition is shared
  across the whole arbiter system.

  Author-time guardrail: when the entered name collides with a bundled skill
  (spike bd-5tc1s0 finding #3 — workers always see the ~20 built-ins) a warning
  is shown, but saving is still allowed.
  """

  use ArbiterWeb, :live_view

  alias Arbiter.Skills

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(:live, connected?(socket))
     # editing: nil = form closed, :new = create, %Skill{} = editing that row
     |> assign(:editing, nil)
     |> assign(:form_name, "")
     |> assign(:form_body, "")
     |> assign(:form_metadata, "")
     |> assign(:form_error, nil)
     |> assign(:name_warning, nil)
     |> refresh()}
  end

  @impl true
  def handle_event("new", _params, socket) do
    {:noreply,
     socket
     |> assign(:editing, :new)
     |> assign(
       form_name: "",
       form_body: "",
       form_metadata: "",
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
       name_warning: Skills.bundled_collision(name)
     )}
  end

  def handle_event("save", %{"skill" => params}, socket) do
    name = params["name"] |> to_string() |> String.trim()
    body = params["body"] |> to_string()
    metadata_text = params["metadata"] |> to_string() |> String.trim()

    with {:ok, metadata} <- parse_metadata(metadata_text) do
      attrs = %{name: name, body: body, metadata: metadata}
      persist(socket, socket.assigns.editing, attrs)
    else
      {:error, msg} ->
        {:noreply,
         assign(socket,
           form_name: name,
           form_body: body,
           form_metadata: metadata_text,
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
         |> assign(editing: nil)
         |> refresh()}

      {:error, _} ->
        {:noreply, put_flash(socket, :error, "Could not delete skill.")}
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
     |> assign(editing: nil, form_error: nil, name_warning: nil)
     |> put_flash(:info, flash)
     |> refresh()}
  end

  defp form_failed(socket, attrs, err) do
    {:noreply,
     assign(socket,
       form_name: attrs.name,
       form_body: attrs.body,
       form_metadata: metadata_to_text(attrs.metadata),
       form_error: error_message(err)
     )}
  end

  defp refresh(socket), do: assign(socket, :skills, Skills.list_skills())

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

  defp error_message(%Ash.Error.Invalid{errors: errors}) do
    errors |> Enum.map(&Exception.message/1) |> Enum.join("; ")
  end

  defp error_message(err) when is_exception(err), do: Exception.message(err)
  defp error_message(err), do: inspect(err)

  defp metadata_summary(m) when is_map(m) and map_size(m) > 0 do
    case Map.get(m, "description") do
      d when is_binary(d) and d != "" -> d
      _ -> Jason.encode!(m)
    end
  end

  defp metadata_summary(_), do: nil

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_path={@current_path} quota={@quota}>
      <div class="p-4 sm:p-6 max-w-7xl mx-auto space-y-6">
        <.index_header
          icon="hero-sparkles"
          title="Skills"
          count={length(@skills)}
          subtitle="System-wide, user-authored worker skill library. Materialized into worker worktrees at dispatch."
        >
          <:actions>
            <div class="flex items-center gap-2">
              <.live_badge live={@live} />
              <.button
                :if={@editing == nil}
                phx-click="new"
                variant="primary"
                class="btn btn-sm btn-primary"
              >
                <.icon name="hero-plus" class="size-4" /> New skill
              </.button>
            </div>
          </:actions>
        </.index_header>

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
                <.icon name="hero-exclamation-triangle" class="size-4 shrink-0" />
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

              <p :if={@form_error} class="text-sm text-error">{@form_error}</p>

              <div class="flex gap-2 mt-1">
                <.button type="submit" variant="primary" class="btn btn-sm btn-primary">
                  {if @editing == :new, do: "Create", else: "Save"}
                </.button>
                <.button type="button" phx-click="cancel" class="btn btn-sm btn-ghost">
                  Cancel
                </.button>
              </div>
            </.form>
          </div>
        </section>

        <section class="card bg-base-200 border border-base-300 shadow-sm">
          <div class="card-body p-4 gap-2">
            <.empty_state :if={@skills == []} id="skills-empty" icon="hero-sparkles">
              No skills yet. Create one to build the worker skill library.
            </.empty_state>

            <ul :if={@skills != []} id="skills" class="flex flex-col gap-1.5">
              <li
                :for={skill <- @skills}
                class="rounded-box border border-base-300 bg-base-100 px-3 py-2"
              >
                <div class="flex items-center gap-2 flex-wrap">
                  <span class="badge badge-sm badge-ghost font-mono shrink-0">/{skill.name}</span>
                  <span
                    :if={Skills.bundled_skill?(skill.name)}
                    class="badge badge-sm badge-warning badge-soft gap-1"
                    title="Collides with a bundled skill name"
                  >
                    <.icon name="hero-exclamation-triangle" class="size-3" /> bundled name
                  </span>
                  <span class="text-xs text-base-content/50">{byte_size(skill.body)} bytes</span>
                  <div class="ml-auto flex items-center gap-1">
                    <.button
                      phx-click="edit"
                      phx-value-id={skill.id}
                      class="btn btn-xs btn-ghost"
                    >
                      <.icon name="hero-pencil-square" class="size-3.5" /> Edit
                    </.button>
                    <.button
                      phx-click="delete"
                      phx-value-id={skill.id}
                      data-confirm={"Delete skill #{skill.name}?"}
                      class="btn btn-xs btn-ghost text-error"
                    >
                      <.icon name="hero-trash" class="size-3.5" /> Delete
                    </.button>
                  </div>
                </div>
                <p
                  :if={metadata_summary(skill.metadata)}
                  class="text-xs text-base-content/60 mt-1"
                >
                  {metadata_summary(skill.metadata)}
                </p>
              </li>
            </ul>
          </div>
        </section>

        <.back_link />
      </div>
    </Layouts.app>
    """
  end
end
