defmodule Arbiter.Quota.Gate.Snapshot do
  @moduledoc """
  Provider-neutral view of a quota snapshot, for `Arbiter.Quota.Gate` (bd-2mpo3f).

  Each provider persists its quota state in its own table with its own field
  names — `AnthropicQuota` has `utilization_5h` / `status_5h` / `reset_5h_at`,
  `CodexQuota` has `session_used_percent` / `limit_reached` / `session_reset_at`,
  `GoogleQuota` has a single representative `used_percent` / `reset_at`. The gate
  needs the same three things from all of them, so `normalize/1` projects each
  row onto this struct and the gate reasons only about:

    * `utilization` — the primary window's usage as a `0.0..1.0` fraction
      (Codex/Google report 0–100 percents; those are rescaled here).
    * `status` — the provider's own verdict. `"allowed"` (or `nil`) means
      plan-allowed; anything else is past-plan and holds. Codex's
      `limit_reached: true` maps to `"limit_reached"`; Google reports no status.
    * `reset_at` / `captured_at` — the staleness inputs (`Gate.stale?/1`),
      alongside `capture_source`, which says which of the two Anthropic
      sources wrote them and therefore which staleness threshold applies
      (bd-b0zody). Codex / Google have a single source each, so it stays
      `nil` for them.
    * `secondary_utilization` / `secondary_status` / `secondary_reset_at` —
      the same three things for the provider's **long** window (Anthropic 7d,
      Codex weekly), named by `secondary_window_label`.

  ## Both windows are projected (bd-1tuxv8)

  This used to project only the primary window, collapsing `utilization_5h` /
  `status_5h` onto one pair and dropping `utilization_7d` / `status_7d` on the
  floor — so a workspace at `utilization_7d 0.76, status_7d allowed_warning`
  dispatched straight through on a 23% 5h window, and the fleet would only
  discover the weekly budget was gone when every worker started failing at once.
  Both windows are now carried, and `Arbiter.Quota.Gate.gating_window/2` decides
  which (if either) binds. Google's Cloud Code Assist API reports a single
  representative model window, so its secondary fields stay `nil`.

  `overage_status` is Anthropic-only (there is no paid-overage passthrough for
  Codex or Google); it stays `nil` for those providers, so `Gate.in_overage?/2`
  falls back to the past-plan `status` signal for them.

  `normalize/1` returns `nil` for `nil` and for anything it does not recognize —
  the gate's fail-open contract: an unknown or missing snapshot never blocks a
  dispatch.
  """

  alias Arbiter.Quota.AnthropicQuota
  alias Arbiter.Quota.CloudCode
  alias Arbiter.Quota.CodexQuota
  alias Arbiter.Quota.GoogleQuota

  # Antigravity's `/usage` groups slug to these prefixes (see
  # `Arbiter.Quota.CloudCode`'s `agy_bucket_id/2`): "Gemini Models" ->
  # "gemini_models", "Claude and GPT models" -> "claude_and_gpt_models", each
  # combined with a `_5h` / `_weekly` window suffix into the model id
  # persisted in `GoogleQuota.snapshot["models"]`.
  @antigravity_gemini_group "gemini_models"
  @antigravity_claude_gpt_group "claude_and_gpt_models"

  @type t :: %__MODULE__{
          provider: String.t() | nil,
          utilization: float() | nil,
          status: String.t() | nil,
          reset_at: DateTime.t() | nil,
          captured_at: DateTime.t() | nil,
          capture_source: String.t() | nil,
          overage_status: String.t() | nil,
          window_label: String.t(),
          secondary_utilization: float() | nil,
          secondary_status: String.t() | nil,
          secondary_reset_at: DateTime.t() | nil,
          secondary_window_label: String.t() | nil
        }

  defstruct provider: nil,
            utilization: nil,
            status: nil,
            reset_at: nil,
            captured_at: nil,
            capture_source: nil,
            overage_status: nil,
            window_label: "primary",
            secondary_utilization: nil,
            secondary_status: nil,
            secondary_reset_at: nil,
            secondary_window_label: nil

  @doc """
  Project a persisted quota row onto the provider-neutral gate shape.

  Accepts `AnthropicQuota` / `CodexQuota` / `GoogleQuota` rows, an already
  normalized `#{inspect(__MODULE__)}`, or `nil`. Anything else → `nil`
  (fail open).

  `opts[:model]` is consulted only for an `"antigravity"` `GoogleQuota` row
  (bd-7qj58o AC4): it picks which of the four Antigravity sub-buckets
  ("Gemini Models" / "Claude and GPT models", each with a `5h` and a
  `weekly` window) the primary/secondary windows are read from — a
  `claude-*` / `gpt-*` model routes to "Claude and GPT models", a
  recognized Gemini model to "Gemini Models". Anything else (including
  `nil`, unresolved) doesn't match either group's exact-id lookup, so it
  falls through to the worst-of-both-groups reading — the conservative
  default when the model can't be identified. See `antigravity_windows/2`.
  """
  @spec normalize(term(), keyword()) :: t() | nil
  def normalize(quota, opts \\ [])

  def normalize(nil, _opts), do: nil

  def normalize(%__MODULE__{} = snapshot, _opts), do: snapshot

  def normalize(%GoogleQuota{provider: "antigravity"} = q, opts) do
    case antigravity_windows(q, Keyword.get(opts, :model)) do
      {primary, secondary} ->
        %__MODULE__{
          provider: q.provider,
          utilization: primary.utilization,
          status: nil,
          reset_at: primary.reset_at,
          captured_at: q.captured_at,
          window_label: "5h",
          secondary_utilization: secondary.utilization,
          secondary_status: nil,
          secondary_reset_at: secondary.reset_at,
          secondary_window_label: "weekly"
        }

      nil ->
        normalize_google(q)
    end
  end

  def normalize(%GoogleQuota{} = q, _opts), do: normalize_google(q)

  def normalize(%AnthropicQuota{} = q, _opts) do
    %__MODULE__{
      provider: q.provider,
      utilization: q.utilization_5h,
      status: q.status_5h,
      reset_at: q.reset_5h_at,
      captured_at: q.captured_at,
      capture_source: q.capture_source,
      overage_status: q.overage_status,
      window_label: "5h",
      secondary_utilization: q.utilization_7d,
      secondary_status: q.status_7d,
      secondary_reset_at: q.reset_7d_at,
      secondary_window_label: "7d"
    }
  end

  def normalize(%CodexQuota{} = q, _opts) do
    %__MODULE__{
      provider: q.provider,
      utilization: fraction(q.session_used_percent),
      status: if(q.limit_reached == true, do: "limit_reached"),
      reset_at: q.session_reset_at,
      captured_at: q.captured_at,
      window_label: "session",
      secondary_utilization: fraction(q.weekly_used_percent),
      # Codex reports one `limit_reached` flag for the account, not per window;
      # it is already carried on the primary window, so the weekly window gates
      # on utilization alone.
      secondary_status: nil,
      secondary_reset_at: q.weekly_reset_at,
      secondary_window_label: "weekly"
    }
  end

  def normalize(_other, _opts), do: nil

  # The pre-bd-7qj58o representative-used-percent projection: a single
  # collapsed "worst of everything" figure with no secondary window. Still
  # used for `"gemini_cli"` rows (Gemini CLI reports one representative
  # model, no explicit windows) and as the fallback for an `"antigravity"`
  # row whose stored snapshot carries no parseable per-bucket models (stale
  # schema, transient fetch error preserved via `preserve_last_good/3`, etc).
  defp normalize_google(%GoogleQuota{} = q) do
    %__MODULE__{
      provider: q.provider,
      utilization: fraction(q.used_percent),
      # Google's Cloud Code Assist API reports no allowed/rejected verdict — the
      # representative used-percent is the only gating signal.
      status: nil,
      reset_at: q.reset_at,
      captured_at: q.captured_at,
      window_label: "used"
    }
  end

  # Resolve the Antigravity 5h + weekly readings to gate on, from the
  # per-bucket `models` list persisted in `GoogleQuota.snapshot` (bd-7qj58o
  # AC3/AC4). Returns `{primary, secondary}` — each `%{utilization:, reset_at:}`
  # — or `nil` when the snapshot carries no matching buckets (falls back to
  # `normalize_google/1`'s single collapsed figure).
  #
  # `model` picks the sub-bucket group: `claude-*` / `gpt-*` gates on "Claude
  # and GPT models" (AC4), anything else (a `gemini-*` model, or `nil` when
  # the caller doesn't know the model yet) gates on "Gemini Models" — the
  # worst reading across *both* groups for that window when the group-exact
  # bucket isn't found, so an unclassified dispatch still holds rather than
  # silently reading an empty/headroom bucket.
  defp antigravity_windows(%GoogleQuota{snapshot: snapshot}, model) do
    models = models_from(snapshot)
    group = bucket_group(model)

    with [_ | _] <- models,
         %{} = primary <- bucket_reading(models, group, "5h"),
         %{} = secondary <- bucket_reading(models, group, "weekly") do
      {primary, secondary}
    else
      _ -> nil
    end
  end

  defp bucket_group(model) when is_binary(model) do
    if String.starts_with?(model, "claude-") or String.starts_with?(model, "gpt-") do
      @antigravity_claude_gpt_group
    else
      @antigravity_gemini_group
    end
  end

  defp bucket_group(_model), do: nil

  # Delegates the exact {group, window} match to the shared reader
  # (`CloudCode.antigravity_bucket/3`, also used by `CloudCode.view/1`), then
  # falls back to the worst reading across both groups for that window — via
  # the same shared per-bucket formula (`CloudCode.antigravity_bucket_reading/1`)
  # — when no group is known or no exact bucket exists.
  defp bucket_reading(models, group, window) do
    case CloudCode.antigravity_bucket(models, group, window) do
      %{} = found -> found
      nil -> models |> window_candidates(window) |> CloudCode.antigravity_bucket_reading()
    end
  end

  defp window_candidates(models, window) do
    Enum.filter(models, fn m ->
      case Map.get(m, "model_id") do
        id when is_binary(id) -> String.ends_with?(id, "_#{window}")
        _ -> false
      end
    end)
  end

  defp models_from(%{"models" => models}) when is_list(models), do: models
  defp models_from(_), do: []

  # Codex and Google report 0-100 used-percents; the gate threshold is a 0-1
  # fraction (Anthropic's native unit).
  defp fraction(nil), do: nil
  defp fraction(pct) when is_number(pct), do: pct / 100.0
  defp fraction(_), do: nil
end
