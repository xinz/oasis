defmodule Oasis.Gen.Plug.TestDelete do
  use Oasis.Controller

  alias Oasis.BadRequestError

  def init(opts), do: opts

  def call(conn, _opts) do
    json(
      conn,
      %{
        "conn_params" => conn.params,
        "query_params" => conn.query_params,
        "body_params" => conn.body_params
      }
    )
  end

  def handle_errors(conn, %{kind: _kind, reason: %BadRequestError{error: %BadRequestError.JSONSchemaValidationFailed{} = _json_schema} = reason, stack: _stack}) do
    message = String.replace_prefix(reason.message, "Failed to validate JSON schema with an error: ", "")
    message = "Find #{reason.use_in} parameter `#{reason.param_name}` with error: #{message}"
    send_resp(conn, conn.status, message)
  end
  def handle_errors(conn, %{kind: _kind, reason: reason, stack: _stack}) do
    message = Map.get(reason, :message) || "Something went wrong"
    send_resp(conn, conn.status, message)
  end
end
