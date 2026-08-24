defmodule ArbiterWeb.WorkspaceDetail.RepoOverridesComponent do
  @moduledoc """
  `review_automation.repo_overrides` — overrides the workspace-wide reviewer
  dispatch mode for one repo.

  Removal rewrites the surviving map with `["review_automation.repo_overrides"]`
  unset first: deep-merge can't delete a key, and a repo name containing a dot
  can't be expressed as a dotted unset path without widening it into a
  different subtree.
  """
  use ArbiterWeb, :live_component

  import ArbiterWeb.WorkspaceDetail.Rows
  import ArbiterWeb.WorkspaceDetail.Shared

  alias ArbiterWeb.CoreComponents.Core
  alias ArbiterWeb.CoreComponents.Forms

  @impl true
  def mount(socket), do: {:ok, assign(socket, :repo_override_error, nil)}

  @impl true
  def update(assigns, socket) do
    socket = assign(socket, assigns)

    {:ok,
     assign(socket, :repo_overrides, socket.assigns.workspace |> repo_overrides() |> Enum.sort())}
  end

  @impl true
  def handle_event(
        "add_repo_override",
        %{"repo_override" => %{"repo" => repo, "mode" => mode}},
        socket
      ) do
    repo = String.trim(repo || "")

    if repo == "" do
      {:noreply, assign(socket, :repo_override_error, "Repo override name can't be empty.")}
    else
      write(socket, %{repo => mode}, [])
    end
  end

  def handle_event("rm_repo_override", %{"repo" => repo}, socket) do
    overrides = socket.assigns.workspace |> repo_overrides() |> Map.delete(repo)
    write(socket, overrides, ["review_automation.repo_overrides"])
  end

  defp write(socket, overrides, unset) do
    patch = %{"review_automation" => %{"repo_overrides" => overrides}}

    case patch_config(socket.assigns.workspace, patch, unset) do
      {:ok, ws} ->
        {:noreply,
         socket
         |> apply_workspace(ws)
         |> assign(:repo_override_error, nil)
         |> assign(:repo_overrides, ws |> repo_overrides() |> Enum.sort())}

      {:error, msg} ->
        {:noreply, assign(socket, :repo_override_error, msg)}
    end
  end

  defp repo_overrides(ws) do
    case cfg(ws, ["review_automation", "repo_overrides"]) do
      m when is_map(m) -> m
      _ -> %{}
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div id={@id} class={pane_class("policy", @section)}>
      <.rows>
        <.setting_row
          name="Per-repo dispatch overrides"
          consequence="review_automation.repo_overrides — these repos ignore the reviewer dispatch mode above and use their own"
        >
          <:below>
            <ul :if={@repo_overrides != []} id="repo-overrides" class={list_class()}>
              <.list_row :for={{repo, mode} <- @repo_overrides}>
                <span class="flex-1 truncate">{repo}</span>
                <span class={value_chip()}>
                  {mode}
                </span>
                <.remove_button
                  label={"Remove override for #{repo}"}
                  phx-click="rm_repo_override"
                  phx-target={@myself}
                  phx-value-repo={repo}
                  data-confirm={"Remove the review_automation override for #{repo}?"}
                />
              </.list_row>
            </ul>

            <.form
              for={%{}}
              as={:repo_override}
              phx-submit="add_repo_override"
              phx-target={@myself}
              class="mt-2 flex items-center gap-2"
            >
              <Forms.input
                name="repo_override[repo]"
                value=""
                size="sm"
                placeholder="owner/repo"
                class="flex-1"
                required
              />
              <Forms.select
                name="repo_override[mode]"
                options={@review_automation_modes}
                size="sm"
                class="w-[140px]"
              />
              <Core.button type="submit" size="sm">Add</Core.button>
            </.form>
          </:below>
        </.setting_row>
      </.rows>

      <p :if={@repo_override_error} class="m-0 text-[11px] text-[var(--arb-fail-text)]">
        {@repo_override_error}
      </p>
    </div>
    """
  end
end
