defmodule Arbiter.Worker.PRTemplate do
  @moduledoc """
  Read + fill PR templates. Tracker-agnostic.

  A repo's PR template lives at `.github/pull_request_template.md` by
  convention. `read/1` returns its contents or `nil`. `fill/3` substitutes
  `{{key}}` placeholders against the task and its resolved tracker; lines
  whose substituted value is empty get dropped entirely (so a `:none`-tracked
  task doesn't leave behind an empty "Tracker:" line).

  ## Placeholder keys

    * `{{task.id}}` — e.g. `"gte-020"`
    * `{{task.title}}` — `issue.title`
    * `{{task.description}}` — `issue.description` (Markdown verbatim)
    * `{{task.acceptance}}` — `issue.acceptance`
    * `{{task.notes}}` — `issue.notes`
    * `{{task.qa_notes}}` — `issue.qa_notes`
    * `{{task.deployment_notes}}` — `issue.deployment_notes`
    * `{{task.priority}}` — `"P\#{issue.priority}"` (e.g. `"P0"`)
    * `{{task.issue_type}}` — `"task"`, `"bug"`, etc.
    * `{{tracker.link}}` — resolved via `Arbiter.Trackers.link_for/1`. Empty
      string for `Tracker.None`.
    * `{{tracker.ref}}` — `issue.tracker_ref` (e.g. `"VR-17585"` or `""`).
    * `{{tracker.type}}` — `"jira" | "shortcut" | "linear" | "github" | "gitlab" | "none"`.
    * `{{tracker.closes}}` — `"Closes #N"` for `:github`/`:gitlab` tasks with a
      bare numeric `tracker_ref`; `""` (line-dropped) for all others.

  Unknown placeholders are left in the output verbatim so templates can use
  `{{...}}` for non-substitution purposes if needed.

  ## Line dropping

  After substitution, any line whose substituted value is the empty string is
  removed. Concretely: if a line contains exactly one placeholder and that
  placeholder resolves to `""`, the line is dropped. If a line has multiple
  placeholders and ANY of them resolve to non-empty, the line stays (and the
  empty placeholders are blanked in-place).

  This is line-granularity, not section-granularity. Templates that need a
  whole section conditioned on tracker type can simply put the tracker
  placeholder on its own line; the section header before it stays.
  """

  alias Arbiter.Tasks.Issue
  alias Arbiter.Trackers

  @template_path ".github/pull_request_template.md"

  @doc """
  Read the PR template from `repo_worktree_path/#{@template_path}`. Returns
  the body string or `nil` if the file is missing.
  """
  @spec read(String.t()) :: String.t() | nil
  def read(repo_worktree_path) when is_binary(repo_worktree_path) do
    path = Path.join(repo_worktree_path, @template_path)

    case File.read(path) do
      {:ok, body} -> body
      {:error, _} -> nil
    end
  end

  @doc """
  Build a minimal PR body when no `.github/pull_request_template.md` exists.

  Produces a clean description containing: title (as a Markdown heading),
  description (if present), tracker link (if present), and — for
  `:github`/`:gitlab`-tracked tasks with a bare numeric `tracker_ref` — a
  `Closes #N` keyword so the provider auto-closes the issue on merge.
  """
  @spec default_body(Issue.t()) :: String.t()
  def default_body(%Issue{} = task) do
    link = safe_link_for(task)

    parts = ["## #{task.title}"]

    parts =
      if task.description && String.trim(task.description) != "",
        do: parts ++ [String.trim(task.description)],
        else: parts

    parts = if link != "", do: parts ++ [link], else: parts

    closing = closing_keyword(task)
    parts = if closing != "", do: parts ++ [closing], else: parts

    Enum.join(parts, "\n\n")
  end

  @doc """
  Substitute placeholders in `template` using `task` (an `%Issue{}`).

  Drops lines whose only placeholder resolves to empty (typical: a `:none`
  tracker leaves `{{tracker.link}}` empty and that line vanishes).
  """
  @spec fill(String.t(), Issue.t(), keyword()) :: String.t()
  def fill(template, %Issue{} = task, _opts \\ []) when is_binary(template) do
    placeholders = placeholders_for(task)

    body =
      template
      |> String.split("\n", trim: false)
      |> Enum.flat_map(&render_line(&1, placeholders))
      |> Enum.join("\n")

    closing = closing_keyword(task)

    if closing != "" do
      body <> "\n\n" <> closing
    else
      body
    end
  end

  # ---- internals ----

  defp render_line(line, placeholders) do
    refs = Regex.scan(~r/\{\{([a-z._]+)\}\}/, line, capture: :all_but_first) |> List.flatten()

    cond do
      refs == [] ->
        [line]

      all_empty?(refs, placeholders) ->
        # Drop the whole line — every placeholder it has is empty.
        []

      true ->
        [substitute(line, placeholders)]
    end
  end

  defp all_empty?(refs, placeholders) do
    Enum.all?(refs, fn key ->
      case Map.fetch(placeholders, key) do
        {:ok, ""} -> true
        {:ok, _} -> false
        # Unknown keys are NOT considered empty — leaving them alone is the
        # documented behaviour, so they shouldn't trigger a line drop.
        :error -> false
      end
    end)
  end

  defp substitute(line, placeholders) do
    Regex.replace(~r/\{\{([a-z._]+)\}\}/, line, fn whole, key ->
      Map.get(placeholders, key, whole)
    end)
  end

  defp placeholders_for(%Issue{} = task) do
    %{
      "task.id" => task.id || "",
      "task.title" => task.title || "",
      "task.description" => task.description || "",
      "task.acceptance" => task.acceptance || "",
      "task.notes" => task.notes || "",
      "task.qa_notes" => task.qa_notes || "",
      "task.deployment_notes" => task.deployment_notes || "",
      "task.priority" => "P#{task.priority}",
      "task.issue_type" => Atom.to_string(task.issue_type || :task),
      "tracker.link" => safe_link_for(task),
      "tracker.ref" => task.tracker_ref || "",
      "tracker.type" => Atom.to_string(task.tracker_type || :none),
      "tracker.closes" => closing_keyword(task)
    }
  end

  # Returns "Closes #N" for :github/:gitlab-tracked tasks whose tracker_ref is a
  # bare integer string (e.g. "42"), so the provider auto-closes the issue when
  # the PR/MR merges to the default branch. Both GitHub and GitLab honour the
  # `Closes #N` keyword in the PR/MR description. Returns "" for all other
  # tracker types — Jira/Linear/etc. have no such native close keyword.
  defp closing_keyword(%Issue{tracker_type: type, tracker_ref: ref})
       when type in [:github, :gitlab] and is_binary(ref) do
    if Regex.match?(~r/^\d+$/, ref), do: "Closes ##{ref}", else: ""
  end

  defp closing_keyword(_task), do: ""

  # Trackers.link_for/1 may raise for unregistered types; we don't want a
  # template-fill to crash the worker. Treat any failure as no-link.
  defp safe_link_for(task) do
    Trackers.link_for(task)
  rescue
    _ -> ""
  end
end
