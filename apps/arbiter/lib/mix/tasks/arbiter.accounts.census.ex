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

  ## Release installs

  A thin wrapper over `Arbiter.Release.accounts_census/1`, which a release
  install (no Mix toolchain) runs directly:

      bin/arbiter eval 'Arbiter.Release.accounts_census(plan: "/home/me/.arbiter/accounts.json")'

  See `docs/provider-accounts-release-runbook.md` for the full procedure.
  """

  use Mix.Task

  @switches [plan: :string, force: :boolean, operator_credential: :string]

  @impl Mix.Task
  def run(argv) do
    # Config only: `Arbiter.Release.accounts_census/1` starts Ash, the Repo and
    # the Vault itself, never the full application next to a live server.
    Mix.Task.run("app.config")
    execute(argv)
  end

  @doc """
  Everything `run/1` does after config is loaded: parse `argv` and hand off to
  `Arbiter.Release.accounts_census/1`, which holds the logic so a release
  install can run the same census through `bin/arbiter eval`.

  Split out so the census can be exercised against a real, seeded, sandboxed
  database in tests.
  """
  @spec execute([String.t()]) :: :ok
  def execute(argv) do
    {opts, _rest, invalid} = OptionParser.parse(argv, switches: @switches)

    unless invalid == [] do
      Mix.raise("unrecognised option(s): #{Enum.map_join(invalid, ", ", &elem(&1, 0))}")
    end

    release_opts =
      [cli: :mix, force?: Keyword.get(opts, :force, false)]
      |> put_opt(:plan, opts[:plan])
      |> put_opt(:operator_credential, opts[:operator_credential])

    _census = Arbiter.Release.accounts_census(release_opts)
    :ok
  rescue
    e in Arbiter.Release.Refused -> Mix.raise(e.message)
  end

  defp put_opt(opts, _key, nil), do: opts
  defp put_opt(opts, key, value), do: Keyword.put(opts, key, value)
end
