defmodule Arbiter.Branding do
  @moduledoc """
  Installation-wide visual branding lookup.

  Sibling to `Arbiter.Vernacular`: where vernacular makes the *words*
  configurable, this makes the *marks* configurable — the top-bar logo, the
  favicon, the product name, and an optional accent colour. A neutral default
  (the "arbiter" mark/wordmark) ships in the box so the stock install imposes
  nothing; an operator can drop a `branding` object into their global settings
  to load a personal theme (e.g. a Sith eclipse mark) without forking.

  ## Schema

  Branding lives in `Settings.branding` (and is read through here from a
  `config["branding"]` JSON object, mirroring vernacular's shape):

  ```json
  {
    "branding": {
      "name": "Penumbral Arbiter",
      "mark": "/images/eclipse-mark.png",
      "wordmark": "/images/eclipse-wordmark.png",
      "favicon": "/images/eclipse-favicon.png",
      "accent": "oklch(58% 0.233 277.117)"
    }
  }
  ```

  All keys optional; missing keys fall through to the neutral defaults. `mark`,
  `wordmark`, and `favicon` are static asset paths (served from
  `priv/static`); `accent` is any CSS colour string and is `nil` by default
  (meaning "leave the theme's own primary colour alone").

  ## Process-dict caching

  Like vernacular, branding is read on a hot path (every page render), so we
  avoid a DB roundtrip per lookup. Callers should `put_global/0` once at the
  start of a request — a `:browser` pipeline plug for the dead render and an
  `on_mount` hook for live re-renders — and subsequent `get/1` / `all/0` calls
  read from the process dict. If nothing has been put, lookups fall back to the
  neutral defaults silently.
  """

  alias Arbiter.Beads.Workspace

  @pdict_key :arbiter_active_branding

  @defaults %{
    name: "Arbiter",
    mark: "/images/arbiter-mark.png",
    wordmark: "/images/arbiter-wordmark.png",
    favicon: "/favicon.ico",
    accent: nil
  }

  @valid_keys Map.keys(@defaults)

  @doc "The neutral default branding. Used as fallback when config omits a key."
  @spec defaults() :: %{atom() => String.t() | nil}
  def defaults, do: @defaults

  @doc "The set of legal branding keys."
  @spec keys() :: [atom()]
  def keys, do: @valid_keys

  @doc """
  Set the active branding for the current process. Accepts a `Workspace`
  struct (reads its `:config`), a config map (the `%{"branding" => ...}`
  shape), or `nil` to clear.
  """
  @spec put_active(Workspace.t() | map() | nil) :: :ok
  def put_active(nil), do: clear()
  def put_active(%Workspace{config: config}), do: put_active(config)

  def put_active(%{} = config) do
    Process.put(@pdict_key, config)
    :ok
  end

  @doc """
  Load the global branding from `Arbiter.Settings` into the process dict.

  Call once at the start of a request (Plug for the dead render, LiveView
  `on_mount` for live re-renders) so subsequent `get/1` and `all/0` calls
  reflect the installation-wide branding rather than the neutral defaults.
  """
  @spec put_global() :: :ok
  def put_global do
    case Arbiter.Settings.get() do
      {:ok, %{branding: b}} when is_map(b) -> put_active(%{"branding" => b})
      _ -> :ok
    end
  end

  @doc "Clear the per-process active branding."
  @spec clear() :: :ok
  def clear do
    Process.delete(@pdict_key)
    :ok
  end

  @doc """
  Look up one branding value. `key` must be one of `keys/0`; unknown keys raise.

  Looks at the active `config["branding"][key]` first, falling back to the
  neutral default. A blank string is treated as absent.
  """
  @spec get(atom()) :: String.t() | nil
  def get(key) when key in @valid_keys do
    case Map.fetch(active_branding_map(), Atom.to_string(key)) do
      {:ok, value} when is_binary(value) and value != "" -> value
      _ -> Map.fetch!(@defaults, key)
    end
  end

  def get(key) do
    raise KeyError,
      key: key,
      term: __MODULE__,
      message: "unknown branding key #{inspect(key)} (valid: #{inspect(@valid_keys)})"
  end

  @doc "The fully-resolved branding map (every key, defaults filled in)."
  @spec all() :: %{atom() => String.t() | nil}
  def all, do: Map.new(@valid_keys, fn key -> {key, get(key)} end)

  # ---- internals ----

  defp active_branding_map do
    case Process.get(@pdict_key) do
      nil -> %{}
      %{"branding" => b} when is_map(b) -> b
      %{} = config -> Map.get(config, "branding", %{})
      _ -> %{}
    end
  end
end
