defmodule Arbiter.Quota.Codex do
  @moduledoc """
  Direct Codex (OpenAI) quota tracking (bd-cqfn5i), modeled on 9router's
  `open-sse/services/usage/codex.js` (`getCodexUsage`).

  Arbiter has no passive quota signal for Codex the way it does for Claude (the
  Anthropic proxy scrapes rate-limit headers off worker traffic). Instead this
  module makes **one direct GET** to OpenAI's usage endpoint using the OAuth
  token the real `codex` CLI already keeps fresh in `~/.codex/auth.json`, and
  upserts the result into `Arbiter.Quota.CodexQuota`.

  ## Credentials — read-only

  We read `tokens.access_token` (sent as `Authorization: Bearer …`) and
  `tokens.account_id` (sent as the `ChatGPT-Account-ID` header) from
  `~/.codex/auth.json`. **We never write to that file.** No refresh logic lives
  here: the `codex` CLI refreshes the token during normal worker dispatch. If
  the token is expired at read time the endpoint returns `401`, and we skip the
  cycle gracefully (no snapshot written) rather than trying to refresh it
  ourselves — matching `Arbiter.Quota.RefreshProbe`'s degrade pattern.

  ## Response shape

  The endpoint returns a `rate_limit` object (also seen as `rate_limits` or
  `rate_limits_by_limit_id.codex`) with a `primary_window` (the **session**
  window) and a `secondary_window` (the **weekly** window). Each carries a
  used-percent (`used_percent` / `percent_used`) and a reset time
  (`reset_at` / `resets_at` / `resetAt`). `normalize/1` translates that into
  `CodexQuota` attrs; `serialize/1` renders the public
  `{used, total: 100, remaining, reset_at, unlimited: false}` window shape
  9router uses.

  ## Graceful no-op

  When Codex isn't authenticated for this machine (no readable auth file / no
  access token), `fetch/2` returns `%{codex: nil, message: …}` and makes **no**
  HTTP call, mirroring 9router's "Usage API not implemented for X" handling of
  unsupported providers.

  ## Configuration

  Via `config :arbiter, :codex_quota`:

    * `:auth_path` — override the `~/.codex/auth.json` location (tests).
    * `:usage_url` — override the usage endpoint URL.

  In test, `config :arbiter, :codex_quota_http_stub, true` routes the request
  through `Req.Test` stub `#{inspect(__MODULE__)}.HTTP`.
  """

  require Logger
  require Ash.Query

  alias Arbiter.Quota.CodexQuota

  @stub_name __MODULE__.HTTP
  @default_usage_url "https://chatgpt.com/backend-api/wham/usage"
  @default_auth_path "~/.codex/auth.json"
  @default_provider "codex"
  @request_timeout_ms 15_000

  @type window :: %{
          used: float(),
          total: 100,
          remaining: float(),
          reset_at: String.t() | nil,
          unlimited: false
        }

  @type result :: %{codex: map() | nil, message: String.t() | nil}

  # ---- fetch -------------------------------------------------------------

  @doc """
  Fetch Codex quota for `workspace_id` via a direct usage API call, upsert the
  snapshot, and return the serialized windows.

  Never raises. Returns `%{codex: map() | nil, message: String.t() | nil}`:

    * creds absent → `%{codex: nil, message: "Codex CLI not authenticated…"}`,
      no HTTP call.
    * non-200 (e.g. expired-token `401`) → `%{codex: nil, message: "Codex
      connected. Usage API temporarily unavailable (401)."}`, no snapshot
      written.
    * `200` with no window data → `%{codex: nil, message: …}`.
    * `200` with windows → `%{codex: serialized, message: nil}` and a fresh
      `CodexQuota` row.

  Options:

    * `:credentials` — inject `%{access_token, account_id}`, bypassing the file.
    * `:auth_path`   — override the auth file path.
    * `:usage_url`   — override the endpoint URL.
  """
  @spec fetch(String.t(), keyword()) :: result()
  def fetch(workspace_id, opts \\ []) when is_binary(workspace_id) do
    case resolve_credentials(opts) do
      {:ok, creds} ->
        fetch_with_credentials(workspace_id, creds, opts)

      {:error, _reason} ->
        %{codex: nil, message: "Codex CLI not authenticated for this workspace"}
    end
  rescue
    e ->
      Logger.debug("Arbiter.Quota.Codex.fetch raised: #{Exception.message(e)}")
      %{codex: nil, message: "Codex quota unavailable"}
  end

  defp fetch_with_credentials(workspace_id, creds, opts) do
    case request_usage(creds, opts) do
      {:ok, 200, body} ->
        handle_ok_body(workspace_id, body)

      {:ok, status, _body} ->
        %{
          codex: nil,
          message: "Codex connected. Usage API temporarily unavailable (#{status})."
        }

      {:error, reason} ->
        Logger.debug("Arbiter.Quota.Codex: usage request failed: #{inspect(reason)}")
        %{codex: nil, message: "Codex connected. Usage API unreachable."}
    end
  end

  defp handle_ok_body(workspace_id, body) do
    case normalize(body) do
      {:ok, attrs} ->
        case upsert(workspace_id, attrs) do
          {:ok, row} -> %{codex: serialize(row), message: nil}
          {:error, _} -> %{codex: nil, message: "Codex quota could not be stored"}
        end

      :noop ->
        %{codex: nil, message: "Codex connected. Usage API returned no rate-limit windows."}
    end
  end

  # ---- persistence -------------------------------------------------------

  defp upsert(workspace_id, attrs) do
    full =
      attrs
      |> Map.put(:workspace_id, workspace_id)
      |> Map.put(:provider, @default_provider)
      |> Map.put_new(:captured_at, DateTime.utc_now() |> DateTime.truncate(:second))

    result =
      CodexQuota
      |> Ash.Changeset.for_create(:upsert, full)
      |> Ash.create()

    with {:ok, row} <- result do
      broadcast(workspace_id, row)
    end

    result
  end

  # Broadcast the uniform `{:quota_updated, ws, view}` (not the raw resource
  # struct) so the LiveView `:quota` hook — which only handles that message —
  # picks up Codex live, exactly like the Anthropic and Google paths (bd-ajh7bd).
  defp broadcast(workspace_id, %CodexQuota{} = row) do
    Phoenix.PubSub.broadcast(
      Arbiter.PubSub,
      "quota:#{workspace_id}",
      {:quota_updated, workspace_id, view(row)}
    )
  rescue
    _ -> :error
  end

  @doc "Latest stored Codex snapshot for `workspace_id`, or `nil`."
  @spec latest(String.t(), String.t()) :: CodexQuota.t() | nil
  def latest(workspace_id, provider \\ @default_provider) when is_binary(workspace_id) do
    CodexQuota
    |> Ash.Query.filter(workspace_id == ^workspace_id and provider == ^provider)
    |> Ash.read_one()
    |> case do
      {:ok, %CodexQuota{} = row} -> row
      _ -> nil
    end
  rescue
    _ -> nil
  end

  # ---- normalize ---------------------------------------------------------

  @doc """
  Translate a decoded usage-endpoint body into `CodexQuota` upsert attrs.

  Returns `{:ok, attrs}` when at least one window (session/weekly) was found,
  or `:noop` when the body carries no rate-limit data. Mirrors the defensive
  multi-key parsing 9router's `getCodexUsage` / `formatCodexWindow` apply.
  """
  @spec normalize(map()) :: {:ok, map()} | :noop
  def normalize(body) when is_map(body) do
    rate_limit = rate_limit_body(body)
    session = window(rate_limit, ["primary_window", "primary"], body)
    weekly = window(rate_limit, ["secondary_window", "secondary"], body)

    if is_nil(session) and is_nil(weekly) do
      :noop
    else
      attrs =
        %{
          plan: plan(body),
          limit_reached: truthy(get_any(rate_limit, ["limit_reached"]))
        }
        |> put_window(:session_used_percent, :session_reset_at, session)
        |> put_window(:weekly_used_percent, :weekly_reset_at, weekly)

      {:ok, attrs}
    end
  end

  def normalize(_), do: :noop

  # The rate-limit object may live under a few keys; fall back to the body
  # itself so a flat `{primary_window, secondary_window}` shape still parses.
  defp rate_limit_body(body) do
    get_any(body, ["rate_limit", "rate_limits"]) ||
      get_in(body, ["rate_limits_by_limit_id", "codex"]) ||
      body
  end

  # Look up a window under any of `keys` in the rate-limit object, else in the
  # top-level body (9router checks both).
  defp window(rate_limit, keys, body) do
    win = get_any(rate_limit, keys) || get_any(body, keys)
    if is_map(win), do: win, else: nil
  end

  defp put_window(attrs, _used_key, _reset_key, nil), do: attrs

  defp put_window(attrs, used_key, reset_key, win) do
    attrs
    |> Map.put(used_key, used_percent(win))
    |> Map.put(reset_key, reset_at(win))
  end

  defp used_percent(win) do
    raw = get_any(win, ["used_percent", "percent_used"])
    raw |> to_finite_number(0.0) |> clamp(0.0, 100.0)
  end

  defp reset_at(win) do
    win
    |> get_any(["reset_at", "resets_at", "resetAt"])
    |> parse_reset_time()
  end

  defp plan(body) do
    case get_any(body, ["plan_type"]) || get_in(body, ["summary", "plan"]) do
      p when is_binary(p) and p != "" -> p
      _ -> nil
    end
  end

  # ---- serialize ---------------------------------------------------------

  @doc """
  Render a stored `CodexQuota` row into the public map shape, with each window
  as `{used, total: 100, remaining, reset_at, unlimited: false}`.
  """
  @spec serialize(CodexQuota.t()) :: map()
  def serialize(%CodexQuota{} = row) do
    %{
      plan: row.plan,
      limit_reached: row.limit_reached,
      session: serialize_window(row.session_used_percent, row.session_reset_at),
      weekly: serialize_window(row.weekly_used_percent, row.weekly_reset_at),
      captured_at: iso(row.captured_at)
    }
  end

  @doc "Serialize the latest stored snapshot for `workspace_id`, or `nil`."
  @spec serialize_latest(String.t()) :: map() | nil
  def serialize_latest(workspace_id) do
    case latest(workspace_id) do
      nil -> nil
      %CodexQuota{} = row -> serialize(row)
    end
  end

  @doc """
  Map a stored `CodexQuota` row to the uniform two-window quota view shape the
  topbar / `/usage` page render (bd-ajh7bd). Codex's session window fills the
  primary ("5h") slot and the weekly window the secondary ("7d") slot; the used
  percents (0-100) are rescaled to the 0-1 fraction the view uses.
  """
  @spec view(CodexQuota.t()) :: map()
  def view(%CodexQuota{} = row) do
    Arbiter.Quota.blank_view(row.provider)
    |> Map.merge(%{
      workspace_id: row.workspace_id,
      utilization_5h: fraction(row.session_used_percent),
      reset_5h_at: row.session_reset_at,
      utilization_7d: fraction(row.weekly_used_percent),
      reset_7d_at: row.weekly_reset_at,
      captured_at: row.captured_at,
      plan: row.plan,
      primary_label: "session",
      secondary_label: "weekly"
    })
  end

  defp fraction(nil), do: nil
  defp fraction(pct) when is_number(pct), do: pct / 100.0

  defp serialize_window(nil, nil), do: nil

  defp serialize_window(used, reset_at) do
    used = to_finite_number(used, 0.0)

    %{
      used: used,
      total: 100,
      remaining: clamp(100.0 - used, 0.0, 100.0),
      reset_at: iso(reset_at),
      unlimited: false
    }
  end

  # ---- credentials -------------------------------------------------------

  @doc """
  Read `access_token` + `account_id` from a `codex` `auth.json`.

  Read-only. `{:ok, %{access_token, account_id}}` on success, `{:error, reason}`
  when the file is absent / unreadable / malformed / lacks an access token.
  """
  @spec read_credentials(keyword()) ::
          {:ok, %{access_token: String.t(), account_id: String.t() | nil}} | {:error, term()}
  def read_credentials(opts \\ []) do
    path = auth_path(opts)

    with {:ok, raw} <- File.read(path),
         {:ok, json} <- Jason.decode(raw),
         %{"tokens" => %{"access_token" => token}} when is_binary(token) and token != "" <- json do
      {:ok, %{access_token: token, account_id: get_in(json, ["tokens", "account_id"])}}
    else
      {:error, reason} -> {:error, reason}
      _ -> {:error, :no_access_token}
    end
  end

  defp resolve_credentials(opts) do
    case Keyword.get(opts, :credentials) do
      %{access_token: token} = creds when is_binary(token) and token != "" ->
        {:ok, creds}

      _ ->
        read_credentials(opts)
    end
  end

  defp auth_path(opts) do
    (Keyword.get(opts, :auth_path) || cfg(:auth_path, @default_auth_path))
    |> Path.expand()
  end

  # ---- HTTP --------------------------------------------------------------

  defp request_usage(creds, opts) do
    url = Keyword.get(opts, :usage_url) || cfg(:usage_url, @default_usage_url)

    headers =
      [
        {"authorization", "Bearer " <> creds.access_token},
        {"accept", "application/json"},
        {"originator", "codex_cli_rs"}
      ] ++ account_header(creds)

    req =
      Req.new(
        url: url,
        method: :get,
        headers: headers,
        receive_timeout: @request_timeout_ms
      )
      |> maybe_stub()

    case Req.request(req) do
      {:ok, %Req.Response{status: status, body: body}} -> {:ok, status, body}
      {:error, reason} -> {:error, reason}
    end
  end

  defp account_header(%{account_id: id}) when is_binary(id) and id != "",
    do: [{"chatgpt-account-id", id}]

  defp account_header(_), do: []

  defp maybe_stub(req) do
    if Application.get_env(:arbiter, :codex_quota_http_stub, false) do
      Req.merge(req, plug: {Req.Test, @stub_name})
    else
      req
    end
  end

  # ---- shared helpers ----------------------------------------------------

  defp get_any(nil, _keys), do: nil

  defp get_any(map, keys) when is_map(map) do
    Enum.find_value(keys, fn key ->
      case Map.get(map, key) do
        nil -> nil
        val -> val
      end
    end)
  end

  defp get_any(_, _), do: nil

  # Mirror of 9router's `toFiniteNumber`: coerce numbers and numeric strings,
  # else the fallback.
  defp to_finite_number(n, _fallback) when is_number(n), do: n * 1.0

  defp to_finite_number(s, fallback) when is_binary(s) do
    case Float.parse(String.trim(s)) do
      {f, _} -> f
      :error -> fallback
    end
  end

  defp to_finite_number(_, fallback), do: fallback

  defp clamp(n, lo, hi), do: n |> max(lo) |> min(hi)

  defp truthy(true), do: true
  defp truthy(_), do: false

  # Mirror of 9router's `parseResetTime`: unix seconds/millis (number or numeric
  # string) or an ISO-8601 string → a second-truncated `DateTime`.
  defp parse_reset_time(nil), do: nil

  defp parse_reset_time(n) when is_integer(n), do: from_epoch(n)

  defp parse_reset_time(n) when is_float(n), do: from_epoch(trunc(n))

  defp parse_reset_time(s) when is_binary(s) do
    case Integer.parse(String.trim(s)) do
      {secs, ""} ->
        from_epoch(secs)

      _ ->
        case DateTime.from_iso8601(s) do
          {:ok, dt, _} -> DateTime.truncate(dt, :second)
          _ -> nil
        end
    end
  end

  defp parse_reset_time(_), do: nil

  # < 1e12 → seconds, else milliseconds (9router's heuristic).
  defp from_epoch(n) when n < 1_000_000_000_000 do
    case DateTime.from_unix(n) do
      {:ok, dt} -> DateTime.truncate(dt, :second)
      _ -> nil
    end
  end

  defp from_epoch(n) do
    case DateTime.from_unix(n, :millisecond) do
      {:ok, dt} -> DateTime.truncate(dt, :second)
      _ -> nil
    end
  end

  defp iso(nil), do: nil
  defp iso(%DateTime{} = dt), do: DateTime.to_iso8601(dt)

  defp cfg(key, default) do
    case Application.get_env(:arbiter, :codex_quota, []) do
      kw when is_list(kw) -> Keyword.get(kw, key, default)
      _ -> default
    end
  end
end
