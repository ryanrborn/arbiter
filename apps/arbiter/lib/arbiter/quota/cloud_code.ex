defmodule Arbiter.Quota.CloudCode do
  @moduledoc """
  On-demand quota snapshots for the Google Cloud Code Assist family:
  **Gemini CLI** and **Antigravity** (bd-57ukgb, part of bd-5qe3qs).

  Unlike the Anthropic quota — which the local proxy captures passively from
  response headers (`Arbiter.Quota.AnthropicQuota`) — neither Gemini CLI nor
  Antigravity emits usage on ordinary traffic. We query it directly, modeled on
  9router's `open-sse/services/usage/google.js`, using the same Cloud Code Assist
  endpoints the real `gemini /stats` command hits.

  ## Credentials (read-only)

  The Gemini CLI stores its OAuth token at `~/.gemini/oauth_creds.json`
  (`access_token`).

  ### Antigravity: no stored token at all (bd-d7hmqn)

  Antigravity used to follow the same read-a-stored-token-and-call-the-API
  shape as Gemini CLI above (bd-4ku4ze): read the IDE's `state.vscdb`
  sqlite DB, fall back to the Gemini CLI creds file, and if neither yielded a
  token, shell out to `agy models` as a pure liveness check so a stale local
  copy could at least be distinguished from a logged-out account. In practice
  that stack of fallbacks degraded to a message telling the *operator* to go
  refresh the token by hand — not useful when nothing was actually wrong with
  the account, just with Arbiter's own copy of its token.

  `agy` (Antigravity's own CLI, `~/.local/bin/agy`) can report the real
  quota directly — `agy --output-format json --print "/usage"` — using
  whatever credential it holds in its own keyring/ADC/WIF chain, without us
  ever reading or holding a token ourselves. So Antigravity now shells out to
  that command instead of making an HTTP call with a stored token: see
  `antigravity/1` below. This removes the token-reading paths above entirely
  (no `state.vscdb`, no Gemini CLI fallback, no liveness-only probe) — there
  is nothing left in Arbiter's control to go stale.

  ### Gemini CLI keyring review (bd-4ku4ze)

  Reviewed whether the Gemini CLI (`@google/gemini-cli`, an npm/Node package)
  has an equivalent keyring/ADC source hiding behind its `oauth_creds.json` —
  it **does**: the installed bundle declares `@github/keytar` as a direct
  dependency (`package.json`) and ships a keychain-backed
  `code_assist/oauth-credential-storage.ts` `OAuthCredentialStorage`
  (service `gemini-cli-oauth`, via `HybridTokenStorage`), plus a
  `GOOGLE_APPLICATION_CREDENTIALS` ADC load path — both bypass
  `oauth_creds.json` entirely. Which path is authoritative is gated by the
  `GEMINI_FORCE_ENCRYPTED_FILE_STORAGE` env var: unset (the default), the CLI
  reads/writes `oauth_creds.json` as Arbiter assumes; set to `"true"`, the
  CLI never touches that file and Arbiter's read here goes stale exactly like
  the original Antigravity bug this task fixes. We do not probe the keyring
  or ADC for Gemini CLI (no equivalent of `agy`'s own liveness-probe CLI
  exists to shell out to), so a host running with that flag set will degrade
  with `project id not available` even though Gemini CLI itself is live —
  a known blind spot, not a silent-wrong-answer one. Its degraded
  `project id not available` message (`project_missing_message/1`) is a
  separate failure mode — a valid token but no cached Cloud Code project —
  already distinct from an auth failure, so no probe is needed on that path.

  ## Flow — Gemini CLI

  1. Read `access_token` from the creds file. Missing/blank → `nil` (no-op).
  2. Resolve the Cloud Code project id. The CLI doesn't cache it locally, so we
     POST `loadCodeAssist` (which also returns `currentTier.name`, the plan).
     A caller may inject a known id via `opts[:project_id]` to skip this hop.
  3. POST `retrieveUserQuota` with `{project: id}` and normalize each model's
     `remainingFraction` into a `{used, total: 1000, ...}` shape.

  `gemini/1` returns either `nil` (not configured) or a serialized snapshot
  map — never raises.

  ## Flow — Antigravity (bd-d7hmqn)

  Shell out to `agy --output-format json --print "/usage"` (the `agy` CLI's
  own binary, resolved via `System.find_executable/1`) and parse
  `.command.data.groups[].buckets[]` — each bucket a `{window, remaining_fraction,
  reset_time}` triple, grouped by model family (`"Gemini Models"`, `"Claude and
  GPT models"` at last check; the CLI's JSON may add more). Each `{group,
  window}` pair is normalized into a `model_quota()` entry via the same
  `normalize_model/4` Gemini CLI uses, so the existing `arb quota` / REST / MCP
  rendering (which walks `snapshot.models`) needs no special-casing for the
  multi-group, multi-window shape — it just sees more "model" rows, one per
  group/window combination. `remaining_fraction` is already a *remaining*
  fraction (unlike the Anthropic/Codex snapshots, which store *utilization*),
  so no inversion is applied — setting `remaining_percentage: fraction * 100`
  directly.

  `antigravity/1` **always returns a snapshot, never `nil`** — the whole point
  of this CLI-only design is that `agy` alone can tell us whether the account
  is live, so every outcome (not installed, not authenticated, timed out,
  unparseable JSON, or a real reading) surfaces as a snapshot with either
  `models` or a plain-English `message`, never a silent omission. Never
  raises. See `run_agy_usage/1` for the subprocess mechanics and the
  process-hygiene notes carried over from the old liveness probe (backgrounded
  language-server, output-capture deadlock, hard subprocess timeout). No
  token material is ever logged — only the parsed `remaining_fraction` /
  `window` / `reset_time` fields are kept, and JSON decode failures log
  nothing about the raw body.

  Both `gemini/1` and `antigravity/1` return a map the `arb quota` /
  `quota_get` / `GET /api/quota` surface can render without special-casing
  errors.

  ## Persistence (bd-ajh7bd)

  `refresh/3` wraps a live fetch with an upsert into `Arbiter.Quota.GoogleQuota`
  and a `{:quota_updated, ws, view}` PubSub broadcast, so `Arbiter.Quota.CloudProbe`
  can keep the snapshot fresh on a timer and the web dashboard picks it up live —
  exactly like the Anthropic header-capture path. `latest/2` / `serialize_latest/2`
  read the persisted row back so the REST + MCP quota surface never fetches live
  at request time.
  """

  require Ash.Query
  require Logger

  alias Arbiter.Quota.GoogleQuota

  # ---- endpoints (verified against 9router registry/gemini-cli.js)
  @gemini_quota_url "https://cloudcode-pa.googleapis.com/v1internal:retrieveUserQuota"
  @gemini_load_url "https://cloudcode-pa.googleapis.com/v1internal:loadCodeAssist"

  @default_creds_path "~/.gemini/oauth_creds.json"

  # Normalized base — the provider only hands us a fraction, not raw units, so
  # we mirror 9router's arbitrary 1000-unit base for used/total. Percentage is
  # carried alongside for callers that prefer a plain 0–100 figure.
  @total 1000

  # loadCodeAssist metadata (9router CLIENT_METADATA): ideType ANTIGRAVITY=9,
  # pluginType GEMINI=2. Platform is a coarse enum; LINUX_AMD64=3 is a safe
  # default for the server host and is not load-bearing for quota reads.
  @client_metadata %{"ideType" => 9, "pluginType" => 2, "platform" => 3}

  # `agy --output-format json --print "/usage"` — reports real per-window
  # remaining quota directly from whatever credential `agy` itself holds
  # (bd-d7hmqn), replacing the old stored-token HTTP call entirely.
  @agy_usage_args ["--output-format", "json", "--print", "/usage"]
  @default_agy_usage_timeout_ms 8_000

  # Same rationale as the old liveness-probe cache this replaces: the `agy`
  # binary is large (~199 MB) and backgrounds its own language server, so
  # `CloudProbe`'s periodic fan-out across every workspace must not re-exec it
  # on every cycle. A short TTL keeps the data reasonably fresh while still
  # collapsing the near-simultaneous per-workspace calls within one probe
  # cycle into a single subprocess.
  @agy_usage_cache_key {__MODULE__, :agy_usage_cache}
  @agy_usage_cache_ttl_ms 60_000

  @type model_quota :: %{
          model_id: String.t(),
          used: non_neg_integer(),
          total: non_neg_integer(),
          remaining_percentage: float(),
          reset_at: String.t() | nil,
          unlimited: boolean()
        }

  @type snapshot :: %{
          provider: String.t(),
          plan: String.t(),
          models: [model_quota()],
          message: String.t() | nil,
          captured_at: String.t()
        }

  # ---- Gemini CLI --------------------------------------------------------

  @doc """
  Gemini CLI per-model quota snapshot, or `nil` when not configured.

  Options:
    * `:creds_path`   — override the oauth creds file (tests / non-default homes)
    * `:project_id`   — a known Cloud Code project id, skips `loadCodeAssist`
    * `:plug`         — a `Req.Test` plug for stubbing HTTP in tests
    * `:receive_timeout` — per-request timeout (default 8s)
  """
  @spec gemini(keyword()) :: snapshot() | nil
  def gemini(opts \\ []) do
    case load_access_token(opts) do
      {:ok, token} -> fetch_gemini(token, opts)
      :error -> nil
    end
  end

  defp fetch_gemini(token, opts) do
    {project_id, plan} = resolve_gemini_project(token, opts)

    if is_nil(project_id) do
      snapshot("gemini-cli", plan, [], project_missing_message("Gemini CLI"))
    else
      case post(@gemini_quota_url, bearer_headers(token), %{project: project_id}, opts) do
        {:ok, %Req.Response{status: status, body: body}} when status in 200..299 ->
          snapshot("gemini-cli", plan, gemini_models(body), nil)

        {:ok, %Req.Response{status: 401}} ->
          snapshot("gemini-cli", plan, [], "Gemini CLI quota auth expired; reconnect the CLI.")

        {:ok, %Req.Response{status: status}} ->
          snapshot("gemini-cli", plan, [], "Gemini CLI quota error (#{status}).")

        {:error, err} ->
          snapshot("gemini-cli", plan, [], "Gemini CLI quota error: #{transport_message(err)}")
      end
    end
  end

  defp resolve_gemini_project(token, opts) do
    case normalize_project_id(opts[:project_id]) do
      pid when is_binary(pid) ->
        {pid, "Free"}

      nil ->
        case post(@gemini_load_url, bearer_headers(token), %{metadata: @client_metadata}, opts) do
          {:ok, %Req.Response{status: status, body: body}} when status in 200..299 ->
            {normalize_project_id(body["cloudaicompanionProject"]), plan_name(body)}

          _ ->
            {nil, "Free"}
        end
    end
  end

  defp gemini_models(%{"buckets" => buckets}) when is_list(buckets) do
    for bucket <- buckets,
        is_binary(bucket["modelId"]),
        not is_nil(bucket["remainingFraction"]) do
      normalize_model(bucket["modelId"], bucket["remainingFraction"], bucket["resetTime"], nil)
    end
  end

  defp gemini_models(_), do: []

  # ---- Antigravity (bd-d7hmqn) -------------------------------------------

  @doc """
  Antigravity quota snapshot, sourced directly from
  `agy --output-format json --print "/usage"` — **never `nil`**, see the
  moduledoc's "Flow — Antigravity" section for why every outcome (not
  installed, not authenticated, timed out, malformed JSON, or a real reading)
  is a snapshot with either `models` or a `message`, never a silent omission.

  Options:

    * `:agy_cmd` — override the `agy` executable name/path (default `"agy"`, resolved via `System.find_executable/1`)
    * `:agy_usage_probe` — override the subprocess call with a 0-arity fun returning `{:ok, decoded_json} | {:error, reason}` (tests)
    * `:agy_probe_timeout` — max time to wait on the `agy` subprocess, ms (default 8000)
    * `:agy_usage_cache_ttl_ms` — override the memoization TTL (tests; default 60000)
  """
  @spec antigravity(keyword()) :: snapshot()
  def antigravity(opts \\ []) do
    case run_agy_usage(opts) do
      {:ok, body} ->
        case usage_models_from_agy(body) do
          [] -> snapshot("antigravity", "Unknown", [], agy_malformed_message())
          models -> snapshot("antigravity", "Unknown", models, nil)
        end

      {:error, :not_installed} ->
        snapshot("antigravity", "Unknown", [], agy_not_installed_message())

      {:error, :timeout} ->
        snapshot("antigravity", "Unknown", [], "Antigravity CLI (agy) did not respond in time.")

      {:error, {:exit, status}} ->
        snapshot(
          "antigravity",
          "Unknown",
          [],
          "Antigravity CLI (agy) is not authenticated (exit #{status}); run `agy` to sign in."
        )

      {:error, :malformed} ->
        snapshot("antigravity", "Unknown", [], agy_malformed_message())
    end
  rescue
    e ->
      Logger.debug("Arbiter.Quota.CloudCode.antigravity raised: #{Exception.message(e)}")
      snapshot("antigravity", "Unknown", [], "Antigravity quota unavailable")
  end

  defp agy_not_installed_message do
    "Antigravity CLI (agy) is not installed on this host (or not on PATH); install it and " <>
      "run it once to authenticate before checking quota."
  end

  defp agy_malformed_message do
    "Antigravity CLI (agy) returned unexpected data; its JSON output may have changed shape."
  end

  # `.command.data.groups[].buckets[]` — each bucket a `{window,
  # remaining_fraction, reset_time}` triple, grouped by model family (e.g.
  # "Gemini Models", "Claude and GPT models"). Flattened into one
  # `model_quota()` per {group, window} pair so the existing per-model
  # rendering needs no special-casing.
  defp usage_models_from_agy(%{"command" => %{"data" => %{"groups" => groups}}})
       when is_list(groups) do
    for group <- groups,
        is_map(group),
        is_binary(group["name"]),
        is_list(group["buckets"]),
        bucket <- group["buckets"],
        is_map(bucket),
        is_binary(bucket["window"]),
        not is_nil(bucket["remaining_fraction"]) do
      normalize_model(
        agy_bucket_id(group["name"], bucket["window"]),
        bucket["remaining_fraction"],
        bucket["reset_time"],
        "#{group["name"]} (#{bucket["window"]})"
      )
    end
  end

  defp usage_models_from_agy(_), do: []

  defp agy_bucket_id(group_name, window) do
    slug =
      group_name
      |> String.downcase()
      |> String.replace(~r/[^a-z0-9]+/, "_")
      |> String.trim("_")

    slug <> "_" <> window
  end

  # ---- persistence (bd-ajh7bd) -------------------------------------------

  # Persisted provider codes (match `ArbiterWeb.QuotaHelpers` labels), keyed by
  # the fetch atom passed to `refresh/3`.
  @provider_codes %{gemini: "gemini_cli", antigravity: "antigravity"}

  @doc """
  Fetch one Google provider's live quota and upsert it into `GoogleQuota`.

  `which` is `:gemini` or `:antigravity`. Returns the serialized snapshot map on
  a successful fetch (persisting a row + broadcasting `{:quota_updated, ws, view}`).

  For `:gemini`, `nil` means the CLI isn't configured on this host (no creds) —
  in which case **no row is written**, so a transient logout doesn't wipe the
  last good reading.

  For `:antigravity` (bd-d7hmqn), the fetch never returns `nil` — `agy` itself
  determines whether it's installed/authenticated, so every call writes a row.
  When that snapshot has no model data (agy missing / not authenticated /
  timed out / malformed output), the write preserves the previous row's
  `used_percent` / `reset_at` / `snapshot` figures rather than nulling them
  out, so a transient error updates the status `message` without wiping the
  last good quota reading. `opts` are forwarded to `gemini/1` / `antigravity/1`.
  """
  @spec refresh(String.t(), :gemini | :antigravity, keyword()) :: snapshot() | nil
  def refresh(workspace_id, which, opts \\ [])
      when is_binary(workspace_id) and which in [:gemini, :antigravity] do
    case fetch_snapshot(which, opts) do
      nil ->
        nil

      snapshot ->
        provider = Map.fetch!(@provider_codes, which)

        case upsert(workspace_id, provider, snapshot) do
          {:ok, row} ->
            broadcast(workspace_id, row)
            snapshot

          {:error, reason} ->
            Logger.debug("Arbiter.Quota.CloudCode: #{provider} upsert failed: #{inspect(reason)}")
            snapshot
        end
    end
  rescue
    e ->
      Logger.debug("Arbiter.Quota.CloudCode.refresh raised: #{Exception.message(e)}")
      nil
  end

  defp fetch_snapshot(:gemini, opts), do: gemini(opts)
  defp fetch_snapshot(:antigravity, opts), do: antigravity(opts)

  defp upsert(workspace_id, provider, snapshot) do
    {used_percent, reset_at, stored_snapshot} =
      case representative(snapshot) do
        {nil, nil} -> preserve_last_good(workspace_id, provider, snapshot)
        {used_percent, reset_at} -> {used_percent, reset_at, stringify(snapshot)}
      end

    attrs = %{
      workspace_id: workspace_id,
      provider: provider,
      plan: snapshot[:plan],
      message: snapshot[:message],
      used_percent: used_percent,
      reset_at: reset_at,
      snapshot: stored_snapshot,
      captured_at: DateTime.utc_now() |> DateTime.truncate(:second)
    }

    GoogleQuota
    |> Ash.Changeset.for_create(:upsert, attrs)
    |> Ash.create()
  end

  # A snapshot with no model data (a transient API error, or the "agy is live
  # but we hold no readable token" liveness-only status) must not clobber the
  # last good reading's figures — but its `message`/`plan`/`captured_at` must
  # still land in the stored `snapshot` column, since that's what
  # `serialize_latest/2` (and therefore `arb quota`/the MCP quota tool) reads
  # back verbatim. Falls back to writing the empty snapshot as-is when there
  # is no previous row to preserve.
  defp preserve_last_good(workspace_id, provider, snapshot) do
    case latest(workspace_id, provider) do
      %GoogleQuota{used_percent: used_percent, reset_at: reset_at, snapshot: prior}
      when not is_nil(prior) ->
        merged =
          Map.merge(
            prior,
            stringify(%{
              message: snapshot[:message],
              plan: snapshot[:plan],
              captured_at: snapshot[:captured_at]
            })
          )

        {used_percent, reset_at, merged}

      _ ->
        {nil, nil, stringify(snapshot)}
    end
  end

  # The representative bar figure: the worst (most-used) important model, i.e.
  # the smallest `remaining_percentage`. `{used_percent :: float | nil,
  # reset_at :: DateTime | nil}` — nil/nil when the snapshot carries no models.
  defp representative(%{models: [_ | _] = models}) do
    worst = Enum.min_by(models, & &1.remaining_percentage)
    used = Float.round(100.0 - (worst.remaining_percentage || 0.0), 2)
    {clamp(used, 0.0, 100.0), parse_datetime(worst[:reset_at])}
  end

  defp representative(_), do: {nil, nil}

  defp parse_datetime(nil), do: nil

  defp parse_datetime(iso) when is_binary(iso) do
    case DateTime.from_iso8601(iso) do
      {:ok, dt, _} -> DateTime.truncate(dt, :second)
      _ -> nil
    end
  end

  defp parse_datetime(_), do: nil

  defp clamp(n, lo, hi), do: n |> max(lo) |> min(hi)

  # JSON-normalize the snapshot to string keys so the read-back shape is stable
  # regardless of the `:map` data-layer's round-trip.
  defp stringify(term) do
    term |> Jason.encode!() |> Jason.decode!()
  end

  defp broadcast(workspace_id, %GoogleQuota{} = row) do
    Phoenix.PubSub.broadcast(
      Arbiter.PubSub,
      "quota:#{workspace_id}",
      {:quota_updated, workspace_id, view(row)}
    )
  rescue
    _ -> :error
  end

  @doc "Latest stored Google snapshot row for `workspace_id` + `provider`, or `nil`."
  @spec latest(String.t(), String.t()) :: GoogleQuota.t() | nil
  def latest(workspace_id, provider) when is_binary(workspace_id) and is_binary(provider) do
    GoogleQuota
    |> Ash.Query.filter(workspace_id == ^workspace_id and provider == ^provider)
    |> Ash.read_one()
    |> case do
      {:ok, %GoogleQuota{} = row} -> row
      _ -> nil
    end
  rescue
    _ -> nil
  end

  @doc "Serialize the latest stored snapshot for `workspace_id` + `provider`, or `nil`."
  @spec serialize_latest(String.t(), String.t()) :: map() | nil
  def serialize_latest(workspace_id, provider) do
    case latest(workspace_id, provider) do
      nil -> nil
      %GoogleQuota{snapshot: snapshot} -> snapshot
    end
  end

  @doc """
  Map a stored `GoogleQuota` row to the uniform two-window quota view shape the
  topbar / `/usage` page render. Gemini has no time windows, so the
  representative used-fraction fills the primary ("5h") slot and the secondary
  ("7d") slot is left empty. Antigravity does have explicit `5h`/`weekly`
  windows per group, but `representative/1` collapses them to a single worst
  bucket, so this "5h" slot may actually carry a weekly reset time; the UI
  doesn't mislabel this today because the 5h-specific helpers are gated to
  the `"claude"` provider and `secondary_label` stays `nil` here.
  """
  @spec view(GoogleQuota.t()) :: map()
  def view(%GoogleQuota{} = row) do
    Arbiter.Quota.blank_view(row.provider)
    |> Map.merge(%{
      workspace_id: row.workspace_id,
      utilization_5h: fraction(row.used_percent),
      reset_5h_at: row.reset_at,
      captured_at: row.captured_at,
      plan: row.plan,
      message: row.message,
      models: models_from(row.snapshot),
      primary_label: "used",
      secondary_label: nil
    })
  end

  defp fraction(nil), do: nil
  defp fraction(pct) when is_number(pct), do: pct / 100.0

  defp models_from(%{"models" => models}) when is_list(models), do: models
  defp models_from(_), do: []

  # ---- normalization -----------------------------------------------------

  defp normalize_model(model_id, fraction, reset, display_name) do
    frac = to_fraction(fraction)
    remaining = round(@total * frac)
    used = max(0, @total - remaining)

    base = %{
      model_id: model_id,
      used: used,
      total: @total,
      remaining_percentage: frac * 100,
      reset_at: parse_reset(reset),
      unlimited: false
    }

    if is_binary(display_name), do: Map.put(base, :display_name, display_name), else: base
  end

  defp snapshot(provider, plan, models, message) do
    %{
      provider: provider,
      plan: plan,
      models: models,
      message: message,
      captured_at: DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.to_iso8601()
    }
  end

  defp to_fraction(f) when is_number(f), do: f * 1.0

  defp to_fraction(f) when is_binary(f) do
    case Float.parse(f) do
      {v, _} -> v
      :error -> 0.0
    end
  end

  defp to_fraction(_), do: 0.0

  # Provider reset times arrive as unix seconds, unix millis, a numeric string,
  # or an ISO-8601 string. Normalize all to ISO-8601 (mirrors 9router's
  # parseResetTime); anything unparseable degrades to nil.
  defp parse_reset(nil), do: nil

  defp parse_reset(n) when is_integer(n) do
    ms = if n < 1_000_000_000_000, do: n * 1000, else: n

    case DateTime.from_unix(ms, :millisecond) do
      {:ok, dt} -> DateTime.to_iso8601(dt)
      _ -> nil
    end
  end

  defp parse_reset(v) when is_binary(v) do
    if Regex.match?(~r/^\d+$/, v) do
      parse_reset(String.to_integer(v))
    else
      case DateTime.from_iso8601(v) do
        {:ok, dt, _offset} -> DateTime.to_iso8601(dt)
        _ -> nil
      end
    end
  end

  defp parse_reset(_), do: nil

  defp plan_name(body, default \\ "Free")
  defp plan_name(%{"currentTier" => %{"name" => name}}, _default) when is_binary(name), do: name
  defp plan_name(_body, default), do: default

  defp normalize_project_id(project) when is_binary(project) do
    case String.trim(project) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp normalize_project_id(%{"id" => id}) when is_binary(id), do: normalize_project_id(id)
  defp normalize_project_id(_), do: nil

  defp project_missing_message(label) do
    "#{label} project id not available; reconnect the CLI or configure a Cloud " <>
      "project with Code Assist access before checking quota."
  end

  # ---- credentials (read-only) -------------------------------------------

  defp load_access_token(opts) do
    path =
      opts[:creds_path] ||
        Application.get_env(:arbiter, :gemini_creds_path) ||
        @default_creds_path

    with {:ok, raw} <- File.read(Path.expand(path)),
         {:ok, %{"access_token" => token}} <- Jason.decode(raw),
         true <- is_binary(token) and token != "" do
      {:ok, token}
    else
      _ -> :error
    end
  end

  # Run `agy --output-format json --print "/usage"` off-process — see
  # moduledoc's "Flow — Antigravity". `{:ok, decoded_json}` on a clean `0`
  # exit with parseable JSON, else `{:error, :not_installed | :timeout |
  # {:exit, status} | :malformed}`. Never raises. Injectable via
  # `opts[:agy_usage_probe]` (a 0-arity fun) so tests never shell out.
  defp run_agy_usage(opts) do
    case opts[:agy_usage_probe] do
      fun when is_function(fun, 0) -> fun.()
      _ -> agy_usage_default(opts)
    end
  end

  # Same memoization rationale as the liveness probe this replaces: `agy` is a
  # large binary that backgrounds its own language server, and `CloudProbe`
  # fans this call out across every workspace on each probe cycle. Cache the
  # outcome briefly so those near-simultaneous per-workspace calls collapse
  # into one subprocess, without holding stale quota figures too long.
  defp agy_usage_default(opts) do
    cmd = opts[:agy_cmd] || Application.get_env(:arbiter, :agy_cmd) || "agy"
    ttl = Keyword.get(opts, :agy_usage_cache_ttl_ms, @agy_usage_cache_ttl_ms)
    now = System.monotonic_time(:millisecond)

    case :persistent_term.get(@agy_usage_cache_key, nil) do
      {^cmd, result, cached_at} when now - cached_at < ttl ->
        result

      _ ->
        result =
          case System.find_executable(cmd) do
            nil -> {:error, :not_installed}
            path -> shell_out_agy_usage(path, opts)
          end

        :persistent_term.put(@agy_usage_cache_key, {cmd, result, now})
        result
    end
  rescue
    _ -> {:error, :not_installed}
  end

  # Run the subprocess with a hard timeout — a hung/prompting CLI must never
  # block `arb quota`. `Task.shutdown/2` on timeout only stops Erlang
  # *waiting* on the OS process, so we wrap the invocation in the `timeout`
  # coreutil to get an actual OS-side kill independent of whether Erlang is
  # still watching (mirrors the old liveness probe's `run_agy_probe/2`).
  #
  # `agy` backgrounds its own language-server process, which inherits whatever
  # file descriptor its stdout points at. Capturing output via a plain
  # `System.cmd/3` pipe would make Erlang's port driver block waiting for that
  # pipe's write end to close — the backgrounded grandchild keeps it open
  # indefinitely, so the port never sees EOF even though `agy` itself exits
  # immediately. Redirecting stdout to a real file at the shell level (not a
  # pipe `System.cmd` itself reads) sidesteps this entirely, so we can capture
  # the JSON body without hitting the deadlock the liveness probe worked
  # around by discarding output altogether.
  defp shell_out_agy_usage(path, opts) do
    timeout = Keyword.get(opts, :agy_probe_timeout, @default_agy_usage_timeout_ms)
    timeout_s = max(1, ceil(timeout / 1000))
    tmp = agy_usage_tmp_path()

    task =
      Task.async(fn ->
        try do
          System.cmd("/bin/sh", [
            "-c",
            ~s(exec timeout -k 1 #{timeout_s} "$0" #{Enum.join(@agy_usage_args, " ")} >"$1" 2>/dev/null </dev/null),
            path,
            tmp
          ])
        rescue
          _ -> {"", 1}
        catch
          :exit, _ -> {"", 1}
        end
      end)

    outcome =
      try do
        case Task.yield(task, timeout + 3_000) do
          {:ok, {_out, 0}} ->
            read_agy_usage_output(tmp)

          # `timeout -k 1` kills with SIGTERM at the deadline and SIGKILL a
          # second later; either way the shell reports 124/137 for a
          # subprocess that overran, not an auth failure. Without this clause
          # a merely-slow `agy` gets reported as "not authenticated".
          {:ok, {_out, status}} when status in [124, 137] ->
            {:error, :timeout}

          {:ok, {_out, status}} ->
            {:error, {:exit, status}}

          {:exit, _reason} ->
            {:error, :malformed}

          nil ->
            Task.shutdown(task, :brutal_kill)
            {:error, :timeout}
        end
      after
        File.rm_rf(agy_usage_tmp_dir(tmp))
      end

    outcome
  end

  # A private, unpredictably-named directory (not just a file) so the shell's
  # `>"$1"` redirect can't be steered onto an attacker-planted symlink in the
  # world-writable /tmp, and so `agy`'s raw JSON (whatever it may contain)
  # isn't world-readable for the subprocess's lifetime the way a bare 0644
  # temp file would be.
  defp agy_usage_tmp_path do
    dir =
      Path.join(
        System.tmp_dir!(),
        "arbiter-agy-#{Base.url_encode64(:crypto.strong_rand_bytes(12), padding: false)}"
      )

    File.mkdir!(dir)
    File.chmod!(dir, 0o700)
    Path.join(dir, "usage.json")
  end

  defp agy_usage_tmp_dir(tmp), do: Path.dirname(tmp)

  # No token material ever passes through here — only the decoded JSON body,
  # which callers parse down to `remaining_fraction` / `window` / `reset_time`.
  defp read_agy_usage_output(tmp) do
    with {:ok, raw} <- File.read(tmp),
         {:ok, decoded} <- Jason.decode(raw) do
      {:ok, decoded}
    else
      _ -> {:error, :malformed}
    end
  end

  # ---- HTTP --------------------------------------------------------------

  defp bearer_headers(token) do
    [
      {"authorization", "Bearer " <> token},
      {"content-type", "application/json"}
    ]
  end

  defp post(url, headers, body, opts) do
    full =
      [
        method: :post,
        url: url,
        headers: headers,
        json: body,
        receive_timeout: Keyword.get(opts, :receive_timeout, 8_000),
        retry: false
      ]
      |> Keyword.merge(stub_opts(opts))

    Req.request(full)
  end

  defp stub_opts(opts) do
    cond do
      Keyword.has_key?(opts, :plug) ->
        [plug: Keyword.fetch!(opts, :plug)]

      Application.get_env(:arbiter, :cloud_code_http_stub, false) ->
        [plug: {Req.Test, __MODULE__}]

      true ->
        []
    end
  end

  defp transport_message(%{reason: reason}), do: inspect(reason)
  defp transport_message(other), do: inspect(other)
end
