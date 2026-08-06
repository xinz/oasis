defmodule Oasis.Gen.Plug.PreTestQuery do
  # NOTICE: Please DO NOT write any business code in this module, since it will always be overridden when
  # run `mix oas.gen.plug` task command with the OpenAPI Specification file.
  use Oasis.Controller
  use Plug.ErrorHandler
  require JSONSchex.Schema

  plug(Oasis.Plug.RequestValidator,
    query_schema: %{
      "profile" => %{
        "content" => %{
          "application/json" => %{
            "schema" =>
              JSONSchex.Schema.compile!(
                %{
                  "properties" => %{
                    "name" => %{"type" => "string"},
                    "tag" => %{"type" => "integer"}
                  },
                  "required" => ["name", "tag"],
                  "type" => "object"
                },
                format_assertion: true,
                content_assertion: false
              )
          }
        },
        "required" => false
      },
      "lang" => %{
        "schema" =>
          JSONSchex.Schema.compile!(
            %{"type" => "integer", "minimum" => 10, "maximum" => 20},
            format_assertion: true,
            content_assertion: false
          ),
        "required" => true
      },
      "all" => %{
        "schema" =>
          JSONSchex.Schema.compile!(
            %{"type" => "boolean"},
            format_assertion: true,
            content_assertion: false
          ),
        "required" => false
      }
    }
  )

  def call(conn, opts) do
    conn |> super(opts) |> Oasis.Gen.Plug.TestQuery.call(opts) |> halt()
  end

  defdelegate handle_errors(conn, error), to: Oasis.Gen.Plug.TestQuery
end
