defmodule Oasis.Plug.RequestValidatorTest do
    use ExUnit.Case, async: false
  import Plug.Test
  import Plug.Conn
  alias Oasis.Plug.RequestValidator

  @schema1 Oasis.Test.JSONSchema.compile!(
             %{
               "properties" => %{"name" => %{"type" => "string"}, "tag" => %{"type" => "integer"}},
               "required" => ["name", "tag"],
               "type" => "object"
             })
  describe "JSON root provenance" do
    test "unwraps a non-object JSON root whose effective type is behind a ref" do
      schema =
        Oasis.Test.JSONSchema.compile!(%{
          "$defs" => %{"Integer" => %{"type" => "integer"}},
          "$ref" => "#/$defs/Integer"
        })

      body_schema = %{
        "content" => %{"application/json" => %{"schema" => schema}},
        "required" => true
      }

      conn =
        conn(:post, "/", %{"_json" => 123})
        |> put_req_header("content-type", "application/json")
        |> assign(:raw_body, ["123"])
        |> RequestValidator.call(body_schema: body_schema)

      assert conn.body_params == 123
      assert conn.params == 123
    end

    test "does not unwrap a form field named _json" do
      schema =
        Oasis.Test.JSONSchema.compile!(%{
          "type" => "object",
          "required" => ["_json"],
          "properties" => %{"_json" => %{"type" => "string"}}
        })

      body_schema = %{
        "content" => %{
          "application/x-www-form-urlencoded" => %{"schema" => schema}
        }
      }

      conn =
        conn(:post, "/", %{"_json" => "ok"})
        |> put_req_header("content-type", "application/x-www-form-urlencoded")
        |> assign(:raw_body, ["_json=ok"])
        |> RequestValidator.call(body_schema: body_schema)

      assert conn.body_params == %{"_json" => "ok"}
    end

    test "preserves a literal JSON object containing _json" do
      schema =
        Oasis.Test.JSONSchema.compile!(%{
          "type" => ["object", "integer"],
          "required" => ["guard"],
          "properties" => %{"guard" => %{"const" => "ok"}},
          "additionalProperties" => false
        })

      body_schema = %{
        "content" => %{"application/json" => %{"schema" => schema}},
        "required" => true
      }

      conn =
        conn(:post, "/", %{"_json" => 123})
        |> put_req_header("content-type", "application/json")
        |> assign(:raw_body, [~s({"_json":123})])

      assert_raise Oasis.BadRequestError, ~r/Required property guard was not present/, fn ->
        RequestValidator.call(conn, body_schema: body_schema)
      end
    end
  end

  describe("with charset in send request") do
    test "content type application/json" do
      body_schema = %{
        "content" => %{"application/json" => %{"schema" => @schema1}},
        "required" => true
      }

      assert_raise Oasis.BadRequestError, ~r/Failed to convert parameter/, fn ->
        conn =
          conn(:post, "/req_validator", %{"name" => "test_name", "tag" => "a"})
          |> put_req_header("content-type", "Application/json; charset=utf-8")

        RequestValidator.call(conn, body_schema: body_schema)
      end

      conn =
        conn(:post, "/req_validator", %{"name" => "test_name", "tag" => "1"})
        |> put_req_header("content-type", "Application/json; charset=utf-8")

      conn = RequestValidator.call(conn, body_schema: body_schema)
      body_params = conn.body_params
      params = conn.params
      assert body_params == params
      assert body_params["tag"] == 1 and body_params["name"] == "test_name"
    end

    test "content type text/plain" do
      body_schema = %{"content" => %{"text/plain" => %{"schema" => @schema1}}, "required" => true}

      assert_raise Oasis.BadRequestError, ~r/Failed to convert parameter/, fn ->
        conn =
          conn(:post, "/req_validator", %{"name" => "test_name", "tag" => "a"})
          |> put_req_header("content-type", "tExt/PlAin; charset=utf-8")

        RequestValidator.call(conn, body_schema: body_schema)
      end

      conn =
        conn(:post, "/req_validator", %{"name" => "test_name", "tag" => "-1"})
        |> put_req_header("content-type", "text/plain; charset=utf-8")

      conn = RequestValidator.call(conn, body_schema: body_schema)
      body_params = conn.body_params
      params = conn.params
      assert body_params == params
      assert body_params["tag"] == -1 and body_params["name"] == "test_name"
    end

    test "content type application/x-www-form-urlencoded" do
      body_schema = %{
        "content" => %{"application/x-www-form-urlencoded" => %{"schema" => @schema1}},
        "required" => true
      }

      assert_raise Oasis.BadRequestError, ~r/Failed to convert parameter/, fn ->
        conn =
          conn(:post, "/req_validator", %{"name" => "test_name", "tag" => "a"})
          |> put_req_header("content-type", "application/x-www-form-urlencoded; charset=utf-8")

        RequestValidator.call(conn, body_schema: body_schema)
      end

      assert_raise Oasis.BadRequestError, ~r/Failed to convert parameter/, fn ->
        conn =
          conn(:post, "/req_validator", %{"name" => "test_name2", "tag" => "100.0"})
          |> put_req_header("content-type", "application/x-www-form-urlencoded; charset=utf-8")

        RequestValidator.call(conn, body_schema: body_schema)
      end

      conn =
        conn(:post, "/req_validator", %{"name" => "test_name2", "tag" => "1000"})
        |> put_req_header("content-type", "application/x-www-form-urlencoded; charset=utf-8")

      conn = RequestValidator.call(conn, body_schema: body_schema)
      body_params = conn.body_params
      params = conn.params
      assert body_params == params
      assert body_params["tag"] == 1000 and body_params["name"] == "test_name2"
    end
  end
end
