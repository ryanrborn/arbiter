defmodule ArbiterCli.Cmd.Account do
  @moduledoc """
  `arb account <verb>` — provider accounts (P11, `docs/provider-account-design.md`
  §2.5). An account is the identity a Claude/Codex/Gemini/Antigravity
  credential, quota snapshot and concurrency ceiling all hang off (§2.4) — it
  survives credential rotation because none of them ever point at the
  credential itself.

      arb account list                              [--provider claude|codex|gemini_cli|antigravity]
      arb account show   <ref>
                                     <ref> is a uuid, "provider:slug", or a
                                     bare slug (only unambiguous if no other
                                     provider shares it)
      arb account create <provider> <slug> [--label ...] [--plan ...]
                                     [--max-concurrent N]
                                     No credential is required at creation
                                     time (§2.4 — operator-asserted identity).
      arb account attach <workspace-id> <provider> <ref> [--share N]
                                     Points a workspace at an account for a
                                     provider — writes/updates the
                                     workspace_provider_accounts row.
      arb account rotate <ref> --kind oauth_token|api_key|cli_credentials_file
                                     --env-var VAR (--secret VALUE | --secret-file PATH | -)
                                     [--scopes a,b]
                                     Inserts a new active credential and
                                     retires the previous one of the same
                                     kind. A data operation, not automated
                                     rotation (§11) — the secret is never
                                     printed or logged, by this command or any
                                     other.
      arb account merge  <from-ref> --into <into-ref>
                                     Re-points usage_events, provider_credentials
                                     and workspace_provider_accounts from
                                     <from-ref> to <into-ref>, collapses the
                                     provider's quota snapshot, and soft-deletes
                                     <from-ref> (merged_into_id set). All-or-
                                     nothing (§2.5) — the operationally
                                     critical command in this design.

  All verbs go through the REST API at `/api/accounts`.
  """

  alias ArbiterCli.{Client, Output}

  @switches [
    provider: :string,
    label: :string,
    plan: :string,
    max_concurrent: :integer,
    share: :integer,
    kind: :string,
    env_var: :string,
    secret: :string,
    secret_file: :string,
    scopes: :string,
    into: :string,
    json: :boolean
  ]

  # credo:disable-for-next-line Credo.Check.Refactor.CyclomaticComplexity
  def run(argv) do
    if Output.help?(argv) do
      IO.puts(@moduledoc)
    else
      {opts, rest, _invalid} = OptionParser.parse(argv, switches: @switches)
      mode = if opts[:json], do: :json, else: :text

      case rest do
        ["list" | _] ->
          list(opts, mode)

        ["show" | args] ->
          show(args, mode)

        ["create" | args] ->
          create(args, opts, mode)

        ["attach" | args] ->
          attach(args, opts, mode)

        ["rotate" | args] ->
          rotate(args, opts, mode)

        ["merge" | args] ->
          merge(args, opts, mode)

        [] ->
          Output.die(
            "account requires a subcommand",
            "verbs: list, show, create, attach, rotate, merge"
          )

        [unknown | _] ->
          Output.die("unknown account subcommand: #{unknown}")
      end
    end
  end

  # ---- list ----------------------------------------------------------------

  defp list(opts, mode) do
    params = if opts[:provider], do: [provider: opts[:provider]], else: []

    case Client.get("/api/accounts", params) do
      {:ok, %{"data" => accounts}} -> emit_list(accounts, mode)
      {:error, err} -> Output.die(err)
    end
  end

  defp emit_list(accounts, :json), do: IO.puts(Jason.encode!(%{data: accounts}))
  defp emit_list([], :text), do: IO.puts("(no accounts)")

  defp emit_list(accounts, :text) do
    Enum.each(accounts, fn a ->
      ceiling = if a["max_concurrent"], do: " max_concurrent=#{a["max_concurrent"]}", else: ""
      state = if a["enabled"], do: "", else: "  [disabled]"
      merged = if a["merged_into_id"], do: "  [merged -> #{a["merged_into_id"]}]", else: ""
      IO.puts("#{a["provider"]}:#{a["slug"]}  (#{a["id"]})#{ceiling}#{state}#{merged}")
    end)
  end

  # ---- show ------------------------------------------------------------

  defp show(args, mode) do
    ref = one_ref!(args, "show")

    case Client.get("/api/accounts/" <> URI.encode(ref)) do
      {:ok, account} -> emit_show(account, mode)
      {:error, err} -> Output.die(err)
    end
  end

  defp emit_show(account, :json), do: IO.puts(Jason.encode!(account))

  defp emit_show(account, :text) do
    IO.puts("Provider:    #{account["provider"]}")
    IO.puts("Slug:        #{account["slug"]}")
    IO.puts("ID:          #{account["id"]}")
    IO.puts("Label:       #{account["label"] || "-"}")
    IO.puts("Plan:        #{account["plan"] || "-"}")
    IO.puts("Enabled:     #{account["enabled"]}")
    IO.puts("Max concurrent: #{account["max_concurrent"] || "(none)"}")

    if account["merged_into_id"] do
      IO.puts("Merged into: #{account["merged_into_id"]}")
    end

    IO.puts("")
    IO.puts("Credentials:")

    case account["credentials"] || [] do
      [] -> IO.puts("  (none)")
      creds -> Enum.each(creds, &emit_credential_line/1)
    end

    IO.puts("")
    IO.puts("Workspaces:")

    case account["workspaces"] || [] do
      [] -> IO.puts("  (none)")
      links -> Enum.each(links, &emit_link_line/1)
    end
  end

  defp emit_credential_line(c) do
    status = if c["active"], do: "active", else: "retired #{c["retired_at"]}"
    IO.puts("  #{c["kind"]} (#{c["env_var"]}) fingerprint=#{c["fingerprint"]}  #{status}")
  end

  defp emit_link_line(l) do
    share = if l["share"], do: " share=#{l["share"]}", else: ""
    IO.puts("  workspace #{l["workspace_id"]}#{share}")
  end

  # ---- create ------------------------------------------------------------

  defp create(args, opts, mode) do
    {provider, slug} = provider_and_ref!(args, "create")

    payload =
      %{"provider" => provider, "slug" => slug}
      |> maybe_put("label", opts[:label])
      |> maybe_put("plan", opts[:plan])
      |> maybe_put("max_concurrent", opts[:max_concurrent])

    case Client.post("/api/accounts", payload) do
      {:ok, account} -> emit_written(account, "created", mode)
      {:error, err} -> Output.die(err)
    end
  end

  # ---- attach ------------------------------------------------------------

  defp attach(args, opts, mode) do
    case args do
      [workspace_id, provider, ref | _] ->
        payload =
          %{"workspace_id" => workspace_id, "provider" => provider}
          |> maybe_put("share", opts[:share])

        case Client.post("/api/accounts/" <> URI.encode(ref) <> "/attach", payload) do
          {:ok, link} -> emit_attach(link, mode)
          {:error, err} -> Output.die(err)
        end

      _ ->
        Output.die("account attach requires <workspace-id> <provider> <ref>")
    end
  end

  defp emit_attach(link, :json), do: IO.puts(Jason.encode!(link))

  defp emit_attach(link, :text) do
    share = if link["share"], do: " share=#{link["share"]}", else: ""

    IO.puts(
      "attached workspace #{link["workspace_id"]} -> account #{link["provider_account_id"]}#{share}"
    )
  end

  # ---- rotate ------------------------------------------------------------

  defp rotate(args, opts, mode) do
    ref = one_ref!(args, "rotate")
    kind = opts[:kind] || Output.die("account rotate requires --kind")
    env_var = opts[:env_var] || Output.die("account rotate requires --env-var")
    secret = resolve_secret!(opts, args)

    payload =
      %{"kind" => kind, "env_var" => env_var, "secret" => secret}
      |> maybe_put("scopes", split_scopes(opts[:scopes]))

    case Client.post("/api/accounts/" <> URI.encode(ref) <> "/rotate", payload) do
      {:ok, credential} -> emit_rotated(credential, mode)
      {:error, err} -> Output.die(err)
    end
  end

  # Never prints the secret it just wrote — only shape/metadata a rotation
  # audit trail needs (P11 acceptance: never display or log the value).
  defp emit_rotated(credential, :json) do
    credential
    |> Map.drop(["secret"])
    |> Jason.encode!()
    |> IO.puts()
  end

  defp emit_rotated(credential, :text) do
    IO.puts("rotated #{credential["kind"]} credential (fingerprint=#{credential["fingerprint"]})")
  end

  defp resolve_secret!(opts, args) do
    cond do
      opts[:secret] && opts[:secret_file] ->
        Output.die("pass only one of --secret / --secret-file")

      is_binary(opts[:secret]) ->
        opts[:secret]

      is_binary(opts[:secret_file]) ->
        case File.read(opts[:secret_file]) do
          {:ok, contents} ->
            String.trim(contents)

          {:error, reason} ->
            Output.die("cannot read --secret-file: #{:file.format_error(reason)}")
        end

      "-" in args ->
        IO.read(:stdio, :eof) |> to_string() |> String.trim()

      true ->
        Output.die(
          "account rotate requires a secret: pass --secret, --secret-file <path>, or - (stdin)"
        )
    end
  end

  defp split_scopes(nil), do: nil
  defp split_scopes(str), do: str |> String.split(",") |> Enum.map(&String.trim/1)

  # ---- merge ------------------------------------------------------------

  defp merge(args, opts, mode) do
    from_ref = one_ref!(args, "merge")
    into_ref = opts[:into] || Output.die("account merge requires --into <ref>")

    case Client.post("/api/accounts/" <> URI.encode(from_ref) <> "/merge", %{"into" => into_ref}) do
      {:ok, account} -> emit_merged(account, mode)
      {:error, err} -> Output.die(err)
    end
  end

  defp emit_merged(account, :json), do: IO.puts(Jason.encode!(account))

  defp emit_merged(account, :text),
    do:
      IO.puts("merged into account #{account["provider"]}:#{account["slug"]} (#{account["id"]})")

  # ---- output ------------------------------------------------------------

  defp emit_written(account, _verb, :json), do: IO.puts(Jason.encode!(account))

  defp emit_written(account, verb, :text),
    do: IO.puts("#{verb} account #{account["provider"]}:#{account["slug"]} (#{account["id"]})")

  # ---- helpers -----------------------------------------------------------

  defp one_ref!(args, verb) do
    case Enum.reject(args, &(&1 == "-")) do
      [ref | _] -> ref
      [] -> Output.die("account #{verb} requires a ref (uuid, provider:slug, or slug)")
    end
  end

  defp provider_and_ref!(args, verb) do
    case args do
      [provider, slug | _] -> {provider, slug}
      _ -> Output.die("account #{verb} requires <provider> <slug>")
    end
  end

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)
end
