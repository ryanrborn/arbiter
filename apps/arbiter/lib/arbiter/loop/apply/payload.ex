defmodule Arbiter.Loop.Apply.Payload do
  @moduledoc """
  The apply pipeline's **validation step**: reading a proposal's `payload` map
  into the arguments a domain action needs, or saying precisely what is
  missing.

  Every function returns `{:ok, value}` or `{:error, {:unmapped, message}}`.
  `:unmapped` is the queue's word for "this proposal cannot be applied as
  written" — an operator-facing gap, not a failed write — so the messages here
  are written to be read in `arb loop apply` output.

  Split out of `Arbiter.Loop` (bd-3b7svv) so the shape of an applicable payload
  is pinned by unit tests rather than only by whichever end-to-end apply
  happens to exercise it.
  """

  @type result(t) :: {:ok, t} | {:error, {:unmapped, String.t()}}

  @doc "Fetch a non-empty string at `key`. `message` overrides the default gap text."
  @spec string(map(), String.t(), String.t() | nil) :: result(String.t())
  def string(payload, key, message \\ nil) do
    case Map.get(payload, key) do
      v when is_binary(v) and v != "" -> {:ok, v}
      _ -> {:error, {:unmapped, message || "payload is missing #{inspect(key)}"}}
    end
  end

  @doc "Fetch an integer at `key`, accepting a fully-parseable decimal string."
  @spec integer(map(), String.t()) :: result(integer())
  def integer(payload, key) do
    case Map.get(payload, key) do
      n when is_integer(n) ->
        {:ok, n}

      s when is_binary(s) ->
        case Integer.parse(s) do
          {n, ""} -> {:ok, n}
          _ -> {:error, {:unmapped, "payload #{inspect(key)} is not an integer"}}
        end

      _ ->
        {:error, {:unmapped, "payload is missing #{inspect(key)}"}}
    end
  end

  @doc "Fetch a non-empty map at `key` — an empty patch is a gap, not a no-op."
  @spec map(map(), String.t()) :: result(map())
  def map(payload, key) do
    case Map.get(payload, key) do
      %{} = m when map_size(m) > 0 -> {:ok, m}
      _ -> {:error, {:unmapped, "payload is missing a non-empty #{inspect(key)} map"}}
    end
  end

  @doc """
  The workspace a `:config_set` / `:repo_doc_patch` proposal targets: the
  payload's explicit `workspace_id`, else the row's own, else a gap.
  """
  @spec workspace_id(map(), String.t() | nil) :: result(String.t())
  def workspace_id(payload, fallback) do
    case Map.get(payload, "workspace_id") || fallback do
      id when is_binary(id) -> {:ok, id}
      _ -> {:error, {:unmapped, "this proposal names no workspace to configure"}}
    end
  end

  @doc """
  The `Arbiter.Skills.update_skill/3` attrs a `:skill_patch` payload carries.

  Only the keys actually present are included, so applying a patch never
  blanks a field the proposal said nothing about. A payload carrying none of
  them is a gap.
  """
  @spec skill_attrs(map()) :: result(map())
  def skill_attrs(payload) do
    attrs =
      %{}
      |> maybe_put(:body, Map.get(payload, "body"))
      |> maybe_put(:metadata, Map.get(payload, "metadata"))
      |> maybe_put(:activation_mode, Map.get(payload, "activation_mode"))

    if map_size(attrs) == 0 do
      {:error, {:unmapped, "this proposal carries no skill patch content to apply"}}
    else
      {:ok, attrs}
    end
  end

  @doc "Put `value` under `key` unless it is nil — the omit-don't-blank rule."
  @spec maybe_put(map(), atom(), term()) :: map()
  def maybe_put(map, _key, nil), do: map
  def maybe_put(map, key, value), do: Map.put(map, key, value)

  @doc """
  The message text for a `:skill_patch` proposal that names no target skill —
  a Stage 3 gap, not a malformed payload, so it reads as such.
  """
  @spec skill_gap_message() :: String.t()
  def skill_gap_message do
    "this proposal names no target skill: the loop does not yet map a finding " <>
      "category to a skill (Stage 3 work), so the skill patch must be authored " <>
      "by hand — reject this row once you have"
  end
end
