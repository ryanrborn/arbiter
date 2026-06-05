defmodule ArbiterWeb.Paging do
  @moduledoc """
  Offset/limit pagination for the index LiveViews.

  Index pages list *everything* for an entity type (unlike the dashboard,
  which shows only current/active items). To keep those pages bounded we read
  one page at a time via `Ash.Query.offset/2` + `Ash.Query.limit/2`, plus a
  separate `Ash.count!/1` for the total so the pager can render page links.

  In-memory collections (e.g. the live polecat snapshots, which are process
  state rather than rows) use `paginate_list/3`.

  Every read is wrapped so a transient data-layer error degrades to an empty
  page rather than crashing the LiveView — matching the defensive posture of
  the existing dashboard reads.
  """

  require Ash.Query

  @default_page_size 25

  @typedoc "A single page of results plus the metadata the pager needs."
  @type page :: %{
          entries: list(),
          page: pos_integer(),
          page_size: pos_integer(),
          total_count: non_neg_integer(),
          total_pages: pos_integer()
        }

  @doc "Default number of items shown per index page."
  @spec default_page_size() :: pos_integer()
  def default_page_size, do: @default_page_size

  @doc """
  Parse a 1-based page number from LiveView params, clamped to `>= 1`.
  Anything missing or unparseable falls back to page 1.
  """
  @spec parse_page(map()) :: pos_integer()
  def parse_page(%{"page" => raw}) do
    case Integer.parse(to_string(raw)) do
      {n, _} when n >= 1 -> n
      _ -> 1
    end
  end

  def parse_page(_params), do: 1

  @doc """
  Paginate an Ash query (or resource module) at the given 1-based page.

  Reads the total count and the requested slice. The page is clamped to the
  available range so an out-of-bounds `?page=` never renders an empty list
  when data exists.
  """
  @spec paginate(Ash.Query.t() | module(), pos_integer(), pos_integer()) :: page()
  def paginate(query, page, page_size \\ @default_page_size) do
    total = safe_count(query)
    total_pages = max(1, div(total + page_size - 1, page_size))
    page = page |> max(1) |> min(total_pages)
    offset = (page - 1) * page_size

    entries =
      try do
        query
        |> Ash.Query.limit(page_size)
        |> Ash.Query.offset(offset)
        |> Ash.read!()
      rescue
        _ -> []
      end

    %{
      entries: entries,
      page: page,
      page_size: page_size,
      total_count: total,
      total_pages: total_pages
    }
  end

  @doc """
  Paginate an already-materialised list (used for live process snapshots that
  aren't backed by a queryable data layer).
  """
  @spec paginate_list(list(), pos_integer(), pos_integer()) :: page()
  def paginate_list(list, page, page_size \\ @default_page_size) when is_list(list) do
    total = length(list)
    total_pages = max(1, div(total + page_size - 1, page_size))
    page = page |> max(1) |> min(total_pages)
    offset = (page - 1) * page_size

    %{
      entries: Enum.slice(list, offset, page_size),
      page: page,
      page_size: page_size,
      total_count: total,
      total_pages: total_pages
    }
  end

  defp safe_count(query) do
    Ash.count!(query)
  rescue
    _ -> 0
  end
end
