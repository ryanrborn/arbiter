defmodule Arbiter.Worker.PRTemplate do
  @moduledoc """
  Read + fill PR templates. Tracker-agnostic.

  A repo's PR template lives at `.github/pull_request_template.md` by
  convention. `read/1` returns its contents or `nil`. `fill/3` substitutes
  `{{key}}` placeholders against the bead and its resolved tracker; lines
  whose substituted value is empty get dropped entirely (so a `:none`-tracked
  bead doesn't leave behind an empty "Tracker:" line).

  ## Placeholder keys

    * `{{bead.id}}` — e.g. `"gte-020"`
    * `{{bead.title}}` — `issue.title`
    * `{{bead.description}}` — `issue.description` (Markdown verbatim)
    * `{{bead.acceptance}}` — `issue.acceptance`
    * `{{bead.notes}}` — `issue.notes`
    * `{{bead.qa_notes}}` — `issue.qa_notes`
    * `{{bead.deployment_notes}}` — `issue.deployment_notes`
    * `{{bead.priority}}` — `"P\#{issue.priority}"` (e.g. `"P0"`)
    * `{{bead.issue_type}}` — `"task"`, `"bug"`, etc.
    * `{{tracker.link}}` — resolved via `Arbiter.Trackers.link_for/1`. Empty
      string for `Tracker.None`.
    * `{{tracker.ref}}` — `issue.tracker_ref` (e.g. `"VR-17585"` or `""`).
    * `{{tracker.type}}` — `"jira" | "linear" | "github" | "none"`.
    * `{{tracker.closes}}` — `"Closes #N"` for `:github` beads with a bare
      numeric `tracker_ref`; `""` (line-dropped) for all others.

  Unknown placeholders are left in the output verbatim so templates can use
  `{{...}}` for non-substitution purposes if needed.

  ## Line dropping

  After substitution, any line whose substituted value is the empty string is
  removed. Concretely: if a line contains exactly one placeholder and that
  placeholder resolves to `""`, the line is dropped. If a line has multiple
  placeholders and ANY of them resolve to non-empty, the line stays (and the
  empty placeholders are blanked in-place).

  This is line-granularity, not section-granularity — see BUILD-SUMMARY for
  the rationale (templates that need a whole section conditioned on tracker
  type can simply put the tracker placeholder on its own line; the section
  header before it stays).
  """

  alias Arbiter.Beads.Issue
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
  `:github`-tracked beads with a bare numeric `tracker_ref` — a
  `Closes #N` keyword so GitHub auto-closes the issue on merge.
  """
  @spec default_body(Issue.t()) :: String.t()
  def default_body(%Issue{} = bead) do
    link = safe_link_for(bead)

    parts = ["## #{bead.title}"]

    parts =
      if bead.description && String.trim(bead.description) != "",
        do: parts ++ [String.trim(bead.description)],
        else: parts

    parts = if link != "", do: parts ++ [link], else: parts

    closing = closing_keyword(bead)
    parts = if closing != "", do: parts ++ [closing], else: parts

    Enum.join(parts, "\n\n")
  end

  @doc """
  Substitute placeholders in `template` using `bead` (an `%Issue{}`).

  Drops lines whose only placeholder resolves to empty (typical: a `:none`
  tracker leaves `{{tracker.link}}` empty and that line vanishes).
  """
  @spec fill(String.t(), Issue.t(), keyword()) :: String.t()
  def fill(template, %Issue{} = bead, _opts \\ []) when is_binary(template) do
    placeholders = placeholders_for(bead)

    body =
      template
      |> String.split("\n", trim: false)
      |> Enum.flat_map(&render_line(&1, placeholders))
      |> Enum.join("\n")

    closing = closing_keyword(bead)

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

  defp placeholders_for(%Issue{} = bead) do
    %{
      "bead.id" => bead.id || "",
      "bead.title" => bead.title || "",
      "bead.description" => bead.description || "",
      "bead.acceptance" => bead.acceptance || "",
      "bead.notes" => bead.notes || "",
      "bead.qa_notes" => bead.qa_notes || "",
      "bead.deployment_notes" => bead.deployment_notes || "",
      "bead.priority" => "P#{bead.priority}",
      "bead.issue_type" => Atom.to_string(bead.issue_type || :task),
      "tracker.link" => safe_link_for(bead),
      "tracker.ref" => bead.tracker_ref || "",
      "tracker.type" => Atom.to_string(bead.tracker_type || :none),
      "tracker.closes" => closing_keyword(bead)
    }
  end

  # Returns "Closes #N" for :github-tracked beads whose tracker_ref is a bare
  # integer string (e.g. "42"), so GitHub auto-closes the issue on merge.
  # Returns "" for all other tracker types — Jira/Linear/etc. have no such
  # native close keyword.
  defp closing_keyword(%Issue{tracker_type: :github, tracker_ref: ref})
       when is_binary(ref) do
    if Regex.match?(~r/^\d+$/, ref), do: "Closes ##{ref}", else: ""
  end

  defp closing_keyword(_bead), do: ""

  # Trackers.link_for/1 may raise for unregistered types; we don't want a
  # template-fill to crash the worker. Treat any failure as no-link.
  defp safe_link_for(bead) do
    Trackers.link_for(bead)
  rescue
    _ -> ""
  end
end
