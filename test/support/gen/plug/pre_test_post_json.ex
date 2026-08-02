defmodule Oasis.Gen.Plug.PreTestPostJSON do
  # NOTICE: Please DO NOT write any business code in this module, since it will always be overridden when
  # run `mix oas.gen.plug` task command with the OpenAPI Specification file.
  use Oasis.Controller
  use Plug.ErrorHandler
  require JSONSchex.Schema

  plug(Plug.Parsers,
    parsers: [:json],
    json_decoder: Jason,
    pass: ["*/*"],
    body_reader: {Oasis.CacheRawBodyReader, :read_body, []}
  )

  plug(Oasis.Plug.RequestValidator,
    body_schema: %{
      "required" => true,
      "content" => %{
        "application/json" => %{
          "schema" =>
            JSONSchex.Schema.compile!(
              %{
                "items" => %{
                  "type" => "object",
                  "properties" => %{
                    "id" => %{"type" => "integer"},
                    "name" => %{"type" => "string"}
                  },
                  "required" => ["id", "name"]
                },
                "type" => "array"
              },
              format_assertion: true,
              content_assertion: false
            )
        },
        "application/vnd.api-v1+json" => %{
          "schema" =>
            JSONSchex.Schema.compile!(
              %{"type" => "integer"},
              format_assertion: true,
              content_assertion: false
            )
        },
        "application/vnd.api-v2+json" => %{
          "schema" =>
            JSONSchex.Schema.compile!(
              %{"type" => "number"},
              format_assertion: true,
              content_assertion: false
            )
        },
        "application/vnd.api-v3+json" => %{
          "schema" =>
            JSONSchex.Schema.compile!(
              %{
                "properties" => %{
                  "_json" => %{
                    "type" => "object",
                    "properties" => %{
                      "street_name" => %{"type" => "string"},
                      "street_type" => %{"enum" => ["Street", "Avenue", "Boulevard"]},
                      "id" => %{"type" => "integer"}
                    }
                  }
                },
                "type" => "object"
              },
              format_assertion: true,
              content_assertion: false
            )
        }
      }
    }
  )

  def call(conn, opts) do
    conn |> super(opts) |> Oasis.Gen.Plug.TestPost.call(opts) |> halt()
  end

  defdelegate handle_errors(conn, error), to: Oasis.Gen.Plug.TestPost
end
