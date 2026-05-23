defmodule Oasis.Gen.Plug.PreTestHeader do
    use Oasis.Controller
  use Plug.ErrorHandler

  plug(Oasis.Plug.RequestValidator,
    header_schema: %{
      "items" => %{
        "required" => true,
        "schema" =>
          Oasis.Test.JSONSchema.compile!(%{"items" => %{"type" => "integer"}, "type" => "array"})
      }
    }
  )

  def call(conn, opts) do
    conn |> super(opts) |> Oasis.Gen.Plug.TestHeader.call(opts) |> halt()
  end

  defdelegate handle_errors(conn, error), to: Oasis.Gen.Plug.TestHeader
end
