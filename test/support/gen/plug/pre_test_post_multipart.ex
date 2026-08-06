defmodule Oasis.Gen.Plug.PreTestPostMultipart do
  # NOTICE: Please DO NOT write any business code in this module, since it will always be overridden when
  # run `mix oas.gen.plug` task command with the OpenAPI Specification file.
  use Oasis.Controller
  use Plug.ErrorHandler
  require JSONSchex.Schema

  plug(Plug.Parsers,
    parsers: [:multipart],
    pass: ["*/*"],
    body_reader: {Oasis.CacheRawBodyReader, :read_body, []}
  )

  plug(Oasis.Plug.RequestValidator,
    body_schema: %{
      "required" => true,
      "content" => %{
        "multipart/mixed" => %{
          "schema" =>
            JSONSchex.Schema.compile!(
              %{
                "properties" => %{
                  "id" => %{"type" => "string"},
                  "addresses" => %{
                    "type" => "array",
                    "items" => %{
                      "type" => "object",
                      "properties" => %{
                        "number" => %{"type" => "integer"},
                        "name" => %{"type" => "string"}
                      },
                      "required" => ["number", "name"]
                    }
                  }
                },
                "required" => ["id", "addresses"],
                "type" => "object"
              },
              format_assertion: true,
              content_assertion: false
            )
        },
        "multipart/form-data" => %{
          "schema" =>
            JSONSchex.Schema.compile!(
              %{
                "properties" => %{
                  "id" => %{"type" => "integer", "maximum" => 10},
                  "username" => %{"type" => "string"}
                },
                "required" => ["id", "username"],
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
