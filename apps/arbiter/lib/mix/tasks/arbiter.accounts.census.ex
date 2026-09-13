defmodule Mix.Tasks.Arbiter.Accounts.Census do
  @shortdoc "Read-only census of provider credentials in every workspace's worker_env"

  @moduledoc """
  Phase P0 of the provider-accounts migration (`docs/provider-account-design.md`
  §7.1). Decrypts every workspace's `worker_env` **in memory**, partitions its
  keys into allowlisted provider-credential keys and everything else, groups the
  credentials by `(provider, sha256(secret))`, prints the result, and writes a
  **candidate** `accounts.json` plan for the operator to edit.

  **This task writes nothing to the database and prints no value** — only
  counts, workspace names, env var names and truncated fingerprints. The full
  plan format, and what it deliberately omits, is documented in
  `Arbiter.Accounts.Census`.

  ## Usage

      mix arbiter.accounts.census
      mix arbiter.accounts.census --plan /tmp/accounts.json
      mix arbiter.accounts.census --operator-credential ~/.claude/.credentials.json
      mix arbiter.accounts.census --force

  ## Options

    * `--plan PATH` — where to write the candidate plan. Default `accounts.json`
      in the current directory. Written mode `0600`.
    * `--force` — overwrite an existing plan file. Without it the task refuses,
      because a plan an operator has already edited is the artefact of record.
    * `--operator-credential PATH` — additionally fingerprint the Claude CLI
      token at `PATH` (`claudeAiOauth.accessToken`) and offer it as a
      **suggested, unconfirmed** second credential on the sole Claude candidate
      (§7.2). Only the fingerprint is ever read out of that file; nothing is
      written back to it. The path is deliberately explicit rather than defaulted
      so this task never reads the operator's credentials without being asked.

  ## After running it

  The plan is *proposed, never applied*. Distinct fingerprints are distinct
  candidates, but §2.2's counter-example (two tokens, one Anthropic plan) is
  already present on this host — so read the census, merge the candidates you
  know to be one account, rename the slugs, and only then hand the file to the
  future `mix arbiter.accounts.migrate --plan accounts.json`.
  """

  use Mix.Task

  require Logger

  alias Arbiter.Accounts.Census

  @default_plan "accounts.json"

  @switches [plan: :string, force: :boolean, operator_credential: :string]

  @impl Mix.Task
  def run(argv) do
    Mix.Task.run("app.start")
    execute(argv)
  end

  @doc """
  Everything `run/1` does after the application has booted.

  Split out so the census can be exercised against a real, seeded, sandboxed
  database in tests — `Mix.Task.run("app.start")` cannot run under the Ecto
  sandbox.
  """
  @spec execute([String.t()]) :: :ok
  def execute(argv) do
    {opts, _rest, invalid} = OptionParser.parse(argv, switches: @switches)

    unless invalid == [] do
      Mix.raise("unrecognised option(s): #{Enum.map_join(invalid, ", ", &elem(&1, 0))}")
    end

    plan_path = Keyword.get(opts, :plan, @default_plan)
    force? = Keyword.get(opts, :force, false)

    if File.exists?(plan_path) and not force? do
      Mix.raise("#{plan_path} already exists; re-run with --force to overwrite it")
    end

    census = Census.run(operator_credential_opts(opts))

    Mix.shell().info(Census.report(census))

    Census.write_plan!(census, plan_path, true)

    Mix.shell().info("""

    Candidate plan written to #{plan_path} (mode 0600). It is a proposal:
    rename the slugs, merge any candidates you know to be one account, then run
    the migrate step against it. Nothing was written to the database.\
    """)

    # Fingerprints and counts only — see §7.4's "Logs" row.
    Logger.info(
      "Arbiter.Accounts.Census: scanned #{census.totals.workspaces} workspace(s), " <>
        "#{census.totals.credential_keys} provider-credential key(s), " <>
        "#{census.totals.accounts} candidate account(s); plan written to #{plan_path}"
    )

    :ok
  end

  # Resolves `--operator-credential` into the fingerprint-only shape `build/2`
  # takes. A read failure is a note on the census, not an abort: the rest of the
  # inventory is still worth having.
  defp operator_credential_opts(opts) do
    case Keyword.fetch(opts, :operator_credential) do
      :error ->
        []

      {:ok, path} ->
        case Census.operator_credential(path) do
          {:ok, credential} ->
            [operator_credential: credential]

          {:error, reason} ->
            Mix.shell().info("\nOperator credential: could not read #{path} (#{reason}).")
            [operator_credential_error: reason]
        end
    end
  end
end
