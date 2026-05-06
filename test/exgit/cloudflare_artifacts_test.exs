defmodule Exgit.CloudflareArtifactsTest do
  @moduledoc """
  Unit tests for the Cloudflare Artifacts REST client. Uses Bypass
  to assert request shape (URL path, method, headers, body, query
  params) and to feed scripted v4-envelope responses through the
  client's parsers.

  Live network coverage of the same surface lives in
  `cloudflare_artifacts_roundtrip_test.exs` (tagged `:cloudflare`).
  """

  use ExUnit.Case, async: true

  alias Exgit.CloudflareArtifacts
  alias Exgit.CloudflareArtifacts.{Repo, Token}

  @account "acct_test"
  @namespace "default"
  @api_token "TEST_API_TOKEN"

  @ns_path "/client/v4/accounts/#{@account}/artifacts/namespaces/#{@namespace}"

  setup do
    bypass = Bypass.open()

    client =
      CloudflareArtifacts.new(
        account_id: @account,
        namespace: @namespace,
        api_token: @api_token,
        base_url: "http://localhost:#{bypass.port}/client/v4",
        # Disable Req's retry-on-transport-error so the bypass-down
        # test fails fast instead of retrying for ~7s.
        retry: false
      )

    {:ok, bypass: bypass, client: client}
  end

  # --- Repos ---

  describe "create_repo/2" do
    test "POSTs the create body and parses CreateRepoResult", ctx do
      Bypass.expect_once(ctx.bypass, "POST", "#{@ns_path}/repos", fn conn ->
        assert auth_header(conn) == "Bearer #{@api_token}"
        assert read_json(conn) == %{"name" => "starter-repo", "default_branch" => "main"}

        respond_ok(conn, %{
          "id" => "repo_123",
          "name" => "starter-repo",
          "description" => nil,
          "default_branch" => "main",
          "remote" =>
            "https://#{@account}.artifacts.cloudflare.net/git/#{@namespace}/starter-repo.git",
          "token" => "art_v1_" <> String.duplicate("a", 40) <> "?expires=1760000000"
        })
      end)

      assert {:ok, %Repo{} = repo} =
               CloudflareArtifacts.create_repo(ctx.client,
                 name: "starter-repo",
                 default_branch: "main"
               )

      assert repo.id == "repo_123"
      assert repo.name == "starter-repo"
      assert repo.default_branch == "main"
      assert repo.remote =~ "starter-repo.git"
      assert repo.token =~ "art_v1_"
    end

    test "drops nil keys so we don't send {default_branch: null}", ctx do
      Bypass.expect_once(ctx.bypass, "POST", "#{@ns_path}/repos", fn conn ->
        body = read_json(conn)
        assert Map.keys(body) == ["name"]
        respond_ok(conn, %{"id" => "repo_x", "name" => "x"})
      end)

      assert {:ok, %Repo{}} = CloudflareArtifacts.create_repo(ctx.client, name: "x")
    end

    test "non-2xx returns {:error, %Req.Response{}} with v4 errors intact", ctx do
      Bypass.expect_once(ctx.bypass, "POST", "#{@ns_path}/repos", fn conn ->
        respond_error(conn, 400, [%{"code" => 10_100, "message" => "name in use"}])
      end)

      assert {:error, %Req.Response{status: 400, body: %{"errors" => errors}}} =
               CloudflareArtifacts.create_repo(ctx.client, name: "dupe")

      assert [%{"code" => 10_100, "message" => "name in use"}] = errors
    end
  end

  describe "list_repos/2" do
    test "expands path with no params and returns list + result_info", ctx do
      Bypass.expect_once(ctx.bypass, "GET", "#{@ns_path}/repos", fn conn ->
        assert conn.query_string == ""
        respond_list(conn, [%{"id" => "r1", "name" => "r1"}], %{"cursor" => "next"})
      end)

      assert {:ok, [%Repo{id: "r1"}], %{"cursor" => "next"}} =
               CloudflareArtifacts.list_repos(ctx.client)
    end

    test "forwards query params verbatim", ctx do
      Bypass.expect_once(ctx.bypass, "GET", "#{@ns_path}/repos", fn conn ->
        params = URI.decode_query(conn.query_string)
        assert params["limit"] == "25"
        assert params["sort"] == "updated_at"
        assert params["direction"] == "desc"
        respond_list(conn, [], %{})
      end)

      assert {:ok, [], _} =
               CloudflareArtifacts.list_repos(ctx.client,
                 limit: 25,
                 sort: "updated_at",
                 direction: "desc"
               )
    end
  end

  describe "get_repo/2 + delete_repo/2" do
    test "get_repo expands :name path param", ctx do
      Bypass.expect_once(ctx.bypass, "GET", "#{@ns_path}/repos/my-repo", fn conn ->
        respond_ok(conn, %{"id" => "repo_x", "name" => "my-repo", "default_branch" => "main"})
      end)

      assert {:ok, %Repo{name: "my-repo"}} = CloudflareArtifacts.get_repo(ctx.client, "my-repo")
    end

    test "delete_repo issues DELETE and returns the {id} envelope", ctx do
      Bypass.expect_once(ctx.bypass, "DELETE", "#{@ns_path}/repos/my-repo", fn conn ->
        respond_ok(conn, %{"id" => "repo_x"}, 202)
      end)

      assert {:ok, %Repo{id: "repo_x"}} = CloudflareArtifacts.delete_repo(ctx.client, "my-repo")
    end

    test "url-encodes path-param values that contain reserved characters", ctx do
      # Pins the load-bearing assumption that Req's :path_params step
      # URL-encodes `/`, ` `, `?` (→ %2F, %20, %3F) before joining
      # into the path. Without this, repo names containing reserved
      # chars would silently produce wrong-shaped URLs.
      Bypass.expect_once(ctx.bypass, "GET", "#{@ns_path}/repos/weird%2Fname%20x", fn conn ->
        respond_ok(conn, %{"id" => "x", "name" => "weird/name x"})
      end)

      assert {:ok, %Repo{name: "weird/name x"}} =
               CloudflareArtifacts.get_repo(ctx.client, "weird/name x")
    end
  end

  describe "fork_repo/3 + import_repo/3" do
    test "fork POSTs to /repos/:name/fork and surfaces objects count", ctx do
      Bypass.expect_once(ctx.bypass, "POST", "#{@ns_path}/repos/source/fork", fn conn ->
        body = read_json(conn)
        assert body["name"] == "fork-target"
        assert body["default_branch_only"] == true

        respond_ok(conn, %{
          "id" => "repo_fork",
          "name" => "fork-target",
          "default_branch" => "main",
          "remote" => "https://example/git/default/fork-target.git",
          "token" => "art_v1_token",
          "objects" => 128
        })
      end)

      assert {:ok, %Repo{id: "repo_fork", objects: 128}} =
               CloudflareArtifacts.fork_repo(ctx.client, "source",
                 name: "fork-target",
                 default_branch_only: true
               )
    end

    test "import POSTs to /repos/:name/import with the source url", ctx do
      Bypass.expect_once(ctx.bypass, "POST", "#{@ns_path}/repos/react-mirror/import", fn conn ->
        body = read_json(conn)
        assert body["url"] == "https://github.com/facebook/react"
        assert body["depth"] == 100

        respond_ok(conn, %{
          "id" => "repo_import",
          "name" => "react-mirror",
          "default_branch" => "main",
          "remote" => "https://example/git/default/react-mirror.git",
          "token" => "art_v1_token"
        })
      end)

      assert {:ok, %Repo{name: "react-mirror"}} =
               CloudflareArtifacts.import_repo(ctx.client, "react-mirror",
                 url: "https://github.com/facebook/react",
                 depth: 100
               )
    end

    test "import 409 still returns the v4 envelope for retry decisions", ctx do
      Bypass.expect_once(ctx.bypass, "POST", "#{@ns_path}/repos/x/import", fn conn ->
        respond_error(conn, 409, [%{"code" => 10_200, "message" => "import in progress"}])
      end)

      assert {:error, %Req.Response{status: 409, body: %{"errors" => [%{"code" => 10_200} | _]}}} =
               CloudflareArtifacts.import_repo(ctx.client, "x", url: "https://example/r.git")
    end
  end

  # --- Tokens ---

  describe "create_token/2" do
    test "POSTs to /tokens (NOT /repos/:name/tokens) and returns plaintext", ctx do
      # Memory note `reference_cf_artifacts_api`: create is /tokens,
      # list is /repos/:name/tokens. Easy to mis-wire.
      Bypass.expect_once(ctx.bypass, "POST", "#{@ns_path}/tokens", fn conn ->
        assert read_json(conn) == %{"repo" => "starter-repo", "scope" => "read", "ttl" => 3600}

        respond_ok(conn, %{
          "id" => "tok_123",
          "plaintext" => "art_v1_" <> String.duplicate("b", 40) <> "?expires=1760003600",
          "scope" => "read",
          "expires_at" => "2025-10-09T12:00:00Z"
        })
      end)

      assert {:ok, %Token{} = token} =
               CloudflareArtifacts.create_token(ctx.client,
                 repo: "starter-repo",
                 scope: "read",
                 ttl: 3600
               )

      assert token.id == "tok_123"
      assert token.plaintext =~ "art_v1_"
      assert token.scope == :read
      assert token.expires_at == "2025-10-09T12:00:00Z"
    end

    test "accepts atom scope and serializes it as a string", ctx do
      Bypass.expect_once(ctx.bypass, "POST", "#{@ns_path}/tokens", fn conn ->
        # Atom :read on input must hit the wire as the string "read".
        assert read_json(conn) == %{"repo" => "r", "scope" => "read", "ttl" => 60}

        respond_ok(conn, %{
          "id" => "tok_a",
          "plaintext" => "art_v1_x",
          "scope" => "read",
          "expires_at" => "2025-10-09T12:00:00Z"
        })
      end)

      assert {:ok, %Token{scope: :read}} =
               CloudflareArtifacts.create_token(ctx.client, repo: "r", scope: :read, ttl: 60)
    end

    test "ttl out of range surfaces upstream code 10_103", ctx do
      Bypass.expect_once(ctx.bypass, "POST", "#{@ns_path}/tokens", fn conn ->
        respond_error(conn, 400, [
          %{"code" => 10_103, "message" => "ttl must be between 60 and 31536000 seconds"}
        ])
      end)

      assert {:error, %Req.Response{body: %{"errors" => [%{"code" => 10_103} | _]}}} =
               CloudflareArtifacts.create_token(ctx.client,
                 repo: "x",
                 ttl: 99_999_999
               )
    end
  end

  describe "list_tokens/3" do
    test "accepts atom state and serializes it as a string in the query", ctx do
      Bypass.expect_once(ctx.bypass, "GET", "#{@ns_path}/repos/r/tokens", fn conn ->
        params = URI.decode_query(conn.query_string)
        assert params["state"] == "active"
        respond_list(conn, [], %{})
      end)

      assert {:ok, [], _} = CloudflareArtifacts.list_tokens(ctx.client, "r", state: :active)
    end

    test "GETs /repos/:name/tokens with offset-pagination params", ctx do
      Bypass.expect_once(ctx.bypass, "GET", "#{@ns_path}/repos/starter-repo/tokens", fn conn ->
        params = URI.decode_query(conn.query_string)
        assert params["state"] == "all"
        assert params["per_page"] == "30"

        result_info = %{
          "page" => 1,
          "per_page" => 30,
          "total_pages" => 1,
          "count" => 1,
          "total_count" => 1
        }

        respond_list(
          conn,
          [
            %{
              "id" => "tok_a",
              "scope" => "write",
              "state" => "active",
              "created_at" => "2025-09-01T00:00:00Z",
              "expires_at" => "2025-10-01T00:00:00Z"
            }
          ],
          result_info
        )
      end)

      assert {:ok, [%Token{id: "tok_a", scope: :write, state: :active}], %{"total_count" => 1}} =
               CloudflareArtifacts.list_tokens(ctx.client, "starter-repo",
                 state: "all",
                 per_page: 30
               )
    end
  end

  describe "delete_token/2" do
    test "issues DELETE /tokens/:id", ctx do
      Bypass.expect_once(ctx.bypass, "DELETE", "#{@ns_path}/tokens/tok_to_kill", fn conn ->
        respond_ok(conn, %{"id" => "tok_to_kill"})
      end)

      assert {:ok, %Token{id: "tok_to_kill"}} =
               CloudflareArtifacts.delete_token(ctx.client, "tok_to_kill")
    end
  end

  # --- Transport-level error path ---

  describe "transport errors" do
    test "bypass-down returns the Req exception, not %Req.Response{}", ctx do
      Bypass.down(ctx.bypass)

      assert {:error, exception} = CloudflareArtifacts.get_repo(ctx.client, "x")
      refute is_struct(exception, Req.Response)
    end
  end

  # --- Inspect redaction ---

  describe "secret redaction" do
    test "Repo with token field redacts in inspect" do
      r = %Repo{id: "r1", name: "r1", token: "art_v1_secretsecret"}
      str = inspect(r)
      refute str =~ "secretsecret"
      assert str =~ "***"
    end

    test "Repo without token field shows normally" do
      r = %Repo{id: "r1", name: "r1"}
      assert inspect(r) =~ "id: \"r1\""
    end

    test "Token with plaintext redacts in inspect" do
      t = %Token{id: "tok_1", plaintext: "art_v1_secret_plaintext"}
      str = inspect(t)
      refute str =~ "secret_plaintext"
      assert str =~ "***"
    end
  end

  # --- Bypass / Plug helpers ---

  defp auth_header(conn) do
    Enum.find_value(conn.req_headers, fn
      {"authorization", v} -> v
      _ -> nil
    end)
  end

  defp read_json(conn) do
    {:ok, body, _conn} = Plug.Conn.read_body(conn)
    Jason.decode!(body)
  end

  defp respond_ok(conn, result, status \\ 200) when is_map(result) do
    body = Jason.encode!(envelope_body(result))

    conn
    |> Plug.Conn.put_resp_content_type("application/json")
    |> Plug.Conn.resp(status, body)
  end

  defp respond_list(conn, items, result_info) do
    body = Jason.encode!(envelope_body(items, %{"result_info" => result_info}))

    conn
    |> Plug.Conn.put_resp_content_type("application/json")
    |> Plug.Conn.resp(200, body)
  end

  defp respond_error(conn, status, errors) do
    body =
      Jason.encode!(%{
        "result" => nil,
        "success" => false,
        "errors" => errors,
        "messages" => []
      })

    conn
    |> Plug.Conn.put_resp_content_type("application/json")
    |> Plug.Conn.resp(status, body)
  end

  defp envelope_body(result, extras \\ %{}) do
    Map.merge(
      %{
        "result" => result,
        "success" => true,
        "errors" => [],
        "messages" => []
      },
      extras
    )
  end
end
