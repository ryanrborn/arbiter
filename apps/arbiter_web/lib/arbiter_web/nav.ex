defmodule ArbiterWeb.Nav do
  @moduledoc """
  Navigation model for ArbiterWeb chrome: groups, items, and active-path resolution.

  Separates the nav hierarchy and routing from component presentation so both
  the rail navigation and top navigation share the exact same groups, order,
  badges, icons, and longest-match active href rules.
  """

  use ArbiterWeb, :verified_routes
  import ArbiterWeb.Labels, only: [cap_plural: 1]

  @type item :: %{
          label: String.t(),
          href: String.t(),
          icon: String.t(),
          badge: integer() | nil
        }

  @type group :: %{
          label: String.t() | nil,
          items: [item()]
        }

  @doc """
  Returns the ordered list of navigation groups.

  Takes the open-epic count which is assigned to the `:badge` of the Epics item.
  Every other item's `:badge` is nil. `label: nil` marks the leading ungrouped
  group (Board).
  """
  @spec groups(integer() | nil) :: [group()]
  def groups(open_epic_count) do
    [
      %{
        label: nil,
        items: [
          %{label: "Board", href: ~p"/", icon: "hero-view-columns", badge: nil}
        ]
      },
      %{
        label: "Work",
        items: [
          %{
            label: cap_plural("issue"),
            href: ~p"/tasks",
            icon: "hero-clipboard-document-list",
            badge: nil
          },
          %{
            label: cap_plural("epic"),
            href: ~p"/epics",
            icon: "hero-rectangle-stack",
            badge: open_epic_count
          },
          %{
            label: cap_plural("merge queue"),
            href: ~p"/merge_queue",
            icon: "hero-queue-list",
            badge: nil
          }
        ]
      },
      %{
        label: "Fleet",
        items: [
          %{
            label: cap_plural("worker"),
            href: ~p"/workers",
            icon: "hero-cpu-chip",
            badge: nil
          },
          %{
            label: "Run history",
            href: ~p"/workers/history",
            icon: "hero-clock",
            badge: nil
          },
          %{
            label: cap_plural("session"),
            href: ~p"/sessions",
            icon: "hero-command-line",
            badge: nil
          }
        ]
      },
      %{
        label: "Analysis",
        items: [
          %{label: "Usage", href: ~p"/usage", icon: "hero-chart-bar", badge: nil},
          %{
            label: "Reviews",
            href: ~p"/reviews",
            icon: "hero-clipboard-document-check",
            badge: nil
          },
          %{
            label: "Audit",
            href: ~p"/audit",
            icon: "hero-shield-exclamation",
            badge: nil
          }
        ]
      },
      %{
        label: "Config",
        items: [
          %{
            label: cap_plural("workspace"),
            href: ~p"/workspaces",
            icon: "hero-building-office-2",
            badge: nil
          },
          %{label: "Providers", href: ~p"/providers", icon: "hero-key", badge: nil},
          %{
            label: cap_plural("skill"),
            href: ~p"/skills",
            icon: "hero-sparkles",
            badge: nil
          },
          %{label: "Loop", href: ~p"/loop", icon: "hero-arrow-path", badge: nil}
        ]
      }
    ]
  end

  @doc """
  Flattens the grouped items into a single ordered list across every group.
  """
  @spec flat_items([group()] | [item()] | integer() | nil) :: [item()]
  def flat_items(groups) when is_list(groups) do
    Enum.flat_map(groups, fn
      %{items: items} -> items
      %{href: _} = item -> [item]
    end)
  end

  def flat_items(open_epic_count) when is_integer(open_epic_count) or is_nil(open_epic_count) do
    open_epic_count |> groups() |> flat_items()
  end

  @doc """
  Predicate ported verbatim from `Navigation.nav_active?/2`:
  - `"/"` only matches exactly (`current == "/"`)
  - `nil` current path is never active
  - otherwise true when `current == target` or `String.starts_with?(current, target <> "/")`
  """
  @spec active?(String.t() | nil, String.t()) :: boolean()
  def active?(current, "/"), do: current == "/"
  def active?(nil, _target), do: false

  def active?(current, target),
    do: current == target or String.starts_with?(current, target <> "/")

  @doc """
  Resolves the `:href` of the longest matching item in `groups` against `current_path`,
  or returns `nil` when none match.
  """
  @spec active_href([group()] | [item()], String.t() | nil) :: String.t() | nil
  def active_href(groups, current_path) when is_list(groups) do
    groups
    |> flat_items()
    |> Enum.filter(&active?(current_path, &1.href))
    |> Enum.max_by(&String.length(&1.href), fn -> nil end)
    |> case do
      nil -> nil
      %{href: href} -> href
    end
  end
end
