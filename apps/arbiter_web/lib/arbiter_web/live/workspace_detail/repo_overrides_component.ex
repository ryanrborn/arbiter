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

  import ArbiterWeb.WorkspaceDetail.Shared

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
    <div id={@id} class="border-t border-base-300 pt-3">
      <h3 class="font-semibold text-sm flex items-center gap-2">
        Per-repo dispatch overrides
        <span class="text-base-content/40 font-normal">({length(@repo_overrides)})</span>
      </h3>
      <p class="text-xs text-base-content/50 mt-1">
        <code>review_automation.repo_overrides</code> — overrides the dispatch mode above for
        a specific repo.
      </p>

      <ul :if={@repo_overrides != []} id="repo-overrides" class="flex flex-col gap-1.5 mt-2">
        <li
          :for={{repo, mode} <- @repo_overrides}
          class="flex items-center gap-2 rounded-box border border-base-300 bg-base-100 px-3 py-2"
        >
          <code class="text-sm flex-1">{repo}</code>
          <span class="badge badge-sm badge-ghost font-mono">{mode}</span>
          <button
            type="button"
            phx-click="rm_repo_override"
            phx-target={@myself}
            phx-value-repo={repo}
            class="btn btn-ghost btn-xs text-error shrink-0"
            aria-label={"Remove override for #{repo}"}
            data-confirm={"Remove the review_automation override for #{repo}?"}
          >
            <.icon name="hero-trash" class="size-4" />
          </button>
        </li>
      </ul>

      <.form
        for={%{}}
        as={:repo_override}
        phx-submit="add_repo_override"
        phx-target={@myself}
        class="flex gap-2 items-start mt-2"
      >
        <input
          type="text"
          name="repo_override[repo]"
          placeholder="owner/repo"
          class="input input-sm flex-1"
          required
        />
        <select name="repo_override[mode]" class="select select-sm">
          <option :for={mode <- @review_automation_modes} value={mode}>{mode}</option>
        </select>
        <.button type="submit" class="btn btn-sm">
          <.icon name="hero-plus" class="size-4" /> Add
        </.button>
      </.form>
      <p :if={@repo_override_error} class="text-sm text-error mt-1">{@repo_override_error}</p>
    </div>
    """
  end
end
