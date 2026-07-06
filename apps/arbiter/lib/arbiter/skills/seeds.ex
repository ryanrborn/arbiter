defmodule Arbiter.Skills.Seeds do
  @moduledoc """
  Built-in seed skills shipped with every arbiter install (bd-503v3d, child of
  epic bd-xfc55c).

  Three skill bodies live in-repo under `priv/seed_skills/*.md` (versioned
  files, not inlined in a migration string) and are seeded into the
  system-wide `Arbiter.Skills.Skill` registry:

    * `test-driven-development`       — `:always_on`, `code_only: true`
    * `verification-before-completion` — `:always_on`
    * `systematic-debugging`          — `:situational` (advertised, not forced)

  ## Idempotency

  `seed!/0` is insert-if-absent **by name**. A skill that already exists (for
  instance because an operator hand-edited a built-in) is left untouched and
  the skip is logged — re-running the seed never clobbers an operator edit.

  ## Where this runs

  Mirrors the existing built-in-data seed path rather than inventing a
  parallel one:

    * `priv/repo/seeds.exs` calls `seed!/0` after the default workspace is
      ensured (dev `mix setup` / `mix ecto.setup`).
    * `Arbiter.Boot.Migrator` calls `seed!/0` right after running pending
      migrations on the primary instance, so a real (dev or prod) boot seeds
      these on install / first boot / every subsequent migration — with no
      operator step required.

  ## Default-workspace wiring

  Seeding the registry rows alone does not make a skill apply to a dispatch —
  `Arbiter.Skills.Selection` only resolves skills explicitly named in a
  workspace's `config["skills"]["workspace"]` list (layered selection, decision
  C). So `seed!/0` also lists these 3 names in the **default** workspace's
  config, but only when that workspace exists yet and its config has no
  `"skills"` key at all — an operator who has already configured `"skills"` is
  never overridden.
  """

  require Ash.Query
  require Logger

  alias Arbiter.Skills
  alias Arbiter.Tasks.Workspace

  @seed_skills [
    %{
      name: "test-driven-development",
      file: "test-driven-development.md",
      description:
        "Write a failing test before the code that makes it pass. Use for any change to product/source behavior.",
      activation_mode: :always_on,
      code_only: true
    },
    %{
      name: "verification-before-completion",
      file: "verification-before-completion.md",
      description:
        "Prove the change works by observing real behavior before signalling done or opening a PR.",
      activation_mode: :always_on,
      code_only: false
    },
    %{
      name: "systematic-debugging",
      file: "systematic-debugging.md",
      description:
        "Reproduce, isolate root cause, fix the cause not the symptom, verify. Use when something fails or misbehaves.",
      activation_mode: :situational,
      code_only: false
    }
  ]

  @default_workspace_name "default"

  @doc "The built-in seed skill names, in seed order."
  @spec seed_names() :: [String.t()]
  def seed_names, do: Enum.map(@seed_skills, & &1.name)

  @doc """
  Idempotently seed the 3 built-in skills and wire them into the default
  workspace's skill config. Safe to call on every boot — existing skills and
  an already-configured default workspace are left untouched.
  """
  @spec seed!() :: :ok
  def seed! do
    Enum.each(@seed_skills, &seed_skill/1)
    seed_default_workspace_config()
    :ok
  end

  defp seed_skill(%{name: name} = attrs) do
    case Skills.get_skill_by_name(name) do
      {:ok, _existing} ->
        Logger.info("Arbiter.Skills.Seeds: skill #{inspect(name)} already exists — skipping")

      {:error, :not_found} ->
        body = File.read!(body_path(attrs.file))

        case Skills.create_skill(%{
               name: name,
               body: body,
               metadata: %{"description" => attrs.description},
               activation_mode: attrs.activation_mode,
               code_only: attrs.code_only
             }) do
          {:ok, _skill} ->
            Logger.info("Arbiter.Skills.Seeds: seeded skill #{inspect(name)}")

          {:error, reason} ->
            Logger.warning(
              "Arbiter.Skills.Seeds: failed to seed skill #{inspect(name)}: #{inspect(reason)}"
            )
        end
    end
  end

  defp body_path(file) do
    Path.join([Application.app_dir(:arbiter, "priv"), "seed_skills", file])
  end

  defp seed_default_workspace_config do
    Workspace
    |> Ash.Query.filter(name == ^@default_workspace_name)
    |> Ash.read_one()
    |> case do
      {:ok, %Workspace{} = ws} ->
        maybe_patch_workspace_skills(ws)

      {:ok, nil} ->
        :ok

      {:error, reason} ->
        Logger.warning(
          "Arbiter.Skills.Seeds: failed to look up default workspace: #{inspect(reason)}"
        )
    end
  end

  defp maybe_patch_workspace_skills(%Workspace{config: config} = ws) do
    if get_in(config || %{}, ["skills"]) do
      Logger.info(
        "Arbiter.Skills.Seeds: default workspace already has a \"skills\" config — leaving it untouched"
      )
    else
      patch = %{"skills" => %{"workspace" => seed_names()}}

      case Ash.update(ws, %{patch: patch}, action: :patch_config) do
        {:ok, _ws} ->
          Logger.info("Arbiter.Skills.Seeds: enabled seed skills on the default workspace")

        {:error, reason} ->
          Logger.warning(
            "Arbiter.Skills.Seeds: failed to enable seed skills on default workspace: #{inspect(reason)}"
          )
      end
    end
  end
end
