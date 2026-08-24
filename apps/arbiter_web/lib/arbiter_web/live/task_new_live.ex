defmodule ArbiterWeb.TaskNewLive do
  @moduledoc """
  Standalone "Create an issue" screen at `/tasks/new`.

  Writes through the same `Issue` `:create` action the CLI/MCP use, so the
  tracker-mirroring and id-generation hooks apply identically, and applies
  the same `Arbiter.Tasks.Dedup` check the REST API does (with a "Create
  anyway" override).

  That sameness now includes where the issue lands: `refined` defaults to
  `false`, so a task filed here starts in the board's Backlog column exactly
  as `arb create` and `task_create` do (bd-b5wyjd). The form deliberately has
  no "file this straight into Ready" affordance — the flash names Backlog and
  the redirect drops the operator on the detail page, where the *Move to
  Ready* button is.

  The create itself runs in `start_async/3`: both the dedup check and
  `Issue.create`'s `CreateUpstream` hook talk to the upstream tracker over
  the network, and a LiveView must not block its own process on that. The
  `CreateUpstream` failure stash is per-process, so it is drained *inside*
  the async function — the same drain `ArbiterWeb.Api.IssueController.create/2`
  does — and surfaced as a warning rather than silently swallowed.
  """

  use ArbiterWeb, :live_view

  alias Arbiter.Tasks.Dedup
  alias Arbiter.Tasks.Issue
  alias Arbiter.Tasks.Issue.Changes.CreateUpstream
  alias Arbiter.Tasks.Workspace
  alias ArbiterWeb.TaskForm
  require Ash.Query

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(:form_params, %{})
     |> assign(:field_errors, %{})
     |> assign(:server_error, nil)
     |> assign(:create_dup, nil)
     |> assign(:submitting, false)
     |> assign(:created, false)
     |> assign(:priority_options, TaskForm.priority_options())
     |> assign(:difficulty_options, TaskForm.difficulty_options())
     |> assign(:issue_type_options, TaskForm.issue_type_options())
     |> load_workspaces()}
  end

  # ---- create ----

  # A submit while one is already in flight would spawn a second create.
  @impl true
  def handle_event("create", _params, %{assigns: %{submitting: true}} = socket) do
    {:noreply, socket}
  end

  def handle_event("create", %{"task" => params}, socket) do
    {:noreply, submit_create(socket, params, false)}
  end

  # "Create anyway" — the operator has seen the duplicate matches and wants the
  # issue filed regardless (the dashboard's `--force`). Re-submits the params
  # they already typed, which are still stashed in `:form_params`.
  def handle_event("create_force", _params, socket) do
    {:noreply, submit_create(socket, socket.assigns.form_params, true)}
  end

  # Keeps the footer's live `arb issue create` preview in sync as the operator
  # types. No validation or I/O here — that's what "create" does on submit.
  #
  # Editing the title clears the duplicate warning (and any stale validation
  # errors) back to the plain editing state — otherwise an operator who sees
  # the warning for title A, retypes to title B, and clicks "Create anyway"
  # would force-create B with `force: true` even though B was never
  # dedup-checked, while the alert still described A.
  def handle_event("preview_new", %{"task" => params}, socket) do
    prev_title = TaskForm.trimmed(socket.assigns.form_params["title"])
    next_title = TaskForm.trimmed(params["title"])

    socket = assign(socket, :form_params, params)

    {:noreply,
     if next_title != prev_title do
       assign(socket, create_dup: nil, field_errors: %{})
     else
       socket
     end}
  end

  # Validation that needs no I/O runs here, on the LiveView process; everything
  # that touches the DB or the tracker runs in the async task.
  defp submit_create(socket, params, force?) do
    # Keep what was typed so a rejected submit re-renders it rather than
    # blanking the form.
    socket = assign(socket, :form_params, params)
    errors = validate(params)

    if errors == %{} do
      attrs = %{
        title: TaskForm.trimmed(params["title"]),
        workspace_id: TaskForm.trimmed(params["workspace_id"]),
        priority: priority_value(params),
        difficulty: difficulty_value(params),
        issue_type: TaskForm.trimmed(params["issue_type"]) || "feature",
        description: TaskForm.trimmed(params["description"]),
        acceptance: TaskForm.trimmed(params["acceptance"])
      }

      socket
      |> assign(submitting: true, field_errors: %{}, server_error: nil, create_dup: nil)
      |> start_async(:create, fn -> run_create(attrs, force?) end)
    else
      assign(socket, field_errors: errors, server_error: nil)
    end
  end

  # Runs off the LiveView process. Drains the `CreateUpstream` stash here
  # because it is per-process — draining in `handle_async/3` would read the
  # LiveView's (empty) slot and silently lose a tracker-mirror failure.
  defp run_create(attrs, force?) do
    case Dedup.check(attrs.title, attrs.workspace_id, force: force?) do
      :ok ->
        case Ash.create(Issue, attrs) do
          {:ok, task} -> {:created, task, CreateUpstream.last_error()}
          {:error, err} -> {:invalid, TaskForm.error_message(err)}
        end

      dup ->
        {:duplicate, dup}
    end
  end

  @impl true
  def handle_async(:create, {:ok, {:created, task, nil}}, socket) do
    {:noreply,
     socket
     |> assign(submitting: false, created: true, field_errors: %{}, server_error: nil)
     |> assign(create_dup: nil)
     |> put_flash(:info, "Created #{task.id} in Backlog — refine it, then Move to Ready")
     |> push_navigate(to: ~p"/tasks/#{task.id}")}
  end

  # The issue is durable but the upstream mirror failed — same condition the
  # REST API answers with a 502. Say so instead of reporting a clean create.
  def handle_async(:create, {:ok, {:created, task, err}}, socket) do
    {:noreply,
     socket
     |> assign(submitting: false, created: true, field_errors: %{}, server_error: nil)
     |> assign(create_dup: nil)
     |> put_flash(
       :error,
       "Created #{task.id} locally, but the tracker mirror failed: " <>
         "#{upstream_error_text(err)}. Re-link with `arb update #{task.id} --tracker-ref REF`."
     )
     |> push_navigate(to: ~p"/tasks/#{task.id}")}
  end

  def handle_async(:create, {:ok, {:duplicate, dup}}, socket) do
    {:noreply, assign(socket, submitting: false, create_dup: dup, field_errors: %{})}
  end

  def handle_async(:create, {:ok, {:invalid, message}}, socket) do
    {:noreply, assign(socket, submitting: false, server_error: message)}
  end

  def handle_async(:create, {:exit, reason}, socket) do
    {:noreply,
     assign(socket, submitting: false, server_error: "Create crashed: #{inspect(reason)}")}
  end

  defp upstream_error_text(%{message: message}) when is_binary(message), do: message
  defp upstream_error_text(err), do: inspect(err)

  defp dup_count({:local_dup, matches}), do: length(matches)
  defp dup_count({:tracker_dup, matches}), do: length(matches)
  defp dup_count(_), do: 0

  defp dup_matches({:local_dup, matches}), do: Enum.map(matches, &{&1.id, &1.title})

  defp dup_matches({:tracker_dup, matches}),
    do: Enum.map(matches, &{Map.get(&1, :url) || Map.get(&1, :ref) || "?", Map.get(&1, :title)})

  defp dup_matches(_), do: []

  # ---- validation ----
  #
  # Each check is independent so every problem the operator has to fix shows
  # up under its own field in one pass, rather than dribbling out one submit
  # at a time.

  defp validate(params) do
    %{}
    |> validate_title(params)
    |> validate_workspace(params)
    |> validate_priority(params)
    |> validate_difficulty(params)
  end

  defp validate_title(errors, params) do
    case TaskForm.trimmed(params["title"]) do
      nil -> Map.put(errors, :title, "Title can't be empty.")
      _ -> errors
    end
  end

  defp validate_workspace(errors, params) do
    case TaskForm.trimmed(params["workspace_id"]) do
      nil -> Map.put(errors, :workspace_id, "Pick a workspace to file this issue in.")
      _ -> errors
    end
  end

  defp validate_priority(errors, params) do
    case TaskForm.parse_int(params["priority"]) do
      :error -> Map.put(errors, :priority, "Priority must be a number 0–4.")
      _ -> errors
    end
  end

  defp validate_difficulty(errors, params) do
    case TaskForm.parse_int(params["difficulty"]) do
      :error -> Map.put(errors, :difficulty, "Difficulty must be a number 0–4.")
      _ -> errors
    end
  end

  defp priority_value(params) do
    case TaskForm.parse_int(params["priority"]) do
      {:ok, nil} -> 2
      {:ok, priority} -> priority
    end
  end

  defp difficulty_value(params) do
    case TaskForm.parse_int(params["difficulty"]) do
      {:ok, difficulty} -> difficulty
    end
  end

  # The footer's live equivalent of what's typed, as `arb issue create` would
  # be invoked — the only cross-reference point between the dashboard and the
  # CLI, so the flag mapping has to be exact. `--workspace` is always shown
  # (not just when it deviates from a default): `arb issue`'s own default
  # resolution (the workspace literally named "default", or the sole
  # workspace if unambiguous — see `ArbiterCli.Workspace.resolve/0`) does not
  # match this form's default (alphabetically first), so omitting it would
  # make the previewed command file into the wrong workspace on any
  # multi-workspace install. `acceptance` has no `arb issue create` flag at
  # all — surfaced as a separate note below the command instead of silently
  # dropped.
  #
  # Deviation from the reference mock (`arb issue create "<title>" --priority
  # 2`, unconditionally): flags whose typed value matches the server default
  # are omitted here so the command shown is the minimal one that reproduces
  # the create, and an empty title renders as `''` rather than `…`.
  defp cli_preview(params, workspaces) do
    title = TaskForm.trimmed(params["title"]) || ""
    workspace_name = workspace_name_for(TaskForm.trimmed(params["workspace_id"]), workspaces)

    ["arb issue create", shell_quote(title)]
    |> maybe_flag("--type", TaskForm.trimmed(params["issue_type"]), "feature")
    |> maybe_flag("--priority", TaskForm.trimmed(params["priority"]), "2")
    |> maybe_flag("--difficulty", TaskForm.trimmed(params["difficulty"]), nil)
    |> maybe_flag("--description", TaskForm.trimmed(params["description"]), nil, quote?: true)
    |> maybe_workspace_flag(workspace_name)
    |> Enum.join(" ")
  end

  defp workspace_name_for(nil, _workspaces), do: nil

  defp workspace_name_for(id, workspaces) do
    case Enum.find(workspaces, &(&1.id == id)) do
      nil -> nil
      workspace -> workspace.name
    end
  end

  defp maybe_workspace_flag(parts, nil), do: parts
  defp maybe_workspace_flag(parts, name), do: parts ++ ["--workspace", shell_quote(name)]

  defp maybe_flag(parts, _flag, value, default, _opts \\ [])

  defp maybe_flag(parts, _flag, value, default, _opts) when value == default or is_nil(value),
    do: parts

  defp maybe_flag(parts, flag, value, _default, opts) do
    value = if opts[:quote?], do: shell_quote(value), else: value
    parts ++ [flag, value]
  end

  # Single-quote the value POSIX-style: this string is meant to be copied
  # straight into a shell, so `$` and backticks inside it must stay inert
  # rather than expanding/executing on paste.
  defp shell_quote(value) do
    "'" <> String.replace(value, "'", "'\\''") <> "'"
  end

  defp load_workspaces(socket) do
    workspaces =
      Workspace
      |> Ash.Query.sort(name: :asc)
      |> Ash.read()
      |> case do
        {:ok, list} -> list
        _ -> []
      end

    assign(socket, :workspaces, workspaces)
  end

  # ---- render ----

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app
      flash={@flash}
      current_path={@current_path}
      quotas={@quotas}
      coordinator_inbox={@coordinator_inbox}
      coordinator_outstanding_count={@coordinator_outstanding_count}
    >
      <div class="p-4 sm:p-6 max-w-[900px] mx-auto flex flex-col gap-4">
        <div>
          <h1 class="m-0 font-[600] text-[24px] leading-[1.2] tracking-[-0.025em] text-[var(--text-title)]">
            Create an issue
          </h1>
          <p class="mt-[6px] text-[12.5px] leading-[1.55] text-[var(--text-secondary)] max-w-[var(--measure-prose)]">
            Writes through the same action the CLI and MCP tools use, so tracker mirroring and id generation apply identically. A duplicate title is advisory, not fatal.
          </p>
        </div>

        <p :if={@workspaces == []} class="text-[12.5px] text-[var(--arb-fail-text)]">
          No workspaces exist yet — create one first at <.link
            navigate={~p"/workspaces"}
            class="text-[var(--text-link)] underline"
          >/workspaces</.link>.
        </p>

        <.panel :if={@workspaces != []}>
          <.form
            for={%{}}
            as={:task}
            id="task-new-form"
            phx-submit="create"
            phx-change="preview_new"
            class="grid sm:grid-cols-2 gap-x-[16px] gap-y-[14px]"
          >
            <div class="sm:col-span-2">
              <ArbiterWeb.CoreComponents.Forms.input
                name="task[title]"
                label="Title"
                value={TaskForm.value(@form_params, "title")}
                required
                mono={false}
                error={@field_errors[:title]}
                placeholder="Short imperative summary"
              />
            </div>
            <ArbiterWeb.CoreComponents.Forms.select
              name="task[workspace_id]"
              label="Workspace"
              options={Enum.map(@workspaces, &{"#{&1.name} (#{&1.prefix})", &1.id})}
              value={TaskForm.value(@form_params, "workspace_id", List.first(@workspaces).id)}
              error={@field_errors[:workspace_id]}
            />
            <ArbiterWeb.CoreComponents.Forms.select
              name="task[issue_type]"
              label="Type"
              options={@issue_type_options}
              value={TaskForm.value(@form_params, "issue_type", "feature")}
            />
            <ArbiterWeb.CoreComponents.Forms.select
              name="task[priority]"
              label="Priority"
              options={@priority_options}
              value={TaskForm.value(@form_params, "priority", "2")}
              error={@field_errors[:priority]}
            />
            <ArbiterWeb.CoreComponents.Forms.select
              name="task[difficulty]"
              label="Difficulty"
              options={@difficulty_options}
              value={TaskForm.value(@form_params, "difficulty")}
              error={@field_errors[:difficulty]}
            />
            <div class="sm:col-span-2">
              <ArbiterWeb.CoreComponents.Forms.textarea
                name="task[description]"
                label="Description (optional)"
                value={TaskForm.value(@form_params, "description")}
                rows={3}
                placeholder="Context, scope, and anything a worker would otherwise have to guess."
              />
            </div>
            <div class="sm:col-span-2">
              <ArbiterWeb.CoreComponents.Forms.textarea
                name="task[acceptance]"
                label="Acceptance (optional)"
                value={TaskForm.value(@form_params, "acceptance")}
                rows={2}
                placeholder="How we'll know it's done."
              />
            </div>

            <p :if={@server_error} class="sm:col-span-2 text-[12.5px] text-[var(--arb-fail-text)]">
              {@server_error}
            </p>

            <%!-- Duplicate-title warning. Advisory, not fatal: the same rule
                 the REST API answers with a 409, plus the dashboard's
                 equivalent of `--force`. --%>
            <div
              :if={@create_dup}
              id="task-new-dup"
              role="alert"
              class="sm:col-span-2 flex flex-col gap-2 rounded-[var(--radius-field)] border border-solid border-[var(--arb-attention-edge)] border-l-[length:var(--border-accent-width)] border-l-[color:var(--arb-attention)] bg-[var(--arb-attention-wash)] px-[13px] py-[11px]"
            >
              <span class="flex items-center gap-2 text-[12.5px] font-medium text-[var(--arb-text-body)]">
                <ArbiterWeb.CoreComponents.Core.icon
                  name="hero-exclamation-triangle"
                  size={14}
                  color="var(--arb-attention)"
                />
                {dup_count(@create_dup)} issues already have a similar title — file it anyway?
              </span>
              <ul class="m-0 pl-[18px] flex flex-col gap-[3px] list-disc">
                <li
                  :for={{ref, title} <- dup_matches(@create_dup)}
                  class="font-[family-name:var(--font-mono)] text-[11.5px] text-[var(--text-secondary)]"
                >
                  <span class="text-[var(--text-link)]">{ref}</span> {title}
                </li>
              </ul>
            </div>

            <div class="sm:col-span-2 flex items-center gap-2 flex-wrap mt-1">
              <ArbiterWeb.CoreComponents.Core.button
                type="submit"
                variant="primary"
                size="md"
                disabled={@submitting || @created}
              >
                {cond do
                  @created -> "Created"
                  @submitting -> "Creating…"
                  true -> "Create"
                end}
              </ArbiterWeb.CoreComponents.Core.button>
              <ArbiterWeb.CoreComponents.Core.button
                :if={@create_dup}
                type="button"
                phx-click="create_force"
                variant="attention"
                size="md"
                disabled={@submitting}
              >
                Create anyway
              </ArbiterWeb.CoreComponents.Core.button>
              <ArbiterWeb.CoreComponents.Core.button
                type="button"
                phx-click={JS.navigate(~p"/")}
                variant="ghost"
                size="md"
              >
                Cancel
              </ArbiterWeb.CoreComponents.Core.button>
            </div>
          </.form>
        </.panel>

        <%!-- Live equivalent of what's typed, run against the CLI directly.
             The only cross-reference point between the dashboard and
             `arb` — the flag mapping must match `arb issue create` exactly. --%>
        <div
          :if={@workspaces != []}
          id="task-new-cli-preview"
          class="flex items-center gap-[10px] font-[family-name:var(--font-mono)] text-[11.5px] text-[var(--text-label)]"
        >
          <ArbiterWeb.CoreComponents.Core.icon name="hero-information-circle" size={13} />
          Equivalent CLI:
          <span class="text-[var(--arb-text-body)]">{cli_preview(@form_params, @workspaces)}</span>
        </div>
        <p
          :if={TaskForm.trimmed(@form_params["acceptance"])}
          class="font-[family-name:var(--font-mono)] text-[11px] text-[var(--text-label)]"
        >
          Acceptance isn't set by `arb issue create` — there's no CLI flag for it.
        </p>

        <ArbiterWeb.CoreComponents.Navigation.back_link />
      </div>
    </Layouts.app>
    """
  end
end
