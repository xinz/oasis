defmodule Oasis.Gen.Plug.TestFilesUpload do
  use Oasis.Controller

  alias Oasis.BadRequestError

  def init(opts), do: opts

  def call(conn, _opts) do
    with_logo =
      case conn.body_params["logo"] do
        %Plug.Upload{} -> true
        _ -> false
      end

    json(
      conn,
      %{
        "uploaded" => length(conn.body_params["file"] || []),
        "with_logo" => with_logo
      }
    )
  end

  def handle_errors(conn, %{kind: _kind, reason: %BadRequestError{error: %BadRequestError.JSONSchemaValidationFailed{} = _json_schema} = reason, stack: _stack}) do
    message = String.replace_prefix(reason.message, "Failed to validate JSON schema with an error: ", "")
    message = "Find #{reason.use_in} parameter `#{reason.param_name}` with error: #{message}"
    send_resp(conn, conn.status, message)
  end
end
