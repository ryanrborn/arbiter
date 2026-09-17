defmodule Arbiter.Sessions.RefineDoctrine do
  @moduledoc """
  The filing doctrine a refine session's instructions carry (bd-980x89), as a
  versioned template.

  Until now this lived only in the operator's own coordinator seat — a
  `CLAUDE.md` plus memory the operator hand-maintains outside Arbiter, which
  means it only ever reaches *that* operator's coordinator sessions, never a
  refine session, and never a second install. This module is the doctrine
  moved into Arbiter proper: a versioned template (`template/0`, `@version`)
  any refine session's instructions render verbatim, with a per-workspace
  override for installs that want their own filing conventions.

  ## Per-workspace override

  `Arbiter.Tasks.Workspace.config["refine"]` follows the same
  `get_in(workspace.config, [...])` shape every other workspace setting uses
  (see `Arbiter.Tasks.Workspace.pr_title_format/1` for the pattern):

    * `config["refine"]["doctrine"]` — an inline string that replaces
      `template/0` outright for that workspace.
    * `config["refine"]["doctrine_path"]` — a file path read at render time
      instead, for operators who would rather hand-edit a file than a JSON
      blob. Takes precedence over `"doctrine"` when both are set.

  Absent either key, `content/1` returns `template/0` unchanged — the common
  case for every workspace that has not opted into its own doctrine.
  """

  alias Arbiter.Tasks.Workspace

  @version "1"

  @doc "The doctrine template's version — bump when the content changes materially."
  @spec version() :: String.t()
  def version, do: @version

  @doc """
  Resolve the doctrine for a workspace: its override if one is configured,
  else `template/0`.

  `nil` (no workspace bound) always returns `template/0` — there is nothing
  to look an override up on.
  """
  @spec content(Workspace.t() | nil) :: String.t()
  def content(nil), do: template()

  def content(%Workspace{config: config}) do
    config = config || %{}

    case doctrine_path(config) do
      {:ok, path} -> read_doctrine_path(path)
      :none -> doctrine_override(config) || template()
    end
  end

  defp doctrine_path(config) do
    case get_in(config, ["refine", "doctrine_path"]) do
      path when is_binary(path) and path != "" -> {:ok, path}
      _ -> :none
    end
  end

  defp read_doctrine_path(path) do
    case File.read(path) do
      {:ok, text} -> text
      {:error, _reason} -> template()
    end
  end

  defp doctrine_override(config) do
    case get_in(config, ["refine", "doctrine"]) do
      text when is_binary(text) and text != "" -> text
      _ -> nil
    end
  end

  @doc "The built-in filing doctrine, version `#{@version}`."
  @spec template() :: String.t()
  def template do
    """
    ## Filing doctrine

    This is how issues get filed and refined in Arbiter. It applies to the
    bound issue and to any children you file under it.

    ### Priority and difficulty

    Two independent axes:

    * **Priority P0–P4** — urgency. How soon this needs attention, independent
      of how hard it is.
    * **Difficulty D0–D5** — hardness. Rate it as the **MAX** over: scope (how
      much surface changes), design uncertainty (how settled the approach
      is), reasoning depth (how much judgment a step requires), blast radius
      (what breaks if it's wrong) and breadth (how many call sites or files
      it touches). The highest of those five decides the rating, not their
      average.

    The D0–D5 rubric:

    * **D0** — trivial, mechanical, one file, no judgment calls.
    * **D1** — small, contained, one clear approach.
    * **D2** — a real but bounded change: a few files, one seam, low design
      uncertainty.
    * **D3** — meaningful scope or uncertainty: several files or one
      genuinely uncertain design decision.
    * **D4** — wide scope, real design uncertainty, or a large blast radius —
      the kind of work that benefits from being split into chained children
      rather than attempted whole.
    * **D5** — reserved for the hardest work in the system. **D5 is never
      assigned by this session.** If a rating would land here, split the
      issue into D4-or-lower children instead, or flag it to the operator
      rather than filing it as D5 yourself.

    Include a **one-line difficulty justification** in the issue description
    — which of the five factors drove the rating, and why.

    **Ratings historically run about one tier low.** Bias up, especially for
    OTP/process-supervision work, anything on the production write path, or
    acceptance criteria that can't be mechanically verified — those three
    kinds of work are exactly where a rating that looks right in the moment
    turns out to have been a tier under.

    ### issue_type semantics

    Get the type right before promotion — **it is fixed at dispatch** and
    changing it afterward does not retroactively change what already ran.

    * **`bug` / `feature` / `chore`** — a PR is expected. ReviewGate engages
      on the resulting PR.
    * **`task`** — no PR. Research or investigation only. The commit gate and
      ReviewGate are both skipped for a `task`-typed issue, so **never use
      `task` for code work** — code that ships without ReviewGate ever
      seeing it is not a task, it is an unreviewed change wearing a task's
      name.
    * **`decision`** — a documented choice, not an implementation.
    * **`epic`** — a parent grouping children; nothing is implemented against
      an epic directly.

    ### Acceptance criteria

    * Concrete and testable. No "ideally" tier — every AC is either met or
      not, with nothing you have to interpret to decide which.
    * **Ground them in the code.** Read the actual fields, values and
      function signatures involved rather than asserting from the shape of
      the work, and grep the real call sites. Invariant-shaped criteria
      ("update X everywhere it's used") often hide N separate edits —
      enumerate them explicitly and rate the difficulty for that fan-out,
      not for the one-line description of the invariant.
    * **Never write an AC a sandboxed worker can't satisfy.** No live
      credentials, no prod access, no real third-party network traffic.
      Author local fixtures instead of asserting against a real external
      service.
    * A check that only a running server or production can prove goes in a
      **final AC marked "POST-MERGE, coordinator-owned; NOT a merge gate
      (reviewers mark it [DEFERRED], never [NOT MET])"**, and the issue sets
      **`verify_after_deploy`** so the coordinator restarts and observes it
      once before the issue closes.
    * End the acceptance list with the repo's own test/precommit gate (e.g.
      `mix precommit` passes).

    ### Splitting

    Prefer several scoped children chained with `depends_on` over one broad
    D4 issue. When filing children:

    * Put descendants under the bound issue (`parent_of`).
    * **Write all edges before promoting anything.** An edge written after
      promotion is an edge Autopilot may already have scheduled around.
    * Use `depends_on`, not `conflicts_with`, to order work that touches the
      dock or shared files — Autopilot does not yet honor `conflicts_with`
      (bd-6bax7s), so it is not a real ordering guarantee today.

    ### Promotion

    Promote **only** once the operator has agreed, in the conversation, that
    the issue — and any children — are ready, and only **after** every edge
    is written. Promote children and the bound issue together, at the end,
    not one at a time as they're written.

    Write a short refinement summary to the issue before promotion.

    **This refine session ends when the bound issue is promoted.** There is
    no further work for it to do after that — promotion is the handoff.
    """
  end
end
