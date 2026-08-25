defmodule ArbiterWeb.RowsTest do
  use ExUnit.Case, async: true

  alias ArbiterWeb.WorkspaceDetail.Rows

  defp render_setting_row(assigns) do
    # Render the component to a string by calling the function and converting to HTML
    assigns = Map.put(assigns, :control, [])
    assigns = Map.put(assigns, :__changed__, nil)

    html =
      Rows.setting_row(assigns)
      |> Phoenix.HTML.Safe.to_iodata()
      |> IO.iodata_to_binary()

    html
  end

  describe "setting_row/1 responsive layout" do
    test "renders with responsive flex direction for mobile/desktop stacking" do
      html =
        render_setting_row(%{
          name: "Test Setting",
          consequence: "This changes X"
        })

      # The row should have flex-col for mobile and sm:flex-row for desktop
      assert html =~ "flex-col"
      assert html =~ "sm:flex-row"
      assert html =~ "items-start"
      assert html =~ "sm:items-center"
    end

    test "maintains name and consequence data attributes" do
      html =
        render_setting_row(%{
          name: "Enable Feature X",
          consequence: "Restarts all workers"
        })

      assert html =~ "Enable Feature X"
      assert html =~ "Restarts all workers"
      assert html =~ ~r/data-consequence="Restarts all workers"/
    end

    test "verifies component source has responsive control wrapper" do
      # Check the source code directly for the responsive control wrapper
      {:ok, source} = File.read("lib/arbiter_web/live/workspace_detail/rows.ex")

      # Should have sm:flex-none in the control wrapper, not just flex-none
      assert source =~ ~r/class="flex\s+sm:flex-none/,
             "Control wrapper should use sm:flex-none for responsive layout"
    end
  end
end
