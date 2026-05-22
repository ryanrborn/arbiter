defmodule Arbiter.Vernacular do
  @moduledoc """
  User-facing vocabulary lookup.

  Every `Workspace.config["vernacular"]` JSON object is a partial override of
  the canonical gas-town vocabulary. This module reads from that JSON with a
  fallback to the canonical defaults. Internal Elixir names (`Polecat`,
  `Refinery`, etc.) stay stable; this module is the read-through layer that
  CLI output, dashboards, notifications, and templates use.

  ## Schema (per `docs/decision-doc.md` section 7)

  ```json
  {
    "vernacular": {
      "coordinator": "Admiral",
      "worker": "Acolyte",
      "merge_queue": "Reclamation",
      "monitor": "Inquisitor",
      "watchdog": "Grand Moff",
      "issue": "Directive",
      "batch": "Strike Force",
      "rig": "Ship",
      "epic": "Campaign",
      "aliases": { "deploy": "sling", "report": "done" },
      "emoji": { "worker": "⚔️", "issue": "📜" }
    }
  }
  ```

  All keys optional; missing keys fall through to the gas-town defaults.

  ## Process-dict caching

  Looking up the workspace's config every call would mean a DB roundtrip per
  CLI command. Instead, callers should call `put_active/1` once with a
  workspace (or its config map) at the start of a request / CLI invocation;
  subsequent `label/1`, `alias_resolve/1`, `emoji/1` calls read from the
  process dict. `clear/0` resets.

  If no workspace has been put, lookups fall back to the gas-town defaults
  silently — code that doesn't care about vernacular doesn't need to set up
  anything.

  ## Acceptance (gte-P2)

  * `label(:worker)` on the default workspace returns `"polecat"`.
  * After `put_active(%{config: %{"vernacular" => %{"worker" => "Acolyte"}}})`,
    `label(:worker)` returns `"Acolyte"`.
  * `label(:unknown_key)` raises `KeyError` with a clear message.
  """

  alias Arbiter.Beads.Workspace

  @pdict_key :arbiter_active_vernacular

  @defaults %{
    coordinator: "mayor",
    worker: "polecat",
    merge_queue: "refinery",
    monitor: "witness",
    watchdog: "deacon",
    issue: "bead",
    batch: "convoy",
    rig: "rig",
    epic: "mountain",
    workspace: "workspace",
    escalation: "escalation",
    pr: "pull request"
  }

  @valid_keys Map.keys(@defaults)

  @doc "The canonical gas-town vocab. Used as fallback when a workspace's vernacular omits a key."
  @spec defaults() :: %{atom() => String.t()}
  def defaults, do: @defaults

  @doc "The set of legal label keys."
  @spec keys() :: [atom()]
  def keys, do: @valid_keys

  @doc """
  Set the active vernacular for the current process. Accepts a `Workspace`
  struct (reads its `:config`), a config map (the `%{"vernacular" => ..., ...}` shape),
  or `nil` to clear.
  """
  @spec put_active(Workspace.t() | map() | nil) :: :ok
  def put_active(nil), do: clear()
  def put_active(%Workspace{config: config}), do: put_active(config)

  def put_active(%{} = config) do
    Process.put(@pdict_key, config)
    :ok
  end

  @doc """
  Load the global vernacular from `Arbiter.Settings` into the process dict.

  Call once at the start of a request (LiveView on_mount, Plug, etc.) so
  that subsequent `label/1`, `alias_resolve/1`, and `emoji/1` calls reflect
  the installation-wide vocabulary rather than gas-town defaults.
  """
  @spec put_global() :: :ok
  def put_global do
    case Arbiter.Settings.get() do
      {:ok, %{vernacular: v}} when is_map(v) -> put_active(%{"vernacular" => v})
      _ -> :ok
    end
  end

  @doc "Clear the per-process active vernacular."
  @spec clear() :: :ok
  def clear do
    Process.delete(@pdict_key)
    :ok
  end

  @doc """
  Look up a label. `key` must be one of `keys/0`; unknown keys raise.

  Looks at the active workspace's `config["vernacular"][key]` first, falling
  back to the canonical default.
  """
  @spec label(atom()) :: String.t()
  def label(key) when key in @valid_keys do
    case Map.fetch(active_vernacular_map(), Atom.to_string(key)) do
      {:ok, value} when is_binary(value) and value != "" -> value
      _ -> Map.fetch!(@defaults, key)
    end
  end

  def label(key) do
    raise KeyError,
      key: key,
      term: __MODULE__,
      message: "unknown vernacular key #{inspect(key)} (valid: #{inspect(@valid_keys)})"
  end

  @doc """
  Look up an alias. `verb` is a CLI verb atom or string (e.g. `:deploy`); the
  return value is the workspace-defined alias if set, else the original verb
  as a string. Always returns a string for ergonomic CLI use.
  """
  @spec alias_resolve(atom() | String.t()) :: String.t()
  def alias_resolve(verb) when is_atom(verb), do: alias_resolve(Atom.to_string(verb))

  def alias_resolve(verb) when is_binary(verb) do
    case active_vernacular_map() |> Map.get("aliases", %{}) |> Map.fetch(verb) do
      {:ok, value} when is_binary(value) and value != "" -> value
      _ -> verb
    end
  end

  @doc """
  Look up an emoji. `key` must be one of `keys/0`. Returns an empty string if
  the active workspace's vernacular has no emoji for that key.
  """
  @spec emoji(atom()) :: String.t()
  def emoji(key) when key in @valid_keys do
    case active_vernacular_map() |> Map.get("emoji", %{}) |> Map.fetch(Atom.to_string(key)) do
      {:ok, value} when is_binary(value) -> value
      _ -> ""
    end
  end

  def emoji(key) do
    raise KeyError,
      key: key,
      term: __MODULE__,
      message: "unknown vernacular key #{inspect(key)} (valid: #{inspect(@valid_keys)})"
  end

  # ---- internals ----

  defp active_vernacular_map do
    case Process.get(@pdict_key) do
      nil -> %{}
      %{"vernacular" => v} when is_map(v) -> v
      %{} = config -> Map.get(config, "vernacular", %{})
      _ -> %{}
    end
  end
end
