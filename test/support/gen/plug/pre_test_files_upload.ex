defmodule Oasis.Gen.Plug.PreTestFilesUpload do
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
      "content" => %{
        "multipart/form-data" => %{
          "schema" =>
            JSONSchex.Schema.compile!(
              %{
                "properties" => %{
                  "file" => %{
                    "items" => %{"format" => "binary", "type" => "string"},
                    "type" => "array"
                  },
                  "logo" => %{"format" => "binary", "type" => "string"},
                  "id" => %{"maximum" => 10, "type" => "integer"}
                }
              },
              format_assertion: true,
              content_assertion: false
            )
        }
      }
    }
  )

  def call(conn, opts) do
    conn |> super(opts) |> Oasis.Gen.Plug.TestFilesUpload.call(opts) |> halt()
  end

  defdelegate handle_errors(conn, error), to: Oasis.Gen.Plug.TestFilesUpload
end
