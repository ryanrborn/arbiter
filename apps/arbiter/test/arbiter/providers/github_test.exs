defmodule Arbiter.Providers.GithubTest do
  use ExUnit.Case, async: true

  alias Arbiter.Http.Client
  alias Arbiter.Providers.Github

  defmodule FakeError do
    defstruct [:kind, :status, :message, :raw, :retry_after_ms]
  end

  describe "headers/1" do
    test "builds the standard GitHub REST auth headers" do
      assert Github.headers("secret-token") == [
               {"authorization", "Bearer secret-token"},
               {"accept", "application/vnd.github+json"},
               {"x-github-api-version", "2022-11-28"},
               {"user-agent", "arbiter"}
             ]
    end
  end

  describe "client/3" do
    test "builds an Arbiter.Http.Client gated through the shared GitHub limiter" do
      cfg = %{base_url: "https://api.github.com", token: "tok"}

      client = Github.client(cfg, FakeError, stub_name: MyStubName)

      assert %Client{base_url: "https://api.github.com"} = client
      assert client.headers == Github.headers("tok")
      assert client.stub == {:github_http_stub, MyStubName}
      assert client.retry == nil
      assert is_function(client.gate, 1)
    end

    test "attaches the secondary-rate-limit retry policy when requested" do
      cfg = %{base_url: "https://api.github.com", token: "tok"}

      client = Github.client(cfg, FakeError, stub_name: MyStubName, retry: :secondary_rate_limit)

      assert %{max: max, retry?: retry?, delay: delay, sleep: sleep} = client.retry
      assert max > 0
      assert is_function(retry?, 1)
      assert is_function(delay, 2)
      assert is_function(sleep, 1)
    end
  end

  describe "error_spec/1 classification" do
    defp build(status, body, resp \\ nil) do
      Github.error_spec(FakeError) |> Arbiter.Http.Error.build(status, body, resp)
    end

    test "429 is always rate_limited" do
      assert %FakeError{kind: :rate_limited} = build(429, %{"message" => "nope"})
    end

    test "403 with a rate-limit body is rate_limited, otherwise forbidden" do
      assert %FakeError{kind: :rate_limited} =
               build(403, %{"message" => "You have exceeded a secondary rate limit"})

      assert %FakeError{kind: :forbidden} = build(403, %{"message" => "Bad credentials"})
    end

    test "maps the rest of the GitHub status codes" do
      assert %FakeError{kind: :validation_failed} = build(400, %{})
      assert %FakeError{kind: :unauthenticated} = build(401, %{})
      assert %FakeError{kind: :not_found} = build(404, %{})
      assert %FakeError{kind: :not_mergeable} = build(405, %{})
      assert %FakeError{kind: :conflict} = build(409, %{})
      assert %FakeError{kind: :validation_failed} = build(422, %{})
      assert %FakeError{kind: :server_error} = build(503, %{})
      assert %FakeError{kind: :http} = build(418, %{})
    end

    test "message falls back to the status when the body has none" do
      assert %FakeError{message: "boom"} = build(500, %{"message" => "boom"})
      assert %FakeError{message: "HTTP 500"} = build(500, %{})
    end
  end

  describe "next_page/3" do
    test "returns nil when there is no rel=\"next\" Link header" do
      assert Github.next_page(%{}, "/repos/o/r/issues", params: []) == nil
    end

    test "parses the rel=\"next\" URL from an RFC 5988 Link header" do
      link =
        "<https://api.github.com/repos/o/r/issues?page=2&per_page=100>; rel=\"next\", " <>
          "<https://api.github.com/repos/o/r/issues?page=5&per_page=100>; rel=\"last\""

      assert Github.next_page(%{"link" => [link]}, "/repos/o/r/issues", params: []) ==
               {"/repos/o/r/issues", [params: [{"page", "2"}, {"per_page", "100"}]]}
    end
  end
end
