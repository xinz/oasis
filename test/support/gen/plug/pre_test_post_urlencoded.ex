defmodule Oasis.Gen.Plug.PreTestPostUrlencoded do
  # NOTICE: Please DO NOT write any business code in this module, since it will always be overridden when
  # run `mix oas.gen.plug` task command with the OpenAPI Specification file.
  use Oasis.Controller
  use Plug.ErrorHandler
  require JSONSchex.Schema

  plug(Plug.Parsers,
    parsers: [:urlencoded],
    pass: ["*/*"],
    body_reader: {Oasis.CacheRawBodyReader, :read_body, []}
  )

  plug(Oasis.Plug.RequestValidator,
    body_schema: %{
      "required" => true,
      "content" => %{
        "application/x-www-form-urlencoded" => %{
          "schema" =>
            JSONSchex.Schema.compile!(
              %{
                "properties" => %{
                  "name" => %{"type" => "string"},
                  "fav_number" => %{"type" => "integer", "minimum" => 1, "maximum" => 3}
                },
                "required" => ["name", "fav_number"],
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
