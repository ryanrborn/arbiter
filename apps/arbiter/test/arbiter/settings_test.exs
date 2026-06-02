defmodule Arbiter.SettingsTest do
  use Arbiter.DataCase, async: false

  alias Arbiter.{Branding, Settings}

  setup do
    on_exit(fn -> Branding.clear() end)
    :ok
  end

  test "get/0 creates the singleton with empty vernacular and branding" do
    {:ok, settings} = Settings.get()
    assert settings.vernacular == %{}
    assert settings.branding == %{}
  end

  test "update_branding/2 persists and round-trips through Branding.put_global/0" do
    {:ok, settings} = Settings.get()

    {:ok, updated} =
      Settings.update_branding(settings, %{
        "name" => "Penumbral Arbiter",
        "wordmark" => "/images/eclipse-wordmark.png"
      })

    assert updated.branding["name"] == "Penumbral Arbiter"

    # A fresh read sees the persisted branding, and put_global loads it.
    :ok = Branding.put_global()
    assert Branding.get(:name) == "Penumbral Arbiter"
    assert Branding.get(:wordmark) == "/images/eclipse-wordmark.png"
    # untouched keys still fall back to the neutral default
    assert Branding.get(:mark) == "/images/arbiter-mark.png"
  end

  test "update_branding/2 leaves vernacular untouched" do
    {:ok, settings} = Settings.get()
    {:ok, settings} = Settings.update_vernacular(settings, %{"worker" => "Acolyte"})
    {:ok, updated} = Settings.update_branding(settings, %{"name" => "Eclipse"})

    assert updated.vernacular == %{"worker" => "Acolyte"}
    assert updated.branding == %{"name" => "Eclipse"}
  end
end
