defmodule Oasis.Gen.Plug.PreTestDelete do
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
    query_schema: %{
      "relation_ids" => %{
        "schema" =>
          JSONSchex.Schema.compile!(
            %{"type" => "array", "items" => %{"type" => "string"}},
            format_assertion: true,
            content_assertion: false
          ),
        "required" => false
      },
      "id" => %{
        "schema" =>
          JSONSchex.Schema.compile!(
            %{"type" => "integer"},
            format_assertion: true,
            content_assertion: false
          ),
        "required" => true
      }
    }
  )

  def call(conn, opts) do
    conn |> super(opts) |> Oasis.Gen.Plug.TestDelete.call(opts) |> halt()
  end

  defdelegate handle_errors(conn, error), to: Oasis.Gen.Plug.TestDelete
end
