defmodule ArbiterWeb.QuotaFixtures do
  @moduledoc """
  Quota rows for the LiveView tests that render the top bar and `/usage` rate
  limits (bd-gukyy1).
  """

  alias Arbiter.Quota

  @doc "The `message` `CloudCode.antigravity/1` sets when `agy` isn't on PATH."
  def agy_missing_message,
    do:
      "Antigravity CLI (agy) is not installed on this host (or not on PATH); install it and " <>
        "run it once to authenticate before checking quota."

  @doc """
  Upserts an antigravity `GoogleQuota` row on `ws`'s antigravity account with
  bd-7mro0t's 4-bucket snapshot: Gemini Models 25% (5h) / 60% (weekly) used,
  Claude and GPT models 10% / 20% used.

  Options: `:gemini_5h_remaining` (default `75.0`), `:models` (replaces the
  whole list — `[]` for an unparseable snapshot), `:message`.
  """
  def antigravity_quota!(ws, opts \\ []) do
    {:ok, account_id} = Quota.ensure_account_id(ws.id, "antigravity")
    now = DateTime.utc_now() |> DateTime.truncate(:second)
    reset = fn secs -> now |> DateTime.add(secs) |> DateTime.to_iso8601() end

    models =
      Keyword.get_lazy(opts, :models, fn ->
        [
          bucket("gemini_models_5h", Keyword.get(opts, :gemini_5h_remaining, 75.0), reset.(3600)),
          bucket("gemini_models_weekly", 40.0, reset.(3 * 86_400)),
          bucket("claude_and_gpt_models_5h", 90.0, reset.(3600)),
          bucket("claude_and_gpt_models_weekly", 80.0, reset.(3 * 86_400))
        ]
      end)

    Quota.GoogleQuota
    |> Ash.Changeset.for_create(:upsert, %{
      provider_account_id: account_id,
      provider: "antigravity",
      plan: "Unknown",
      message: Keyword.get(opts, :message),
      used_percent: 60.0,
      reset_at: DateTime.add(now, 3600),
      snapshot: %{"provider" => "antigravity", "models" => models},
      captured_at: now
    })
    |> Ash.create!()
  end

  defp bucket(model_id, remaining, reset_at),
    do: %{"model_id" => model_id, "remaining_percentage" => remaining, "reset_at" => reset_at}
end
