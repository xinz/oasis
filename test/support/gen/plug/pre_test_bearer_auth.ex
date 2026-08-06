defmodule Oasis.Gen.Plug.PreTestBearerAuth do
  # NOTICE: Please DO NOT write any business code in this module, since it will always be overridden when
  # run `mix oas.gen.plug` task command with the OpenAPI Specification file.
  use Oasis.Controller
  use Plug.ErrorHandler
  require JSONSchex.Schema

  plug(Oasis.Plug.RequestValidator,
    query_schema: %{
      "max_age" => %{
        "schema" =>
          JSONSchex.Schema.compile!(
            %{"type" => "integer"},
            format_assertion: true,
            content_assertion: false
          ),
        "required" => false
      }
    }
  )

  plug(Oasis.Plug.BearerAuth, security: Oasis.Gen.BearerAuth, key_to_assigns: :id)

  def call(conn, opts) do
    conn |> super(opts) |> Oasis.Gen.Plug.TestBearerAuth.call(opts) |> halt()
  end

  defdelegate handle_errors(conn, error), to: Oasis.Gen.Plug.TestBearerAuth
end
