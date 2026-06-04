defmodule ArbiterCli.Cmd.Update do
  @moduledoc """
  `arb update` wears two hats, chosen by whether you name an issue.

  ## Deploy mode — `arb update [--timeout SECONDS] [--json]`

  With **no issue id**, `arb update` deploys freshly-merged work: it
  `git pull --ff-only`s the integration branch (`main`) in the Arbiter
  checkout, reports what changed, then reuses `arb restart` to bounce Phoenix
  so the new code is live. One verb for the contributor + Admiral to ship
  merged work.

  Steps:

    1. **Locate the checkout** — the Arbiter project root (same resolution as
       `arb start`/`arb restart`: `ARB_HOME`, the escript's umbrella, or a
       walk up for `compose.yml`).
    2. **Refuse to clobber work.** Abort if the working tree is dirty, or if
       `HEAD` isn't on the integration branch — deploying is a fast-forward of
       `main`, never a merge or a branch switch under a running server.
    3. **`git pull --ff-only`.** A non-fast-forward (diverged history) makes
       git itself abort; we surface its message rather than force anything.
    4. **Report the short log** of the commits that arrived
       (`git log --oneline old..new`). If nothing arrived, say "already up to
       date" and skip the restart — there's no new code to load.
    5. **Restart Phoenix** via `ArbiterCli.Cmd.Restart.perform/2`, which also
       re-runs the boot reconciler. Migrations are handled at boot by the
       app's supervision-tree migrator, so `arb update` carries no migration
       logic of its own.

  ## Issue-edit mode — `arb update <id> [field flags]`

  With an **issue id**, `arb update` patches that issue's fields:

      arb update <id> [--priority N] [--append-notes text] [--status s]
                      [--description d] [--assignee a]

  `--append-notes` appends the given string to the existing `notes` field
  (separated by two newlines). This requires fetching the issue first so we
  don't lose existing notes.

  ## Why one verb

  The two modes never collide: editing an issue *requires* an id, so any
  invocation with a positional argument is an edit, and a bare `arb update`
  (which previously just errored "requires an issue id") becomes the deploy.

  ## Exit codes

    * `0` — issue patched, or deploy succeeded (or was already up to date).
    * `1` — a bad invocation, an API error, a dirty/diverged checkout, or
      Phoenix not coming back green after the restart.
  """

  alias ArbiterCli.{Client, Cmd.Doctor, Cmd.Restart, Cmd.Start, Output}

  # The branch `arb update` fast-forwards. Matches the repo's integration
  # branch (`main`); a deploy is always a pull of merged work into it.
  @integration_branch "main"

  # Forwarded to the restart's green-wait. Mirrors `arb restart`'s default;
  # a cold `mix phx.server` may recompile, so it's generous.
  @default_timeout_s 60

  @edit_switches [
    priority: :integer,
    append_notes: :string,
    notes: :string,
    status: :string,
    description: :string,
    title: :string,
    assignee: :string,
    json: :boolean
  ]

  @deploy_switches [json: :boolean, timeout: :integer]

  def run(argv) do
    if deploy_invocation?(argv) do
      deploy(argv)
    else
      edit_issue(argv)
    end
  end

  # A bare verb, or one whose first token is a flag, is a deploy. The moment a
  # positional appears (the issue id) it's an edit — see the moduledoc.
  defp deploy_invocation?([]), do: true
  defp deploy_invocation?([first | _]), do: String.starts_with?(first, "-")

  # ---- deploy mode -------------------------------------------------------

  defp deploy(argv) do
    {opts, _rest, invalid} = OptionParser.parse(argv, strict: @deploy_switches)

    if invalid != [] do
      [{flag, _} | _] = invalid

      Output.die(
        "unknown option #{flag} for `arb update`",
        "To deploy, run `arb update` with no issue id. To edit an issue, " <>
          "name it: `arb update <id> #{flag} …`."
      )
    end

    mode = if opts[:json], do: :json, else: :text
    timeout_ms = max(1, opts[:timeout] || @default_timeout_s) * 1000

    root =
      case Start.project_root() do
        {:ok, dir} ->
          dir

        :error ->
          Output.die(
            "could not locate the Arbiter project root (no compose.yml found)",
            "Set ARB_HOME to your Arbiter checkout, or run `arb update` from inside it."
          )
      end

    ensure_on_integration_branch(root)
    ensure_clean_tree(root)

    before_sha = head_sha(root)
    git_pull(root)
    after_sha = head_sha(root)

    if before_sha == after_sha do
      emit_up_to_date(mode)
    else
      commits = short_log(root, before_sha, after_sha)
      Start.log_text("Pulled #{length(commits)} new commit(s); restarting Phoenix…")

      case Restart.perform(root, timeout_ms) do
        {:ok, actions, was_running} ->
          emit_deployed(mode, before_sha, after_sha, commits, actions, was_running)

        {:timeout, actions, _was_running} ->
          emit_deploy_timeout(mode, before_sha, after_sha, commits, actions, timeout_ms)
      end
    end
  end

  # ---- git ---------------------------------------------------------------

  defp ensure_on_integration_branch(root) do
    case git(root, ["rev-parse", "--abbrev-ref", "HEAD"]) do
      {out, 0} ->
        branch = String.trim(out)

        unless branch == @integration_branch do
          Output.die(
            "the checkout is on `#{branch}`, not the integration branch `#{@integration_branch}`",
            "`arb update` fast-forwards `#{@integration_branch}`. " <>
              "Switch with `git checkout #{@integration_branch}` first."
          )
        end

      {out, _code} ->
        Output.die(
          "could not determine the current git branch",
          "Is #{root} a git checkout? Output:\n" <> String.trim_trailing(out)
        )
    end
  end

  defp ensure_clean_tree(root) do
    case git(root, ["status", "--porcelain"]) do
      {"", 0} ->
        :ok

      {out, 0} ->
        Output.die(
          "the working tree has uncommitted changes",
          "Commit or stash them before `arb update`:\n" <> String.trim_trailing(out)
        )

      {out, _code} ->
        Output.die(
          "could not read git status",
          "Output:\n" <> String.trim_trailing(out)
        )
    end
  end

  defp head_sha(root) do
    case git(root, ["rev-parse", "HEAD"]) do
      {out, 0} ->
        String.trim(out)

      {out, _code} ->
        Output.die(
          "could not read HEAD",
          "Output:\n" <> String.trim_trailing(out)
        )
    end
  end

  defp git_pull(root) do
    Start.log_text("Pulling #{@integration_branch} (git pull --ff-only)…")

    case git(root, ["pull", "--ff-only"]) do
      {_out, 0} ->
        :ok

      {out, code} ->
        Output.die(
          "git pull --ff-only failed (exit #{code})",
          "The branch may have diverged from its upstream (a non-fast-forward). " <>
            "Resolve it manually. Output:\n" <> String.trim_trailing(out)
        )
    end
  end

  # `git log --oneline old..new` → a list of {sha, subject} for the new commits.
  defp short_log(root, before_sha, after_sha) do
    case git(root, ["log", "--oneline", "--no-decorate", "#{before_sha}..#{after_sha}"]) do
      {out, 0} ->
        out
        |> String.split("\n", trim: true)
        |> Enum.map(fn line ->
          case String.split(line, " ", parts: 2) do
            [sha, subject] -> %{sha: sha, subject: subject}
            [sha] -> %{sha: sha, subject: ""}
          end
        end)

      {_out, _code} ->
        # The pull already succeeded; a log failure shouldn't abort the deploy.
        []
    end
  end

  # `git`, routed through `arb start`'s `:bd2_cmd_runner` seam so one test stub
  # covers the pull and the reused restart. Always run inside `root`.
  defp git(root, args) do
    Start.run_cmd("git", args, cd: root, stderr_to_stdout: true)
  rescue
    e in ErlangError ->
      Output.die(
        "could not run git: #{inspect(e.original)}",
        "Ensure git is installed and on your PATH."
      )
  end

  # ---- deploy output -----------------------------------------------------

  defp emit_up_to_date(:json) do
    IO.puts(
      Jason.encode!(%{
        branch: @integration_branch,
        pulled: false,
        up_to_date: true,
        restarted: false,
        commits: [],
        ok: true
      })
    )
  end

  defp emit_up_to_date(:text) do
    IO.puts("Already up to date on #{@integration_branch} — nothing to deploy.")
    IO.puts("(Run `arb restart` if you want to bounce Phoenix anyway.)")
  end

  defp emit_deployed(:json, before_sha, after_sha, commits, actions, was_running) do
    IO.puts(
      Jason.encode!(%{
        branch: @integration_branch,
        pulled: true,
        up_to_date: false,
        restarted: true,
        was_running: was_running,
        old_sha: before_sha,
        new_sha: after_sha,
        commits: commits,
        actions: action_payload(actions),
        base_url: Client.base_url(),
        checks: Enum.map(Doctor.checks(), &Map.from_struct/1),
        ok: Doctor.green?()
      })
    )
  end

  defp emit_deployed(:text, _before, _after, commits, _actions, _was_running) do
    IO.puts("")
    IO.puts("Pulled #{length(commits)} new commit(s) onto #{@integration_branch}:")
    print_commits(commits)
    IO.puts("")
    IO.puts("Arbiter Phoenix restarted at #{Client.base_url()}")
    IO.puts("")
    Doctor.report()
  end

  defp emit_deploy_timeout(:json, before_sha, after_sha, commits, actions, timeout_ms) do
    IO.puts(
      Jason.encode!(%{
        branch: @integration_branch,
        pulled: true,
        up_to_date: false,
        restarted: false,
        old_sha: before_sha,
        new_sha: after_sha,
        commits: commits,
        actions: action_payload(actions),
        base_url: Client.base_url(),
        checks: Enum.map(Doctor.checks(), &Map.from_struct/1),
        ok: false,
        timed_out_after_s: div(timeout_ms, 1000)
      })
    )

    Output.halt(1)
  end

  defp emit_deploy_timeout(:text, _before, _after, commits, _actions, timeout_ms) do
    IO.puts("")
    IO.puts("Pulled #{length(commits)} new commit(s) onto #{@integration_branch}:")
    print_commits(commits)
    IO.puts("")
    IO.puts("…but Phoenix did not come back up within #{div(timeout_ms, 1000)}s.")
    IO.puts("Last status:")
    IO.puts("")
    Doctor.report()
    IO.puts("")
    IO.puts("hint: tail #{Start.phoenix_log_path()} for Phoenix startup output.")
    Output.halt(1)
  end

  defp print_commits(commits) do
    Enum.each(commits, fn %{sha: sha, subject: subject} ->
      IO.puts("  #{sha}  #{subject}")
    end)
  end

  defp action_payload(actions) do
    Enum.map(actions, fn {component, status, detail} ->
      base = %{component: to_string(component), status: to_string(status)}
      if is_list(detail), do: Map.put(base, :pids, detail), else: base
    end)
  end

  # ---- issue-edit mode ---------------------------------------------------

  defp edit_issue(argv) do
    {opts, rest, _invalid} = OptionParser.parse(argv, switches: @edit_switches)
    mode = if opts[:json], do: :json, else: :text

    id =
      case rest do
        [id] -> id
        [] -> Output.die("update requires an issue id")
        _ -> Output.die("update takes exactly one positional argument: the issue id")
      end

    existing =
      if opts[:append_notes] do
        case Client.get("/api/issues/" <> id) do
          {:ok, body} -> body
          {:error, err} -> Output.die(err)
        end
      end

    payload =
      %{}
      |> put_if("priority", opts[:priority])
      |> put_if("notes", opts[:notes])
      |> put_if("status", opts[:status])
      |> put_if("description", opts[:description])
      |> put_if("title", opts[:title])
      |> put_if("assignee", opts[:assignee])
      |> maybe_append_notes(opts[:append_notes], existing)

    if map_size(payload) == 0 do
      Output.die("update requires at least one field flag (e.g. --priority, --append-notes)")
    end

    case Client.patch("/api/issues/" <> id, payload) do
      {:ok, issue} -> Output.emit_issue(issue, mode)
      {:error, err} -> Output.die(err)
    end
  end

  defp put_if(map, _key, nil), do: map
  defp put_if(map, _key, ""), do: map
  defp put_if(map, key, value), do: Map.put(map, key, value)

  defp maybe_append_notes(payload, nil, _existing), do: payload

  defp maybe_append_notes(payload, addition, existing) do
    combined =
      case existing["notes"] do
        n when n in [nil, ""] -> addition
        prev -> prev <> "\n\n" <> addition
      end

    Map.put(payload, "notes", combined)
  end
end
