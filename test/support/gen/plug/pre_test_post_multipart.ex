defmodule Oasis.Gen.Plug.PreTestPostMultipart do
  use Oasis.Controller
  use Plug.ErrorHandler
  use JSONSchex

  plug(
    Plug.Parsers,
    parsers: [:multipart],
    pass: ["*/*"]
  )

  plug(
    Oasis.Plug.RequestValidator,
    body_schema: %{
      "required" => true,
      "content" => %{
        "multipart/mixed" => %{
          "schema" => ~X"""
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
          }
          """
        },
        "multipart/form-data" => %{
          "schema" => ~X"""
          %{
            "properties" => %{
              "id" => %{"type" => "integer", "maximum" => 10},
              "username" => %{"type" => "string"}
            },
            "required" => ["id", "username"],
            "type" => "object"
          }
          """
        }
      }
    }
  )

  def call(conn, opts) do
    conn |> super(opts) |> Oasis.Gen.Plug.TestPost.call(opts) |> halt()
  end

  defdelegate handle_errors(conn, error), to: Oasis.Gen.Plug.TestPost
end
