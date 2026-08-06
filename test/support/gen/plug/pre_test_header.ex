defmodule Oasis.Gen.Plug.PreTestHeader do
  # NOTICE: Please DO NOT write any business code in this module, since it will always be overridden when
  # run `mix oas.gen.plug` task command with the OpenAPI Specification file.
  use Oasis.Controller
  use Plug.ErrorHandler
  require JSONSchex.Schema

  plug(Oasis.Plug.RequestValidator,
    header_schema: %{
      "items" => %{
        "required" => true,
        "schema" =>
          JSONSchex.Schema.compile!(
            %{"items" => %{"type" => "integer"}, "type" => "array"},
            format_assertion: true,
            content_assertion: false
          )
      }
    }
  )

  def call(conn, opts) do
    conn |> super(opts) |> Oasis.Gen.Plug.TestHeader.call(opts) |> halt()
  end

  defdelegate handle_errors(conn, error), to: Oasis.Gen.Plug.TestHeader
end
