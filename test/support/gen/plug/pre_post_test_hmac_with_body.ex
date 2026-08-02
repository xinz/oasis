defmodule Oasis.Gen.Plug.PrePostTestHMACWithBody do
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
      "content" => %{
        "application/json" => %{
          "schema" =>
            JSONSchex.Schema.compile!(
              %{"properties" => %{"a" => %{"type" => "string"}}, "type" => "object"},
              format_assertion: true,
              content_assertion: false
            )
        }
      }
    }
  )

  plug(Oasis.Plug.HMACAuth,
    signed_headers: "host;x-oasis-body-sha256",
    algorithm: :sha256,
    security: Oasis.Gen.HMACAuthWithBody
  )

  def call(conn, opts) do
    conn |> super(opts) |> Oasis.Gen.Plug.PostTestHMACWithBody.call(opts) |> halt()
  end

  defdelegate handle_errors(conn, error), to: Oasis.Gen.Plug.PostTestHMACWithBody
end
