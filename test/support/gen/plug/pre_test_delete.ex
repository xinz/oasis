defmodule Oasis.Gen.Plug.PreTestDelete do
  use Oasis.Controller
  use Plug.ErrorHandler
  use JSONSchex

  plug(
    Plug.Parsers,
    parsers: [:urlencoded],
    pass: ["*/*"]
  )

  plug(
    Oasis.Plug.RequestValidator,
    query_schema: %{
      "relation_ids" => %{
        "schema" => ~X|%{"type" => "array", "items" => %{"type" => "string"}}|,
        "required" => false
      },
      "id" => %{
        "schema" => ~X|%{"type" => "integer"}|,
        "required" => true
      }
    }
  )

  def call(conn, opts) do
    conn |> super(opts) |> Oasis.Gen.Plug.TestDelete.call(opts) |> halt()
  end

  defdelegate handle_errors(conn, error), to: Oasis.Gen.Plug.TestDelete
end
