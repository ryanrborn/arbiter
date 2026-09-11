defmodule TestFollowUp do
  def run do
    config = %{"review_automation" => %{"default" => "auto"}}
    repos = []
    repo_name = "some_repo"
    
    res = case nil do
      :off -> false
      nil -> not false # default_off? is false
      _ -> repos != []
    end
    IO.puts("Result when repos == []: #{res}")
    
    repos = ["owner/A", "owner/B"]
    res2 = case nil do
      :off -> false
      nil -> not false
      _ -> repos != []
    end
    IO.puts("Result when repos has other repos: #{res2}")
  end
end
TestFollowUp.run()
