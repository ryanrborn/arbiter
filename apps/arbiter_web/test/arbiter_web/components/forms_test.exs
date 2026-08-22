defmodule ArbiterWeb.CoreComponents.FormsTest do
  use ExUnit.Case, async: true

  import Phoenix.LiveViewTest
  import ArbiterWeb.CoreComponents.Forms

  describe "input/1" do
    test "renders a text input with default styling" do
      html = render_component(&input/1, type: "text", name: "username", id: "user-input")
      assert html =~ "type=\"text\""
      assert html =~ "name=\"username\""
      assert html =~ "id=\"user-input\""
      assert html =~ "input"
    end

    test "renders with custom class" do
      html = render_component(&input/1, type: "text", name: "username", id: "user-input", class: "custom-class")
      assert html =~ "custom-class"
    end

    test "renders disabled state" do
      html = render_component(&input/1, type: "text", name: "username", id: "user-input", disabled: true)
      assert html =~ "disabled"
    end
  end

  describe "select/1" do
    test "renders a select element with options" do
      html = render_component(&select/1, name: "status", id: "status-select", options: [{"Open", "open"}, {"Closed", "closed"}])
      assert html =~ "<select"
      assert html =~ "name=\"status\""
      assert html =~ "id=\"status-select\""
      assert html =~ "Open"
      assert html =~ "Closed"
    end

    test "renders with a prompt" do
      html = render_component(&select/1, name: "status", id: "status-select", options: [{"Open", "open"}], prompt: "Choose one...")
      assert html =~ "Choose one..."
    end

    test "selects the correct value" do
      html = render_component(&select/1, name: "status", id: "status-select", options: [{"Open", "open"}, {"Closed", "closed"}], value: "closed")
      assert html =~ "selected"
    end
  end

  describe "textarea/1" do
    test "renders a textarea element" do
      html = render_component(&textarea/1, name: "description", id: "desc-textarea")
      assert html =~ "<textarea"
      assert html =~ "name=\"description\""
      assert html =~ "id=\"desc-textarea\""
    end

    test "renders with value" do
      html = render_component(&textarea/1, name: "description", id: "desc-textarea", value: "Some text")
      assert html =~ "Some text"
    end

    test "renders disabled state" do
      html = render_component(&textarea/1, name: "description", id: "desc-textarea", disabled: true)
      assert html =~ "disabled"
    end
  end

  describe "checkbox/1" do
    test "renders a checkbox input" do
      html = render_component(&checkbox/1, name: "agree", id: "agree-checkbox")
      assert html =~ "type=\"checkbox\""
      assert html =~ "name=\"agree\""
      assert html =~ "id=\"agree-checkbox\""
    end

    test "renders with label" do
      html = render_component(&checkbox/1, name: "agree", id: "agree-checkbox", label: "I agree")
      assert html =~ "I agree"
    end

    test "renders checked state" do
      html = render_component(&checkbox/1, name: "agree", id: "agree-checkbox", checked: true)
      assert html =~ "checked"
    end
  end
end
