defmodule ArbiterWeb.WorkspaceDetail.RepoPathsComponent do
  @moduledoc """
  `repo_paths` — repo name to local filesystem checkout path, used to resolve
  a dispatch's working directory.

  Both add and remove rewrite the whole map and pass `["repo_paths"]` as an
  unset path: deep-merge can't delete a key, and an entry may carry the richer
  `%{"path" => ..., "target_branch" => ...}` shape a sibling write must not
  flatten.
  """
  use ArbiterWeb, :live_component

  import ArbiterWeb.WorkspaceDetail.Shared

  alias Arbiter.Tasks.RepoConfig

  @impl true
  def mount(socket), do: {:ok, assign(socket, :repo_path_error, nil)}

  @impl true
  def update(assigns, socket) do
    socket = assign(socket, assigns)
    {:ok, assign(socket, :repo_paths, socket.assigns.workspace |> repo_paths() |> Enum.sort())}
  end

  @impl true
  def handle_event("add_repo_path", %{"repo_path" => %{"repo" => repo, "path" => path}}, socket) do
    repo = String.trim(repo || "")
    path = String.trim(path || "")

    cond do
      repo == "" ->
        {:noreply, assign(socket, :repo_path_error, "Repo name can't be empty.")}

      path == "" ->
        {:noreply, assign(socket, :repo_path_error, "Repo path can't be empty.")}

      true ->
        existing = repo_paths_raw(socket.assigns.workspace)

        entry =
          case Map.get(existing, repo) do
            %{} = m -> Map.put(m, "path", path)
            _ -> path
          end

        write(socket, Map.put(existing, repo, entry))
    end
  end

  def handle_event("rm_repo_path", %{"repo" => repo}, socket) do
    write(socket, socket.assigns.workspace |> repo_paths_raw() |> Map.delete(repo))
  end

  defp write(socket, paths) do
    case patch_config(socket.assigns.workspace, %{"repo_paths" => paths}, ["repo_paths"]) do
      {:ok, ws} ->
        {:noreply,
         socket
         |> apply_workspace(ws)
         |> assign(:repo_path_error, nil)
         |> assign(:repo_paths, ws |> repo_paths() |> Enum.sort())}

      {:error, msg} ->
        {:noreply, assign(socket, :repo_path_error, msg)}
    end
  end

  # The raw `repo_paths` map — entries may be a bare path string or the
  # richer `%{"path" => ..., "target_branch" => ...}` shape set via the CLI.
  # Used as-is for writes so touching one entry can't clobber a sibling's
  # `target_branch`.
  defp repo_paths_raw(ws) do
    case cfg(ws, ["repo_paths"]) do
      m when is_map(m) -> m
      _ -> %{}
    end
  end

  # `repo_paths_raw/1` flattened to a simple repo -> path string map for
  # display, same as `RepoConfig.find_path/2` elsewhere reads it. Entries that
  # don't resolve to a path string (malformed, e.g. `%{"target_branch" => .}`
  # with no `"path"`) are kept with a `nil` path rather than dropped, so they
  # still render (as "invalid") and can be removed from the dashboard.
  defp repo_paths(ws) do
    ws
    |> repo_paths_raw()
    |> Enum.map(fn {repo, entry} -> {repo, RepoConfig.repo_path_from_config(entry)} end)
    |> Map.new()
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div id={@id} class="border-t border-base-300 pt-3">
      <h3 class="font-semibold text-sm flex items-center gap-2">
        Repo paths <span class="text-base-content/40 font-normal">({length(@repo_paths)})</span>
      </h3>
      <p class="text-xs text-base-content/50 mt-1">
        <code>repo_paths</code> — repo name to local filesystem checkout path, used
        to resolve a dispatch's working directory.
      </p>

      <ul :if={@repo_paths != []} id="repo-paths" class="flex flex-col gap-1.5 mt-2">
        <li
          :for={{repo, path} <- @repo_paths}
          class="flex items-center gap-2 rounded-box border border-base-300 bg-base-100 px-3 py-2"
        >
          <code class="text-sm font-semibold">{repo}</code>
          <span class="text-xs font-mono text-base-content/60 flex-1">
            {path || "— (invalid entry)"}
          </span>
          <button
            type="button"
            phx-click="rm_repo_path"
            phx-target={@myself}
            phx-value-repo={repo}
            class="btn btn-ghost btn-xs text-error shrink-0"
            aria-label={"Remove repo path for #{repo}"}
            data-confirm={"Remove the repo_paths entry for #{repo}?"}
          >
            <.icon name="hero-trash" class="size-4" />
          </button>
        </li>
      </ul>

      <.form
        for={%{}}
        as={:repo_path}
        phx-submit="add_repo_path"
        phx-target={@myself}
        class="flex gap-2 items-start mt-2"
      >
        <input
          type="text"
          name="repo_path[repo]"
          placeholder="repo name, e.g. arbiter"
          class="input input-sm flex-1"
          required
        />
        <input
          type="text"
          name="repo_path[path]"
          placeholder="/home/ryan/dev/arbiter"
          class="input input-sm flex-1"
          required
        />
        <.button type="submit" class="btn btn-sm">
          <.icon name="hero-plus" class="size-4" /> Add
        </.button>
      </.form>
      <p :if={@repo_path_error} class="text-sm text-error mt-1">{@repo_path_error}</p>
    </div>
    """
  end
end
