defmodule Arbiter.Accounts.Census do
  @moduledoc """
  Phase P0 of the provider-accounts migration (`docs/provider-account-design.md`
  §7.1): a **read-only** inventory of the provider credentials currently living
  inside every workspace's encrypted `worker_env`.

  The census decrypts each `worker_env` **in memory**, partitions its keys into
  allowlisted provider-credential keys and everything else (§7.3), groups the
  credentials by `(provider, sha256(secret))` (§7.2), and reports **counts, key
  names, workspace names and fingerprints — never values**.

  Nothing here writes to the database, and nothing here is applied. The output
  is a *candidate* plan the operator edits and then feeds to a future
  `mix arbiter.accounts.migrate --plan`.

  ## Why the grouping is only a proposal

  Fingerprint equality proves two workspaces hold the same secret. Fingerprint
  *inequality* proves nothing — §2.1 measured two different tokens belonging to
  one Anthropic plan on this very host. So distinct fingerprints are rendered as
  distinct **candidates**, which the operator is expected to merge by hand
  before applying. See §2.2.

  ## The allowlist (§7.3)

  Only the keys in `credential_keys/0` are ever treated as credentials. A key
  that merely *looks* credential-ish (`GITHUB_TOKEN`, `MY_SECRET`) is reported
  by name under `unmoved_keys` and stays on the workspace. The list is explicit
  and versioned here rather than inferred, because the failure mode of a
  heuristic is moving an unrelated secret into a provider-credential table.

  Numbered pool variants (`ANTHROPIC_API_KEY_2`, the shape
  `Arbiter.Agents.Claude.Config`'s `credentials_refs` pool uses) are
  deliberately **not** allowlisted in P0. They are surfaced as a note so the
  operator sees them, but a P0 census does not decide how a key pool maps onto
  account rows.

  ## Plan file format

  `plan/1` returns the document `write_plan!/3` serialises to `accounts.json`
  (mode `0600`). It is JSON with string keys, and it is the format a future
  `mix arbiter.accounts.migrate --plan accounts.json` consumes:

      {
        "kind": "arbiter.accounts.plan",
        "version": 1,
        "generated_at": "2026-09-12T12:00:00Z",
        "generated_by": "mix arbiter.accounts.census",
        "applied": false,
        "fingerprint": {
          "algorithm": "sha256",
          "encoding": "hex",
          "of": "the raw secret value"
        },
        "accounts": [
          {
            "slug": "claude-1",              // operator renames this
            "label": "claude-1",             // provider_accounts.label (§3.1)
            "provider": "claude",            // Arbiter.Quota.provider_code/1 code
            "plan": null,                    // operator-stated: max_5x / pro / ...
            "max_concurrent": null,          // null = no account ceiling (§4.4)
            "quota_config": {},
            "credentials": [                 // provider_credentials rows (§3.2)
              {
                "fingerprint": "<sha256 hex>",
                "kind": "oauth_token",       // oauth_token | api_key | cli_credentials_file
                "env_var": "CLAUDE_CODE_OAUTH_TOKEN",
                "active": true,
                "suggested": false,
                "source": {
                  "type": "workspace_worker_env",
                  "workspaces": ["default", "emricare"]
                }
              }
            ],
            "workspaces": [                  // workspace_provider_accounts rows (§3.3)
              {"id": "…", "name": "default", "env_key": "CLAUDE_CODE_OAUTH_TOKEN", "share": null}
            ]
          }
        ],
        "unmoved_keys": [
          {"workspace_id": "…", "workspace": "default", "keys": ["LOG_LEVEL"]}
        ],
        "suggestions": [ /* credential rows with no candidate account to attach to */ ],
        "notes": ["human-readable caveats"]
      }

  ### What the plan deliberately does not contain

  **No secret value, in any field.** A credential row carries only its
  fingerprint and the `env_var` it lives under. The migrate step is expected to
  re-read the secret from that workspace's `worker_env` by `env_var` and refuse
  to proceed unless it hashes to the recorded `fingerprint` — so the plan is a
  set of *instructions*, not a copy of the material. That is what lets the plan
  be a plain file on disk, and it is why `"applied": false` is stamped on it:
  the file is inert until an operator runs migrate against it.

  ## Editing the plan

  The operator is expected to: rename `slug` / `label`; **merge candidates they
  know to be one plan** (move the credential rows and workspace rows under one
  account and delete the empty one); set `plan` and, if they want an account
  ceiling, `max_concurrent`; and accept or delete any `"suggested": true`
  credential row.
  """

  require Logger

  alias Arbiter.Tasks.Workspace

  @plan_version 1
  @plan_kind "arbiter.accounts.plan"

  @default_operator_credential_path "~/.claude/.credentials.json"

  # §7.3. Providers are the codes `Arbiter.Quota.provider_code/1` speaks, so a
  # plan row can be joined straight onto the existing quota tables (§6).
  #
  # `ANTIGRAVITY_API_KEY` is a placeholder: Antigravity currently stores no
  # token Arbiter can read at all (bd-d7hmqn, `Arbiter.Quota.CloudCode`), so on
  # this install it never matches. It is listed so the allowlist is complete
  # against §7.3 rather than silently Anthropic-shaped.
  @credential_keys %{
    "CLAUDE_CODE_OAUTH_TOKEN" => %{provider: "claude", kind: :oauth_token},
    "ANTHROPIC_AUTH_TOKEN" => %{provider: "claude", kind: :oauth_token},
    "ANTHROPIC_API_KEY" => %{provider: "claude", kind: :api_key},
    "OPENAI_API_KEY" => %{provider: "codex", kind: :api_key},
    "CODEX_API_KEY" => %{provider: "codex", kind: :api_key},
    "GEMINI_API_KEY" => %{provider: "gemini", kind: :api_key},
    "GOOGLE_GENAI_API_KEY" => %{provider: "gemini", kind: :api_key},
    "ANTIGRAVITY_API_KEY" => %{provider: "antigravity", kind: :api_key}
  }

  # An unmoved key of this shape is a numbered variant of an allowlisted key —
  # worth telling the operator about, not worth guessing at.
  @pool_variant_re ~r/^(?<base>[A-Z0-9_]+?)_\d+$/

  @typedoc "A workspace reduced to what the census reads: identity plus its decrypted env."
  @type source_workspace :: %{id: String.t(), name: String.t(), env: %{String.t() => String.t()}}

  @doc """
  The provider-credential key allowlist (§7.3), as
  `%{env_var => %{provider: String.t(), kind: atom()}}`.
  """
  @spec credential_keys() :: %{String.t() => %{provider: String.t(), kind: atom()}}
  def credential_keys, do: @credential_keys

  @doc "The default path the operator's Claude CLI credentials live at."
  @spec default_operator_credential_path() :: String.t()
  def default_operator_credential_path, do: @default_operator_credential_path

  @doc """
  Lowercase hex sha256 of `secret` — the `provider_credentials.fingerprint`
  shape from §3.2, and the grouping key from §7.2.

  Evidence only. Equality proves sameness; inequality proves nothing (§2.2).
  """
  @spec fingerprint(String.t()) :: String.t()
  def fingerprint(secret) when is_binary(secret),
    do: Base.encode16(:crypto.hash(:sha256, secret), case: :lower)

  @doc "The display form of a fingerprint: the first 12 hex characters."
  @spec short_fingerprint(String.t()) :: String.t()
  def short_fingerprint(fingerprint) when is_binary(fingerprint),
    do: String.slice(fingerprint, 0, 12)

  @doc """
  Reads every workspace and decrypts its `worker_env` in memory.

  This is the only function here that touches the database, and it only reads.
  Returns the `t:source_workspace/0` list `build/2` consumes, sorted by name.
  """
  @spec collect() :: [source_workspace()]
  def collect do
    Workspace
    |> Ash.read!()
    |> Enum.map(fn workspace ->
      %{id: workspace.id, name: workspace.name, env: Workspace.worker_env_map(workspace)}
    end)
    |> Enum.sort_by(& &1.name)
  end

  @doc """
  Builds the census from already-decrypted workspaces.

  Pure: no database, no filesystem, no clock beyond `generated_at`.

  ## Options

    * `:operator_credential` — `%{fingerprint: String.t(), path: String.t()}`,
      the §7.2 suggestion. Only ever a fingerprint; the caller
      (`operator_credential/1`) is responsible for never letting the secret out
      of its own stack frame.
    * `:operator_credential_error` — a reason string when the file could not be
      read, recorded as a note instead of a failure.
  """
  @spec build([source_workspace()], keyword()) :: map()
  def build(workspaces, opts \\ []) do
    workspaces =
      workspaces
      |> Enum.sort_by(& &1.name)
      |> Enum.map(&partition/1)

    accounts = group_accounts(workspaces)
    operator = Keyword.get(opts, :operator_credential)

    {accounts, suggestions, suggestion_notes} = offer_operator_credential(accounts, operator)

    notes =
      suggestion_notes ++
        operator_error_note(Keyword.get(opts, :operator_credential_error)) ++
        pool_variant_notes(workspaces) ++
        conflict_notes(accounts)

    %{
      generated_at: DateTime.truncate(DateTime.utc_now(), :second),
      workspaces: workspaces,
      accounts: accounts,
      suggestions: suggestions,
      notes: notes,
      totals: totals(workspaces, accounts)
    }
  end

  @doc """
  Convenience wrapper: `collect/0` then `build/2`.
  """
  @spec run(keyword()) :: map()
  def run(opts \\ []), do: collect() |> build(opts)

  # ---------------------------------------------------------------- partition

  defp partition(%{id: id, name: name, env: env}) do
    {credential_entries, other_entries} =
      env
      |> Enum.split_with(fn {key, _value} -> Map.has_key?(@credential_keys, key) end)

    credentials =
      credential_entries
      |> Enum.map(fn {key, value} ->
        %{provider: provider, kind: kind} = Map.fetch!(@credential_keys, key)

        %{
          env_key: key,
          provider: provider,
          kind: kind,
          fingerprint: fingerprint(value)
        }
      end)
      |> Enum.sort_by(& &1.env_key)

    other_keys = other_entries |> Enum.map(&elem(&1, 0)) |> Enum.sort()

    %{
      id: id,
      name: name,
      credentials: credentials,
      other_keys: other_keys,
      credential_count: length(credentials),
      other_count: length(other_keys)
    }
  end

  # ------------------------------------------------------------------ grouping

  # §7.2: one candidate account per distinct `(provider, sha256(secret))`,
  # defaulted to `<provider>-<n>`. Numbering follows first appearance walking
  # workspaces by name, so a re-run over unchanged data produces an identical
  # plan (an operator diffing two censuses is the point).
  defp group_accounts(workspaces) do
    pairs =
      for workspace <- workspaces,
          credential <- workspace.credentials,
          do: {credential, workspace}

    pairs
    |> Enum.map(fn {credential, _} -> {credential.provider, credential.fingerprint} end)
    |> Enum.uniq()
    |> Enum.map_reduce(%{}, fn {provider, fingerprint}, counters ->
      n = Map.get(counters, provider, 0) + 1
      {{provider, fingerprint, n}, Map.put(counters, provider, n)}
    end)
    |> elem(0)
    |> Enum.map(fn {provider, fingerprint, n} ->
      members =
        Enum.filter(pairs, fn {c, _} ->
          c.provider == provider and c.fingerprint == fingerprint
        end)

      slug = "#{provider}-#{n}"

      %{
        slug: slug,
        label: slug,
        provider: provider,
        index: n,
        credentials: account_credentials(members, fingerprint),
        workspaces: account_workspaces(members)
      }
    end)
    |> Enum.sort_by(&{&1.provider, &1.index})
  end

  # One account is one fingerprint, but that one secret can be configured under
  # more than one env var name across workspaces (e.g. `CLAUDE_CODE_OAUTH_TOKEN`
  # in one and `ANTHROPIC_AUTH_TOKEN` in another). Each distinct
  # `{env_var, kind}` gets its own `provider_credentials` row, since §3.2's
  # `env_var` is what `Dispatch` projects back into the spawn env.
  defp account_credentials(members, fingerprint) do
    members
    |> Enum.group_by(fn {c, _} -> {c.env_key, c.kind} end)
    |> Enum.map(fn {{env_var, kind}, group} ->
      %{
        fingerprint: fingerprint,
        kind: kind,
        env_var: env_var,
        active?: true,
        suggested?: false,
        source: %{
          type: :workspace_worker_env,
          workspaces: group |> Enum.map(fn {_, w} -> w.name end) |> Enum.uniq() |> Enum.sort()
        }
      }
    end)
    |> Enum.sort_by(& &1.env_var)
  end

  defp account_workspaces(members) do
    members
    |> Enum.map(fn {credential, workspace} ->
      %{id: workspace.id, name: workspace.name, env_key: credential.env_key, share: nil}
    end)
    |> Enum.uniq()
    |> Enum.sort_by(&{&1.name, &1.env_key})
  end

  # ------------------------------------------------- operator credential (§7.2)

  defp offer_operator_credential(accounts, nil) do
    {accounts, [],
     [
       "No operator credential was offered. Pass " <>
         "`--operator-credential #{@default_operator_credential_path}` to add that token as a " <>
         "second credential on the same Claude account (§7.2) — only its fingerprint is ever read."
     ]}
  end

  defp offer_operator_credential(accounts, %{fingerprint: fingerprint, path: path}) do
    credential = %{
      fingerprint: fingerprint,
      kind: :cli_credentials_file,
      env_var: "CLAUDE_CODE_OAUTH_TOKEN",
      active?: true,
      suggested?: true,
      source: %{
        type: :operator_credentials_file,
        path: path,
        json_path: "claudeAiOauth.accessToken"
      }
    }

    claude_accounts = Enum.filter(accounts, &(&1.provider == "claude"))

    cond do
      Enum.any?(claude_accounts, fn account ->
        Enum.any?(account.credentials, &(&1.fingerprint == fingerprint))
      end) ->
        {accounts, [],
         [
           "The operator credential at #{path} is already present as a workspace credential " <>
             "(identical fingerprint #{short_fingerprint(fingerprint)}); nothing to suggest."
         ]}

      match?([_single], claude_accounts) ->
        [%{slug: slug}] = claude_accounts

        accounts =
          Enum.map(accounts, fn
            %{slug: ^slug} = account ->
              %{account | credentials: account.credentials ++ [credential]}

            account ->
              account
          end)

        {accounts, [],
         [
           "SUGGESTION (unconfirmed): the operator token at #{path} is proposed as a second " <>
             "credential on #{slug}, on the §2.1 finding that it is the same Anthropic plan. " <>
             "Delete that `\"suggested\": true` row from the plan if that is not true here."
         ]}

      true ->
        {accounts, [Map.put(credential, :provider, "claude")],
         [
           "SUGGESTION (unattached): the operator token at #{path} has no single Claude candidate " <>
             "to attach to (#{length(claude_accounts)} found). It is listed under `suggestions`; " <>
             "move it onto the right account by hand, or delete it."
         ]}
    end
  end

  defp operator_error_note(nil), do: []

  defp operator_error_note(reason) when is_binary(reason),
    do: ["Operator credential: could not read it (#{reason}). The census continued without it."]

  defp pool_variant_notes(workspaces) do
    variants =
      for workspace <- workspaces,
          key <- workspace.other_keys,
          captures = Regex.named_captures(@pool_variant_re, key),
          is_map(captures),
          Map.has_key?(@credential_keys, captures["base"]),
          do: key

    case Enum.uniq(variants) do
      [] ->
        []

      keys ->
        [
          "Numbered pool variants of allowlisted keys were found and deliberately NOT treated as " <>
            "credentials in P0: #{Enum.join(Enum.sort(keys), ", ")}. Decide by hand how they map " <>
            "onto accounts before migrating."
        ]
    end
  end

  # §3.3 makes `(workspace_id, provider)` unique, so a workspace holding two
  # different secrets for one provider cannot be applied as-is.
  defp conflict_notes(accounts) do
    conflicts =
      accounts
      |> Enum.flat_map(fn account ->
        Enum.map(account.workspaces, &{&1.name, account.provider, account.slug})
      end)
      |> Enum.group_by(fn {name, provider, _} -> {name, provider} end, &elem(&1, 2))
      |> Enum.filter(fn {_, slugs} -> length(Enum.uniq(slugs)) > 1 end)
      |> Enum.sort()

    for {{name, provider}, slugs} <- conflicts do
      "CONFLICT: workspace #{name} holds more than one distinct #{provider} credential " <>
        "(#{Enum.join(Enum.uniq(slugs), ", ")}). §3.3 allows one account per (workspace, provider), " <>
        "so merge those candidates — or drop one — before migrating."
    end
  end

  defp totals(workspaces, accounts) do
    %{
      workspaces: length(workspaces),
      credential_keys: workspaces |> Enum.map(& &1.credential_count) |> Enum.sum(),
      other_keys: workspaces |> Enum.map(& &1.other_count) |> Enum.sum(),
      accounts: length(accounts),
      distinct_fingerprints:
        workspaces
        |> Enum.flat_map(fn w -> Enum.map(w.credentials, & &1.fingerprint) end)
        |> Enum.uniq()
        |> length(),
      providers: accounts |> Enum.map(& &1.provider) |> Enum.uniq() |> length()
    }
  end

  # ------------------------------------------------------- operator credential

  @doc """
  Fingerprints the operator's Claude CLI token without letting its value escape
  this function.

  Reads `path`, pulls `claudeAiOauth.accessToken`, hashes it, and returns
  `{:ok, %{fingerprint: hex, path: path}}`. Every failure answers
  `{:error, reason}` where `reason` describes the *shape* of the problem and
  never quotes file content.
  """
  @spec operator_credential(String.t()) :: {:ok, map()} | {:error, String.t()}
  def operator_credential(path) when is_binary(path) do
    expanded = Path.expand(path)

    with {:ok, body} <- read_file(expanded),
         {:ok, json} <- decode_json(body),
         {:ok, token} <- fetch_access_token(json) do
      {:ok, %{fingerprint: fingerprint(token), path: path}}
    end
  end

  defp read_file(path) do
    case File.read(path) do
      {:ok, body} -> {:ok, body}
      {:error, reason} -> {:error, "#{path}: #{:file.format_error(reason)}"}
    end
  end

  # Only the error *kind* is reported: Jason's message can quote the offending
  # bytes, which in this file are a token.
  defp decode_json(body) do
    case Jason.decode(body) do
      {:ok, json} when is_map(json) -> {:ok, json}
      {:ok, _} -> {:error, "not a JSON object"}
      {:error, _} -> {:error, "not valid JSON"}
    end
  end

  defp fetch_access_token(%{"claudeAiOauth" => %{"accessToken" => token}})
       when is_binary(token) and token != "",
       do: {:ok, token}

  defp fetch_access_token(_), do: {:error, "no claudeAiOauth.accessToken"}

  # ---------------------------------------------------------------- plan file

  @doc """
  The JSON-encodable plan document. String keys throughout; see the moduledoc
  for the format and its contract.
  """
  @spec plan(map()) :: map()
  def plan(census) do
    %{
      "kind" => @plan_kind,
      "version" => @plan_version,
      "generated_at" => DateTime.to_iso8601(census.generated_at),
      "generated_by" => "mix arbiter.accounts.census",
      "applied" => false,
      "fingerprint" => %{
        "algorithm" => "sha256",
        "encoding" => "hex",
        "of" => "the raw secret value"
      },
      "accounts" => Enum.map(census.accounts, &plan_account/1),
      "unmoved_keys" => Enum.map(census.workspaces, &plan_unmoved/1) |> Enum.reject(&is_nil/1),
      "suggestions" => Enum.map(census.suggestions, &plan_suggestion/1),
      "notes" => census.notes
    }
  end

  defp plan_account(account) do
    %{
      "slug" => account.slug,
      "label" => account.label,
      "provider" => account.provider,
      "plan" => nil,
      "max_concurrent" => nil,
      "quota_config" => %{},
      "credentials" => Enum.map(account.credentials, &plan_credential/1),
      "workspaces" =>
        Enum.map(account.workspaces, fn workspace ->
          %{
            "id" => workspace.id,
            "name" => workspace.name,
            "env_key" => workspace.env_key,
            "share" => workspace.share
          }
        end)
    }
  end

  defp plan_credential(credential) do
    %{
      "fingerprint" => credential.fingerprint,
      "kind" => Atom.to_string(credential.kind),
      "env_var" => credential.env_var,
      "active" => credential.active?,
      "suggested" => credential.suggested?,
      "source" => plan_source(credential.source)
    }
  end

  defp plan_source(%{type: :workspace_worker_env} = source),
    do: %{"type" => "workspace_worker_env", "workspaces" => source.workspaces}

  defp plan_source(%{type: :operator_credentials_file} = source),
    do: %{
      "type" => "operator_credentials_file",
      "path" => source.path,
      "json_path" => source.json_path
    }

  defp plan_suggestion(suggestion) do
    suggestion
    |> plan_credential()
    |> Map.put("provider", suggestion.provider)
  end

  defp plan_unmoved(%{other_keys: []}), do: nil

  defp plan_unmoved(workspace),
    do: %{
      "workspace_id" => workspace.id,
      "workspace" => workspace.name,
      "keys" => workspace.other_keys
    }

  @doc """
  Writes the plan to `path` as pretty JSON, mode `0600`.

  Refuses to overwrite an existing file unless `force?` — the operator's edits
  to a previous plan are the whole value of the file.
  """
  @spec write_plan!(map(), String.t(), boolean()) :: :ok
  def write_plan!(census, path, force? \\ false) do
    if File.exists?(path) and not force? do
      raise File.Error,
        reason: :eexist,
        action: "write plan to",
        path: path
    end

    path |> Path.dirname() |> File.mkdir_p!()
    File.write!(path, Jason.encode!(plan(census), pretty: true) <> "\n")
    File.chmod!(path, 0o600)
    :ok
  end

  # ------------------------------------------------------------------- report

  @doc """
  The human-readable census an operator reads before editing the plan.

  Contains counts, workspace names, env var **names**, candidate slugs and
  truncated fingerprints. It contains no value, by construction: the only
  secret-derived string it can reach is a fingerprint.
  """
  @spec report(map()) :: String.t()
  def report(census) do
    [
      "Provider account census — read-only. No database writes; no values printed.",
      "",
      summary_line(census),
      "",
      "Workspaces",
      workspace_lines(census),
      "",
      accounts_heading(census),
      account_lines(census),
      suggestion_lines(census),
      notes_lines(census)
    ]
    |> List.flatten()
    |> Enum.join("\n")
  end

  defp summary_line(%{totals: t}) do
    "Scanned #{pluralize(t.workspaces, "workspace")}: " <>
      "#{pluralize(t.credential_keys, "provider-credential key")}, " <>
      "#{pluralize(t.other_keys, "other key")}, " <>
      "#{pluralize(t.distinct_fingerprints, "distinct fingerprint")}."
  end

  defp workspace_lines(%{workspaces: []}), do: ["  (none)"]

  defp workspace_lines(%{workspaces: workspaces, accounts: accounts}) do
    slugs = slug_index(accounts)
    width = workspaces |> Enum.map(&String.length(&1.name)) |> Enum.max(fn -> 0 end)

    Enum.flat_map(workspaces, fn workspace ->
      name = String.pad_trailing(workspace.name, width)

      credentials =
        case workspace.credentials do
          [] ->
            ["  #{name}  credentials (0): —"]

          list ->
            ["  #{name}  credentials (#{length(list)}):"] ++
              Enum.map(list, fn credential ->
                slug = Map.get(slugs, {credential.provider, credential.fingerprint}, "?")

                "  #{String.duplicate(" ", width)}    #{credential.env_key} " <>
                  "[#{credential.provider}/#{credential.kind}] " <>
                  "sha256:#{short_fingerprint(credential.fingerprint)} → #{slug}"
              end)
        end

      others =
        case workspace.other_keys do
          [] ->
            ["  #{String.duplicate(" ", width)}  other keys (0): —"]

          keys ->
            [
              "  #{String.duplicate(" ", width)}  other keys (#{length(keys)}): #{Enum.join(keys, ", ")}"
            ]
        end

      credentials ++ others
    end)
  end

  defp accounts_heading(%{totals: t}) do
    "Candidate accounts — #{pluralize(t.accounts, "candidate account")} across " <>
      "#{pluralize(t.providers, "provider")} (proposed, never applied — §7.2)"
  end

  defp account_lines(%{accounts: []}), do: ["  (none)"]

  defp account_lines(%{accounts: accounts}) do
    Enum.flat_map(accounts, fn account ->
      ["  #{account.slug}  [#{account.provider}]"] ++
        Enum.map(account.credentials, fn credential ->
          flag = if credential.suggested?, do: "  ** suggested, unconfirmed **", else: ""

          "      credential sha256:#{short_fingerprint(credential.fingerprint)} " <>
            "as #{credential.env_var} (#{credential.kind})#{flag}"
        end) ++
        [
          "      workspaces (#{length(account.workspaces)}): " <>
            (account.workspaces |> Enum.map(& &1.name) |> Enum.join(", "))
        ]
    end)
  end

  defp suggestion_lines(%{suggestions: []}), do: []

  defp suggestion_lines(%{suggestions: suggestions}) do
    ["", "Unattached suggestions"] ++
      Enum.map(suggestions, fn suggestion ->
        "  [#{suggestion.provider}] sha256:#{short_fingerprint(suggestion.fingerprint)} " <>
          "as #{suggestion.env_var} (#{suggestion.kind})"
      end)
  end

  defp notes_lines(%{notes: []}), do: []

  defp notes_lines(%{notes: notes}) do
    ["", "Notes"] ++ Enum.map(notes, &"  - #{&1}")
  end

  defp slug_index(accounts) do
    Map.new(accounts, fn account ->
      {{account.provider, hd(account.credentials).fingerprint}, account.slug}
    end)
  end

  defp pluralize(1, noun), do: "1 #{noun}"
  defp pluralize(n, noun), do: "#{n} #{noun}s"
end
