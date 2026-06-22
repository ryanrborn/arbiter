defmodule ArbiterCli.Cmd.Create do
  @moduledoc """
  `arb create <title> [--description ...] [--priority N] [--difficulty N]
                       [--type T] [--deps id1,id2] [--labels a,b]
                       [--assignee a] [--tracker-ref REF] [--no-tracker]
                       [--target-branch NAME] [--parent <parent-id>]
                       [--ticket-only]`

  Creates a new issue in the resolved workspace (see `ArbiterCli.Workspace`).

  ## --difficulty N (0..4 / D0..D4)

  Sets how hard the task is. Orthogonal to `--priority`: priority answers
  "how urgent?"; difficulty answers "how hard?" and drives the model +
  thinking budget routed to workers that work the task. Classify by the
  MAX over: scope (files/modules touched), design uncertainty, reasoning
  depth (mechanical vs concurrency/correctness), blast radius, breadth of
  context required.

      D0 Trivial  — single-file, fully specified, no judgment
                    (typo, rename, config bump, doc edit).
      D1 Simple   — localized, clear approach, light reasoning;
                    follows an existing pattern.
      D2 Moderate — multi-file or some design choice; the common
                    feature case. **Default when unspecified.**
      D3 Hard     — cross-cutting, non-obvious design,
                    concurrency/state/edge-case correctness,
                    several components.
      D4 Extreme  — novel architecture, deep ambiguity,
                    correctness-critical; may warrant exploration
                    or multiple passes.

  The Admiral / filing session sets `--difficulty` at create time with a
  one-line justification in the task's description. Routing maps the value
  to abstract `{model_tier, thinking}` (see `Arbiter.Agents.Routing.ByDifficulty`).

  `--parent <parent-id>` attaches the new issue as a child of an existing parent
  task immediately after creation, by adding a `parent_of` dependency edge
  (`<parent-id> parent_of <new-id>`). The parent then rolls up child progress
  and can auto-close. Like `--deps`, the task is durable even if the attach
  fails — the failure is surfaced and arb exits non-zero.

  When the workspace has a tracker configured (`config["tracker"]["type"] !=
  none`), the server **also creates a corresponding upstream issue** and
  writes the returned ref back into `tracker_ref`. To opt out of that:

    * `--tracker-ref REF` — bind the new task to an *existing* upstream
      issue (skip outbound create). The ref is passed through to the create
      action as `tracker_ref`; the server's after-transaction hook sees the
      ref is already set and skips the API call.
    * `--no-tracker` / `--local-only` — create a purely local task even on a
      tracker-configured workspace. Forwards `skip_upstream_create=true` as
      the action argument.
    * `--ticket-only` / `--no-task` / `--unclaimed` — create ONLY the upstream
      tracker ticket, with NO local task. The ticket sits unclaimed on the
      shared tracker; anyone can pick it up via `arb claim <ref>`. The workspace
      must have a tracker configured. Mutually exclusive with `--no-tracker` /
      `--local-only` (opposite intent).
      Honored: `--title`, `--description`, `--priority`, `--type`, `--assignee`.
      Not honored (warning emitted): `--difficulty`, `--deps`, `--parent`,
      `--tracker-ref`, `--target-branch`, `--labels`.

  `--deps id1,id2` is a convenience that creates `blocks` dependencies for
  each listed issue (each becomes `<dep_id> blocks <new_id>`) AFTER the issue
  itself is created. If any dependency creation fails the new issue is left
  in place — the failure is reported and arb exits non-zero. Mirrors the
  upstream-create failure semantics: the task is durable, the failure is
  surfaced.

  `--labels` is accepted for interface parity with `bd` but the current Issue
  resource has no `labels` field; the value is reported back in a warning
  unless `--json` is set. The `labels` field is not yet part of the Issue resource.
  """

  alias ArbiterCli.{Client, Output, Workspace}

  @switches [
    description: :string,
    priority: :integer,
    difficulty: :integer,
    type: :string,
    deps: :string,
    labels: :string,
    assignee: :string,
    tracker_ref: :string,
    target_branch: :string,
    no_tracker: :boolean,
    local_only: :boolean,
    ticket_only: :boolean,
    no_task: :boolean,
    unclaimed: :boolean,
    parent: :string,
    auto_close: :boolean,
    force: :boolean,
    json: :boolean
  ]

  def run(argv) do
    if Output.help?(argv) do
      IO.puts(@moduledoc)
    else
      {opts, rest, _invalid} = OptionParser.parse(argv, switches: @switches)
      mode = if opts[:json], do: :json, else: :text

      title =
        case rest do
          [t] -> t
          [] -> Output.die("create requires a title argument")
          many -> Enum.join(many, " ")
        end

      ticket_only? =
        opts[:ticket_only] == true or opts[:no_task] == true or opts[:unclaimed] == true

      skip_upstream? = opts[:no_tracker] == true or opts[:local_only] == true

      if ticket_only? and skip_upstream? do
        Output.die(
          "--ticket-only and --no-tracker/--local-only are mutually exclusive: " <>
            "--ticket-only creates ONLY the tracker ticket, while --no-tracker skips the tracker entirely"
        )
      end

      if ticket_only? do
        run_ticket_only(opts, title, mode)
      else
        run_task_create(opts, rest, title, skip_upstream?, mode)
      end
    end
  end

  defp run_ticket_only(opts, title, mode) do
    workspace_id = Workspace.id_or_halt()

    ignored =
      [
        {"--difficulty", opts[:difficulty]},
        {"--deps", opts[:deps]},
        {"--parent", opts[:parent]},
        {"--tracker-ref", opts[:tracker_ref]},
        {"--target-branch", opts[:target_branch]},
        {"--labels", opts[:labels]}
      ]
      |> Enum.filter(fn {_flag, val} -> not is_nil(val) end)
      |> Enum.map(fn {flag, _val} -> flag end)

    if ignored != [] and mode == :text do
      IO.puts(
        :stderr,
        "arb: warning: --ticket-only ignores #{Enum.join(ignored, ", ")} (no local task is created)."
      )
    end

    payload =
      %{"title" => title}
      |> maybe_put("description", opts[:description])
      |> maybe_put("priority", opts[:priority])
      |> maybe_put("issue_type", opts[:type])
      |> maybe_put("assignee", opts[:assignee])

    ticket =
      case Client.post("/api/workspaces/#{workspace_id}/tracker/tickets", payload) do
        {:ok, body} -> body
        {:error, err} -> Output.die(err)
      end

    Output.emit_ticket(ticket, mode)
  end

  defp run_task_create(opts, _rest, title, skip_upstream?, mode) do
    workspace_id = Workspace.id_or_halt()
    force? = opts[:force] == true

    validate_difficulty!(opts[:difficulty])

    payload =
      %{"title" => title, "workspace_id" => workspace_id}
      |> maybe_put("description", opts[:description])
      |> maybe_put("priority", opts[:priority])
      |> maybe_put("difficulty", opts[:difficulty])
      |> maybe_put("issue_type", opts[:type])
      |> maybe_put("assignee", opts[:assignee])
      |> maybe_put("tracker_ref", opts[:tracker_ref])
      |> maybe_put("target_branch", opts[:target_branch])
      |> maybe_put_flag("auto_close", opts[:auto_close] == true)
      |> maybe_put_flag("skip_upstream_create", skip_upstream?)
      |> maybe_put_flag("force", force?)

    if opts[:labels] && mode == :text do
      IO.puts(
        :stderr,
        "arb: warning: --labels is accepted for interface parity but the Issue resource has no labels field (ignored)."
      )
    end

    issue =
      case Client.post("/api/issues", payload) do
        {:ok, body} ->
          body

        {:error, err} ->
          # Includes the upstream-create-failed (HTTP 502) path: the task was
          # created locally but the upstream tracker call failed. The error
          # message embeds the task id so the user can recover via
          # `arb update <id> --tracker-ref N`.
          Output.die(err)
      end

    if opts[:deps] do
      attach_deps(issue["id"], opts[:deps])
    end

    if opts[:parent] do
      attach_parent(issue["id"], opts[:parent])
    end

    Output.emit_issue(issue, mode)
  end

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, _key, ""), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  defp maybe_put_flag(map, _key, false), do: map
  defp maybe_put_flag(map, key, true), do: Map.put(map, key, true)

  defp validate_difficulty!(nil), do: :ok
  defp validate_difficulty!(n) when is_integer(n) and n in 0..4, do: :ok

  defp validate_difficulty!(other) do
    Output.die("invalid --difficulty #{inspect(other)} (must be an integer 0..4 / D0..D4)")
  end

  defp attach_deps(new_id, raw) do
    raw
    |> String.split(",", trim: true)
    |> Enum.map(&String.trim/1)
    |> Enum.each(fn dep_id ->
      body = %{"from_issue_id" => dep_id, "to_issue_id" => new_id, "type" => "blocks"}

      case Client.post("/api/dependencies", body) do
        {:ok, _} ->
          :ok

        {:error, err} ->
          Output.die(%{
            err
            | message: "failed to add dependency #{dep_id} -> #{new_id}: #{err.message}"
          })
      end
    end)
  end

  # Attach the freshly-created issue as a child of an existing parent task via a
  # `parent_of` edge (`parent_id parent_of new_id`). The task is durable; a
  # failed attach is surfaced and arb exits non-zero, mirroring `attach_deps/2`.
  defp attach_parent(new_id, parent_id) do
    body = %{"from_issue_id" => parent_id, "to_issue_id" => new_id, "type" => "parent_of"}

    case Client.post("/api/dependencies", body) do
      {:ok, _} ->
        :ok

      {:error, err} ->
        Output.die(%{
          err
          | message: "failed to attach #{new_id} to parent #{parent_id}: #{err.message}"
        })
    end
  end
end
