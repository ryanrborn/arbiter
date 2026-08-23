defmodule ArbiterWeb.TaskIndexLive do
  @moduledoc """
  Index of every directive (task) at `/tasks` — the "See all" target for the
  dashboard's current-only recent-directives section.

  Lists all directives with a status filter (all / open / in progress /
  closed) and offset/limit paging, newest-updated first. Re-renders live on
  `:task_lifecycle` events so a transition shows up without a refresh.

  The "New issue" action opens an inline create form (the
  `WorkspaceIndexLive` pattern) so an operator can file an issue without
  dropping to `arb create`. It writes through the same `Issue` `:create`
  action the CLI/MCP use, so the tracker-mirroring and id-generation hooks
  apply identically, and it applies the same `Arbiter.Tasks.Dedup` check the
  REST API does (with a "Create anyway" override).

  The create itself runs in `start_async/3`: both the dedup check and
  `Issue.create`'s `CreateUpstream` hook talk to the upstream tracker over the
  network, and a LiveView must not block its own process on that. The
  `CreateUpstream` failure stash is per-process, so it is drained *inside* the
  async function — the same drain `ArbiterWeb.Api.IssueController.create/2`
  does — and surfaced as a warning rather than silently swallowed.
  """

  use ArbiterWeb, :live_view

  alias Arbiter.Tasks.Dedup
  alias Arbiter.Tasks.Issue
  alias Arbiter.Tasks.Issue.Changes.CreateUpstream
  alias Arbiter.Tasks.Workspace
  alias ArbiterWeb.Paging
  alias ArbiterWeb.TaskForm
  require Ash.Query

  @tasks_topic "tasks"

  # Literal status values — FilterTabs shows these verbatim, not humanized,
  # so the value here is what lands in the URL and the query filter.
  @filters [
    %{label: "All", value: "all"},
    %{label: "Open", value: "open"},
    %{label: "In progress", value: "in_progress"},
    %{label: "Closed", value: "closed"}
  ]

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket), do: Phoenix.PubSub.subscribe(Arbiter.PubSub, @tasks_topic)

    {:ok,
     socket
     |> assign(:live, connected?(socket))
     |> assign(:issue_label, "issue")
     |> assign(:filters, @filters)
     |> assign(:creating, false)
     |> assign(:create_error, nil)
     |> assign(:create_params, %{})
     |> assign(:create_dup, nil)
     |> assign(:submitting, false)
     |> assign(:priority_options, TaskForm.priority_options())
     |> assign(:difficulty_options, TaskForm.difficulty_options())
     |> assign(:issue_type_options, TaskForm.issue_type_options())
     |> load_workspaces()}
  end

  @impl true
  def handle_params(params, _uri, socket) do
    status = parse_status(params)
    page = Paging.parse_page(params)

    {:noreply,
     socket
     |> assign(:status, status)
     |> assign(:page, page)
     |> refresh()}
  end

  @impl true
  # Any task transition can change which rows belong on the current page;
  # re-read the page in place (same filter + page).
  def handle_info({:task_lifecycle, _event, _issue}, socket) do
    {:noreply, refresh(socket)}
  end

  def handle_info(_msg, socket), do: {:noreply, socket}

  # ---- create ----

  @impl true
  def handle_event("new", _params, socket) do
    {:noreply,
     socket
     |> assign(creating: true, create_error: nil, create_params: %{}, create_dup: nil)
     |> load_workspaces()}
  end

  def handle_event("cancel_new", _params, socket) do
    {:noreply,
     assign(socket, creating: false, create_error: nil, create_params: %{}, create_dup: nil)}
  end

  # A submit while one is already in flight would spawn a second create.
  def handle_event("create", _params, %{assigns: %{submitting: true}} = socket) do
    {:noreply, socket}
  end

  def handle_event("create", %{"task" => params}, socket) do
    {:noreply, submit_create(socket, params, false)}
  end

  # "Create anyway" — the operator has seen the duplicate matches and wants the
  # issue filed regardless (the dashboard's `--force`). Re-submits the params
  # they already typed, which are still stashed in `:create_params`.
  def handle_event("create_force", _params, socket) do
    {:noreply, submit_create(socket, socket.assigns.create_params, true)}
  end

  # Keeps the footer's live `arb issue create` preview in sync as the operator
  # types. No validation or I/O here — that's what "create" does on submit.
  def handle_event("preview_new", %{"task" => params}, socket) do
    {:noreply, assign(socket, :create_params, params)}
  end

  # Validation that needs no I/O runs here, on the LiveView process; everything
  # that touches the DB or the tracker runs in the async task.
  defp submit_create(socket, params, force?) do
    # Keep what was typed so a rejected submit re-renders it rather than
    # blanking the form.
    socket = assign(socket, :create_params, params)

    with {:ok, title} <- fetch_title(params),
         {:ok, workspace_id} <- fetch_workspace_id(params),
         {:ok, priority} <- fetch_priority(params),
         {:ok, difficulty} <- fetch_difficulty(params) do
      attrs = %{
        title: title,
        workspace_id: workspace_id,
        priority: priority,
        difficulty: difficulty,
        issue_type: TaskForm.trimmed(params["issue_type"]) || "feature",
        description: TaskForm.trimmed(params["description"]),
        acceptance: TaskForm.trimmed(params["acceptance"])
      }

      socket
      |> assign(submitting: true, create_error: nil, create_dup: nil)
      |> start_async(:create, fn -> run_create(attrs, force?) end)
    else
      {:error, message} -> assign(socket, :create_error, message)
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
     |> assign(submitting: false, creating: false, create_error: nil)
     |> assign(create_params: %{}, create_dup: nil)
     |> put_flash(:info, "Created #{socket.assigns.issue_label} #{task.id}.")
     |> push_navigate(to: ~p"/tasks/#{task.id}")}
  end

  # The issue is durable but the upstream mirror failed — same condition the
  # REST API answers with a 502. Say so instead of reporting a clean create.
  def handle_async(:create, {:ok, {:created, task, err}}, socket) do
    {:noreply,
     socket
     |> assign(submitting: false, creating: false, create_error: nil)
     |> assign(create_params: %{}, create_dup: nil)
     |> put_flash(
       :error,
       "Created #{task.id} locally, but the tracker mirror failed: " <>
         "#{upstream_error_text(err)} Re-link with `arb update #{task.id} --tracker-ref REF`."
     )
     |> push_navigate(to: ~p"/tasks/#{task.id}")}
  end

  def handle_async(:create, {:ok, {:duplicate, dup}}, socket) do
    {:noreply, assign(socket, submitting: false, create_dup: dup, create_error: nil)}
  end

  def handle_async(:create, {:ok, {:invalid, message}}, socket) do
    {:noreply, assign(socket, submitting: false, create_error: message)}
  end

  def handle_async(:create, {:exit, reason}, socket) do
    {:noreply,
     assign(socket, submitting: false, create_error: "Create crashed: #{inspect(reason)}")}
  end

  defp upstream_error_text(%{message: message}) when is_binary(message), do: message
  defp upstream_error_text(err), do: inspect(err)

  defp dup_matches({:local_dup, matches}), do: Enum.map(matches, &{&1.id, &1.title})

  defp dup_matches({:tracker_dup, matches}),
    do: Enum.map(matches, &{Map.get(&1, :url) || Map.get(&1, :ref) || "?", Map.get(&1, :title)})

  defp dup_matches(_), do: []

  defp fetch_title(params) do
    case TaskForm.trimmed(params["title"]) do
      nil -> {:error, "Title can't be empty."}
      title -> {:ok, title}
    end
  end

  defp fetch_workspace_id(params) do
    case TaskForm.trimmed(params["workspace_id"]) do
      nil -> {:error, "Pick a workspace to file this issue in."}
      id -> {:ok, id}
    end
  end

  defp fetch_priority(params) do
    case TaskForm.parse_int(params["priority"]) do
      {:ok, nil} -> {:ok, 2}
      {:ok, priority} -> {:ok, priority}
      :error -> {:error, "Priority must be a number 0–4."}
    end
  end

  defp fetch_difficulty(params) do
    case TaskForm.parse_int(params["difficulty"]) do
      {:ok, difficulty} -> {:ok, difficulty}
      :error -> {:error, "Difficulty must be a number 0–4."}
    end
  end

  # The footer's live equivalent of what's typed, as `arb issue create` would
  # be invoked — the only cross-reference point between the dashboard and the
  # CLI, so the flag mapping has to be exact. `workspace_id`/`acceptance` have
  # no CLI flag (workspace is resolved from cwd, acceptance isn't exposed by
  # `arb issue create`) and are deliberately absent. Flags whose typed value
  # matches the server default are omitted so the command shown is the
  # minimal one that reproduces the create.
  defp cli_preview(params) do
    title = TaskForm.trimmed(params["title"]) || ""

    ["arb issue create", shell_quote(title)]
    |> maybe_flag("--type", TaskForm.trimmed(params["issue_type"]), "feature")
    |> maybe_flag("--priority", TaskForm.trimmed(params["priority"]), "2")
    |> maybe_flag("--difficulty", TaskForm.trimmed(params["difficulty"]), nil)
    |> maybe_flag("--description", TaskForm.trimmed(params["description"]), nil, quote?: true)
    |> Enum.join(" ")
  end

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

  defp refresh(socket) do
    query =
      Issue
      |> filter_by_status(socket.assigns.status)
      |> Ash.Query.sort(updated_at: :desc)

    result = Paging.paginate(query, socket.assigns.page)

    socket
    |> assign(:tasks, result.entries)
    |> assign(:page, result.page)
    |> assign(:total_pages, result.total_pages)
    |> assign(:total_count, result.total_count)
  end

  defp filter_by_status(query, :all), do: Ash.Query.new(query)
  defp filter_by_status(query, status), do: Ash.Query.filter(query, status == ^status)

  defp parse_status(%{"status" => s}) when s in ~w(open in_progress closed),
    do: String.to_existing_atom(s)

  defp parse_status(_), do: :all

  # ---- routes ----

  defp task_path(:all, page), do: ~p"/tasks?#{%{page: page}}"
  defp task_path(status, page), do: ~p"/tasks?#{%{status: status, page: page}}"

  # ---- render ----

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_path={@current_path} quotas={@quotas}>
      <div class="p-4 sm:p-6 max-w-7xl mx-auto space-y-6">
        <ArbiterWeb.CoreComponents.Domain.index_header
          icon="hero-clipboard-document-list"
          title={cap_plural(@issue_label)}
          count={@total_count}
          subtitle={"Every #{@issue_label}, filterable and paged. The dashboard shows only the current ones."}
        >
          <:actions>
            <ArbiterWeb.CoreComponents.Feedback.live_badge live={@live} />
            <ArbiterWeb.CoreComponents.Core.button
              :if={!@creating}
              type="button"
              variant="primary"
              size="sm"
              phx-click="new"
            >
              <:icon><ArbiterWeb.CoreComponents.Core.icon name="hero-plus" size={13} /></:icon>
              New {@issue_label}
            </ArbiterWeb.CoreComponents.Core.button>
          </:actions>
        </ArbiterWeb.CoreComponents.Domain.index_header>

        <.panel :if={@creating} title={"Create an #{@issue_label}"}>
          <p :if={@workspaces == []} class="text-[12.5px] text-[var(--arb-fail-text)]">
            No workspaces exist yet — create one first at <.link
              navigate={~p"/workspaces"}
              class="text-[var(--text-link)] underline"
            >/workspaces</.link>.
          </p>

          <.form
            :if={@workspaces != []}
            for={%{}}
            as={:task}
            id="task-create-form"
            phx-submit="create"
            phx-change="preview_new"
            class="grid sm:grid-cols-2 gap-x-4 gap-y-3"
          >
            <div class="sm:col-span-2">
              <ArbiterWeb.CoreComponents.Forms.input
                name="task[title]"
                label="Title"
                value={TaskForm.value(@create_params, "title")}
                required
                mono={false}
                placeholder="Short imperative summary"
              />
            </div>
            <ArbiterWeb.CoreComponents.Forms.select
              name="task[workspace_id]"
              label="Workspace"
              options={Enum.map(@workspaces, &{"#{&1.name} (#{&1.prefix})", &1.id})}
              value={TaskForm.value(@create_params, "workspace_id", List.first(@workspaces).id)}
            />
            <ArbiterWeb.CoreComponents.Forms.select
              name="task[issue_type]"
              label="Type"
              options={@issue_type_options}
              value={TaskForm.value(@create_params, "issue_type", "feature")}
            />
            <ArbiterWeb.CoreComponents.Forms.select
              name="task[priority]"
              label="Priority"
              options={@priority_options}
              value={TaskForm.value(@create_params, "priority", "2")}
            />
            <ArbiterWeb.CoreComponents.Forms.select
              name="task[difficulty]"
              label="Difficulty"
              options={@difficulty_options}
              value={TaskForm.value(@create_params, "difficulty")}
            />
            <div class="sm:col-span-2">
              <ArbiterWeb.CoreComponents.Forms.textarea
                name="task[description]"
                label="Description (optional)"
                value={TaskForm.value(@create_params, "description")}
                rows={4}
                placeholder="Context, scope, and anything a worker would otherwise have to guess."
              />
            </div>
            <div class="sm:col-span-2">
              <ArbiterWeb.CoreComponents.Forms.textarea
                name="task[acceptance]"
                label="Acceptance (optional)"
                value={TaskForm.value(@create_params, "acceptance")}
                rows={3}
                placeholder="How we'll know it's done."
              />
            </div>
            <p :if={@create_error} class="sm:col-span-2 text-[12.5px] text-[var(--arb-fail-text)]">
              {@create_error}
            </p>

            <%!-- Duplicate-title warning. Advisory, not fatal: the same rule
                 the REST API answers with a 409, plus the dashboard's
                 equivalent of `--force`. --%>
            <div
              :if={@create_dup}
              id="task-create-dup"
              role="alert"
              class="sm:col-span-2 flex flex-col items-start gap-1 rounded-[var(--radius-field)] border border-solid border-[var(--arb-attention-edge)] bg-[var(--arb-attention-wash)] px-[12px] py-[10px]"
            >
              <span class="text-[12.5px] font-medium text-[var(--arb-text-body)]">
                {Dedup.message(@create_dup)} — file it anyway?
              </span>
              <ul class="text-[11px] font-[family-name:var(--font-mono)] list-disc list-inside text-[var(--text-secondary)]">
                <li :for={{ref, title} <- dup_matches(@create_dup)}>{ref} {title}</li>
              </ul>
            </div>

            <div class="sm:col-span-2 flex items-center gap-2 mt-1">
              <ArbiterWeb.CoreComponents.Core.button
                type="submit"
                variant="primary"
                disabled={@submitting}
              >
                {if @submitting, do: "Creating…", else: "Create"}
              </ArbiterWeb.CoreComponents.Core.button>
              <ArbiterWeb.CoreComponents.Core.button
                :if={@create_dup}
                type="button"
                phx-click="create_force"
                variant="attention"
                disabled={@submitting}
              >
                Create anyway
              </ArbiterWeb.CoreComponents.Core.button>
              <ArbiterWeb.CoreComponents.Core.button
                type="button"
                phx-click="cancel_new"
                variant="ghost"
              >
                Cancel
              </ArbiterWeb.CoreComponents.Core.button>
            </div>

            <%!-- Live equivalent of what's typed, run against the CLI directly.
                 The only cross-reference point between the dashboard and
                 `arb` — the flag mapping must match `arb issue create` exactly. --%>
            <p
              id="task-create-cli-preview"
              class="sm:col-span-2 text-[11px] font-[family-name:var(--font-mono)] text-[var(--text-label)] truncate"
            >
              {cli_preview(@create_params)}
            </p>
          </.form>
        </.panel>

        <ArbiterWeb.CoreComponents.Navigation.filter_tabs
          tabs={@filters}
          active={Atom.to_string(@status)}
          tab_path={fn value -> task_path(String.to_existing_atom(value), 1) end}
        />

        <ArbiterWeb.CoreComponents.Core.panel body_class="flex flex-col gap-4">
          <div :if={@tasks == []} id="tasks-empty">
            <ArbiterWeb.CoreComponents.Feedback.empty_state icon="hero-clipboard-document-list">
              No {plural(@issue_label)} match this filter.
            </ArbiterWeb.CoreComponents.Feedback.empty_state>
          </div>

          <ul :if={@tasks != []} id="tasks" class="flex flex-col gap-1.5">
            <li :for={b <- @tasks} class={issue_row_class(b)}>
              <.priority_tag priority={b.priority} />
              <.difficulty_meter difficulty={b.difficulty} />
              <.link
                navigate={~p"/tasks/#{b.id}"}
                class="min-w-0 flex-1 flex items-center gap-2 group"
              >
                <span class="font-[family-name:var(--font-mono)] text-[10.5px] text-[var(--text-secondary)] shrink-0 group-hover:text-[var(--text-link)] transition-colors">
                  {b.id}
                </span>
                <span
                  class="truncate text-[12.5px] font-medium text-[var(--text-title)] group-hover:text-[var(--text-link)] transition-colors"
                  title={b.title}
                >
                  {b.title}
                </span>
              </.link>
              <.status_chip status={b.status} />
            </li>
          </ul>

          <ArbiterWeb.CoreComponents.Navigation.pager
            page={@page}
            total_pages={@total_pages}
            total_count={@total_count}
            page_path={fn page -> task_path(@status, page) end}
            class={@tasks != [] && "pt-2"}
          />
        </ArbiterWeb.CoreComponents.Core.panel>

        <ArbiterWeb.CoreComponents.Navigation.back_link />
      </div>
    </Layouts.app>
    """
  end

  # ---- view helpers ----

  # P1 is the only priority that owns the row: a red left rule plus a faint
  # wash, matching the accent-rule treatment `Domain.task_card/1` uses for
  # its `fail` accent. Closed issues recede instead — opacity 0.62, no rule.
  defp issue_row_class(issue) do
    [
      "flex items-center gap-2 px-3 py-2 rounded-[var(--radius-field)] border border-solid",
      "border-[var(--border-strong)] hover:bg-[var(--arb-raised-hover)]",
      "transition-colors duration-[var(--dur-hover)]",
      if(issue.priority == 1,
        do: [
          "bg-[var(--arb-fail-wash)]",
          "border-l-[length:var(--border-accent-width)] border-l-[color:var(--arb-fail)]"
        ],
        else: "bg-[var(--surface-card)]"
      ),
      issue.status == :closed && "opacity-[0.62]"
    ]
  end
end
