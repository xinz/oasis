defmodule Oasis.Plug.RequestValidatorTest do
    use ExUnit.Case, async: false
  import Plug.Test
  import Plug.Conn
  alias Oasis.Plug.RequestValidator

  defmodule ReadBodyErrorAdapter do
    def read_req_body(reason, _opts), do: {:error, reason}
  end

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

      assert conn.body_params == %{"_json" => 123}
      assert conn.params == %{"_json" => 123}
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

    test "does not let private metadata override raw JSON provenance" do
      schema = Oasis.Test.JSONSchema.compile!(%{"type" => "integer"})
      body_schema = %{"content" => %{"application/json" => %{"schema" => schema}}}

      conn =
        conn(:post, "/", %{"_json" => 123})
        |> put_req_header("content-type", "application/json")
        |> assign(:raw_body, [~s({"_json":123})])
        |> put_private(:oasis_json_root, :non_object)

      assert_raise Oasis.BadRequestError, ~r/Expected Integer but got Object/, fn ->
        RequestValidator.call(conn, body_schema: body_schema)
      end
    end

    test "validates an explicit JSON null instead of treating it as an absent optional body" do
      body_schema = %{
        "content" => %{"application/json" => %{"schema" => Oasis.Test.JSONSchema.compile!(false)}}
      }

      conn =
        conn(:post, "/", %{"_json" => nil})
        |> put_req_header("content-type", "application/json")
        |> assign(:raw_body, ["null"])

      assert_raise Oasis.BadRequestError, fn ->
        RequestValidator.call(conn, body_schema: body_schema)
      end
    end

    test "accepts a present JSON null for a required null-capable schema" do
      schema = Oasis.Test.JSONSchema.compile!(%{"type" => ["integer", "null"]})

      body_schema = %{
        "content" => %{"application/json" => %{"schema" => schema}},
        "required" => true
      }

      conn =
        conn(:post, "/", %{"_json" => nil})
        |> put_req_header("content-type", "application/json")
        |> assign(:raw_body, ["null"])
        |> RequestValidator.call(body_schema: body_schema)

      assert conn.body_params == %{"_json" => nil}
      assert conn.params == %{"_json" => nil}
    end

    test "distinguishes an absent cached body from an explicit JSON value" do
      optional = %{
        "content" => %{"application/json" => %{"schema" => Oasis.Test.JSONSchema.compile!(false)}}
      }

      conn =
        conn(:post, "/", %{})
        |> put_req_header("content-type", "application/json")
        |> assign(:raw_body, [""])
        |> RequestValidator.call(body_schema: optional)

      assert conn.body_params == %{}

      generated_empty =
        conn(:post, "/", %{})
        |> delete_req_header("content-type")
        |> RequestValidator.call(body_schema: optional)

      assert generated_empty.body_params == %{}

      required = Map.put(optional, "required", true)

      for conn <- [
            conn(:post, "/", %{})
            |> put_req_header("content-type", "application/json")
            |> assign(:raw_body, [""]),
            conn(:post, "/", %{})
            |> delete_req_header("content-type")
          ] do
        assert_raise Oasis.BadRequestError, ~r/Missing a required parameter/, fn ->
          RequestValidator.call(conn, body_schema: required)
        end
      end
    end

    test "keeps a standard Plug.Parsers primitive wrapper when raw provenance is unavailable" do
      parser_opts = Plug.Parsers.init(parsers: [:json], pass: ["*/*"], json_decoder: Jason)
      schema = Oasis.Test.JSONSchema.compile!(%{"type" => "integer"})
      body_schema = %{"content" => %{"application/json" => %{"schema" => schema}}}

      conn =
        conn(:post, "/", "123")
        |> put_req_header("content-type", "application/json")
        |> Plug.Parsers.call(parser_opts)

      assert conn.body_params == %{"_json" => 123}

      assert_raise Oasis.BadRequestError, ~r/Expected Integer but got Object/, fn ->
        RequestValidator.call(conn, body_schema: body_schema)
      end
    end

    test "unwraps a Plug.Parsers primitive when CacheRawBodyReader is configured" do
      parser_opts =
        Plug.Parsers.init(
          parsers: [:json],
          pass: ["*/*"],
          json_decoder: Jason,
          body_reader: {Oasis.CacheRawBodyReader, :read_body, []}
        )

      schema = Oasis.Test.JSONSchema.compile!(%{"type" => "integer"})
      body_schema = %{"content" => %{"application/json" => %{"schema" => schema}}}

      conn =
        conn(:post, "/", "123")
        |> put_req_header("content-type", "application/json")
        |> Plug.Parsers.call(parser_opts)
        |> RequestValidator.call(body_schema: body_schema)

      assert conn.body_params == %{"_json" => 123}
      assert conn.params == %{"_json" => 123}
    end

    test "fails closed when an empty parsed object has no raw-body provenance" do
      parser_opts = Plug.Parsers.init(parsers: [:json], pass: ["*/*"], json_decoder: Jason)
      body_schema = %{"content" => %{"application/json" => %{"schema" => Oasis.Test.JSONSchema.compile!(false)}}}

      conn =
        conn(:post, "/", "{}")
        |> put_req_header("content-type", "application/json")
        |> Plug.Parsers.call(parser_opts)

      assert conn.body_params == %{}

      try do
        RequestValidator.call(conn, body_schema: body_schema)
        flunk("expected missing raw-body provenance error")
      rescue
        error in Oasis.BadRequestError ->
          assert error.plug_status == 415
          assert error.use_in == "body"
          assert error.param_name == "body_request"
          assert error.message =~ "empty request body from an empty parsed object"
      end
    end

    test "validates an empty JSON object when CacheRawBodyReader is configured" do
      parser_opts =
        Plug.Parsers.init(
          parsers: [:json],
          pass: ["*/*"],
          json_decoder: Jason,
          body_reader: {Oasis.CacheRawBodyReader, :read_body, []}
        )

      body_schema = %{"content" => %{"application/json" => %{"schema" => Oasis.Test.JSONSchema.compile!(false)}}}

      conn =
        conn(:post, "/", "{}")
        |> put_req_header("content-type", "application/json")
        |> Plug.Parsers.call(parser_opts)

      assert conn.assigns.raw_body == ["{}"]

      try do
        RequestValidator.call(conn, body_schema: body_schema)
        flunk("expected JSON Schema validation error")
      rescue
        error in Oasis.BadRequestError ->
          assert error.plug_status == 400
          assert %Oasis.BadRequestError.JSONSchemaValidationFailed{} = error.error
      end
    end

    test "CacheRawBodyReader preserves chunk status and adapter errors" do
      conn = conn(:post, "/", "abcdef")

      assert {:more, "abc", conn} = Oasis.CacheRawBodyReader.read_body(conn, length: 3)
      assert conn.assigns.raw_body == ["abc"]

      assert {:ok, "def", conn} = Oasis.CacheRawBodyReader.read_body(conn, length: 3)
      assert conn.assigns.raw_body == ["def", "abc"]

      error_conn = %{conn(:post, "/", "") | adapter: {ReadBodyErrorAdapter, :closed}}
      assert Oasis.CacheRawBodyReader.read_body(error_conn, []) == {:error, :closed}
    end
  end

  describe "request body media selection" do
    test "validates the selected wildcard media range using the actual request type" do
      schema = Oasis.Test.JSONSchema.compile!(%{"type" => "integer"})
      body_schema = %{"content" => %{"*/*" => %{"schema" => schema}}}

      invalid =
        conn(:post, "/", %{"_json" => "invalid"})
        |> put_req_header("content-type", "application/json")
        |> assign(:raw_body, [~s("invalid")])

      assert_raise Oasis.BadRequestError, ~r/Failed to convert parameter/, fn ->
        RequestValidator.call(invalid, body_schema: body_schema)
      end

      valid =
        conn(:post, "/", %{"_json" => 123})
        |> put_req_header("content-type", "application/json")
        |> assign(:raw_body, ["123"])
        |> RequestValidator.call(body_schema: body_schema)

      assert valid.body_params == %{"_json" => 123}
    end

    test "does not let a wildcard media range bypass multipart upload policy" do
      upload = %Plug.Upload{content_type: "text/plain", filename: "a.txt", path: "/tmp/a.txt"}

      schema =
        Oasis.Test.JSONSchema.compile!(%{
          "type" => "object",
          "properties" => %{"file" => %{}}
        })

      body_schema = %{"content" => %{"*/*" => %{"schema" => schema}}}

      conn =
        conn(:post, "/", %{"file" => upload})
        |> put_req_header("content-type", "multipart/form-data; boundary=oasis")
        |> assign(:raw_body, ["--oasis--"])

      assert_raise Oasis.BadRequestError, ~r/Type mismatch/, fn ->
        RequestValidator.call(conn, body_schema: body_schema)
      end
    end

    test "rejects a present body whose Content-Type is not declared" do
      schema = Oasis.Test.JSONSchema.compile!(%{"type" => "object"})
      body_schema = %{"content" => %{"application/json" => %{"schema" => schema}}}

      conn =
        conn(:post, "/", %{"value" => 1})
        |> put_req_header("content-type", "application/xml")
        |> assign(:raw_body, ["<value>1</value>"])

      try do
        RequestValidator.call(conn, body_schema: body_schema)
        flunk("expected unsupported media type")
      rescue
        error in Oasis.BadRequestError ->
          assert error.plug_status == 415
          assert error.use_in == "header"
          assert error.param_name == "content-type"
          assert %Oasis.BadRequestError.Invalid{value: "application/xml"} = error.error
      end
    end

    test "rejects an unsupported media type even when an OpenAPI wildcard matches" do
      body_schema = %{
        "content" => %{"*/*" => %{"schema" => Oasis.Test.JSONSchema.compile!(%{})}}
      }

      conn =
        conn(:post, "/", %{"value" => 1})
        |> put_req_header("content-type", "application/xml")
        |> assign(:raw_body, ["<value>1</value>"])

      try do
        RequestValidator.call(conn, body_schema: body_schema)
        flunk("expected unsupported media type")
      rescue
        error in Oasis.BadRequestError ->
          assert error.plug_status == 415
          assert error.use_in == "header"
          assert error.param_name == "content-type"
          assert %Oasis.BadRequestError.Invalid{value: "application/xml"} = error.error
      end
    end

    test "enforces required and parser configuration for unfetched bodies" do
      schema = Oasis.Test.JSONSchema.compile!(%{"type" => "integer"})

      required = %{
        "required" => true,
        "content" => %{"application/json" => %{"schema" => schema}}
      }

      assert_raise Oasis.BadRequestError, ~r/Missing a required parameter/, fn ->
        conn(:post, "/", "")
        |> RequestValidator.call(body_schema: required)
      end

      try do
        conn(:post, "/", "123")
        |> put_req_header("content-type", "application/json")
        |> RequestValidator.call(body_schema: required)

        flunk("expected parser configuration error")
      rescue
        error in Oasis.BadRequestError ->
          assert error.plug_status == 415
          assert error.use_in == "body"
          assert error.param_name == "body_request"
          assert %Oasis.BadRequestError.Invalid{value: "application/json"} = error.error
          assert error.message =~ "was not parsed"
      end

      try do
        conn(:post, "/", "")
        |> put_req_header("content-type", "application/json")
        |> RequestValidator.call(body_schema: required)

        flunk("expected parser configuration error")
      rescue
        error in Oasis.BadRequestError ->
          assert error.plug_status == 415
          assert error.message =~ "was not parsed"
      end
    end

    test "treats whitespace bytes as a present body" do
      body_schema = %{
        "content" => %{
          "application/x-www-form-urlencoded" => %{
            "schema" => Oasis.Test.JSONSchema.compile!(false)
          }
        }
      }

      conn =
        conn(:post, "/", %{})
        |> put_req_header("content-type", "application/x-www-form-urlencoded")
        |> assign(:raw_body, ["   "])

      assert_raise Oasis.BadRequestError, fn ->
        RequestValidator.call(conn, body_schema: body_schema)
      end
    end

    test "uses framing headers as evidence that an empty parsed map came from a body" do
      body_schema = %{
        "content" => %{"application/json" => %{"schema" => Oasis.Test.JSONSchema.compile!(false)}}
      }

      for {header, value} <- [{"content-length", "2"}, {"transfer-encoding", "chunked"}] do
        conn =
          conn(:post, "/", %{})
          |> put_req_header("content-type", "application/json")
          |> put_req_header(header, value)

        try do
          RequestValidator.call(conn, body_schema: body_schema)
          flunk("expected present body to be validated")
        rescue
          error in Oasis.BadRequestError ->
            assert error.plug_status == 400
            assert %Oasis.BadRequestError.JSONSchemaValidationFailed{} = error.error
        end
      end
    end
  end

  describe("with charset in send request") do
    test "matches charset parameter values case-insensitively" do
      schema = Oasis.Test.JSONSchema.compile!(%{"type" => "integer"})

      body_schema = %{
        "content" => %{"application/json; charset=utf-8" => %{"schema" => schema}}
      }

      conn =
        conn(:post, "/req_validator", %{"_json" => 123})
        |> put_req_header("content-type", "application/json; charset=UTF-8")
        |> assign(:raw_body, ["123"])
        |> RequestValidator.call(body_schema: body_schema)

      assert conn.body_params == %{"_json" => 123}
    end

    test "parameterized vendor +json content selects and validates its OpenAPI media type" do
      schema = Oasis.Test.JSONSchema.compile!(%{"type" => "integer"})

      body_schema = %{
        "content" => %{"application/vnd.oasis+json" => %{"schema" => schema}},
        "required" => true
      }

      invalid =
        conn(:post, "/req_validator", %{"_json" => "invalid"})
        |> put_req_header("content-type", "Application/Vnd.Oasis+JSON; charset=UTF-8")
        |> assign(:raw_body, [~s("invalid")])

      assert_raise Oasis.BadRequestError, ~r/Failed to convert parameter/, fn ->
        RequestValidator.call(invalid, body_schema: body_schema)
      end

      valid =
        conn(:post, "/req_validator", %{"_json" => 123})
        |> put_req_header("content-type", "application/vnd.oasis+json; charset=utf-8")
        |> assign(:raw_body, ["123"])
        |> RequestValidator.call(body_schema: body_schema)

      assert valid.body_params == %{"_json" => 123}
      assert valid.params == %{"_json" => 123}
    end

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
