defmodule Oasis do
  @moduledoc false

  defmodule InvalidSpecError do
    defexception message: "used an invalid specification while generating modules"

    @moduledoc """
    Error raised when an invalid OpenAPI specification is used to generate modules.
    """
  end

  defmodule FileNotFoundError do
    defexception message: "failed to open file while generating modules"

    @moduledoc """
    Error raised when an invalid file path is used to generate modules.
    """
  end

  defmodule BadRequestError do
    @moduledoc """
    Error raised when a request cannot be processed because of client input.
    """
    defexception message: "invalid request",
                 use_in: nil,
                 param_name: nil,
                 error: nil,
                 plug_status: 400

    defmodule Invalid do
      @moduledoc """
      Indicates that a parameter could not be parsed into the expected type because of client input.
      """
      defstruct [:value]
    end

    defmodule Required do
      @moduledoc """
      Indicates that a required parameter is missing because of client input.
      """
      defstruct([])
    end

    defmodule JsonSchemaValidationFailed do
      @moduledoc """
      Indicates that input did not pass validation against the configured JSON Schema.

      The `:error` field contains a `JSONSchex.Types.Error` value from the configured JSON Schema
      validator.
      """
      defstruct [:error, :path]
    end

    defmodule InvalidToken do
      @moduledoc """
      Indicates that the provided token is expired, revoked, malformed, or otherwise invalid.
      """
      defstruct([])
    end
  end

  defmodule CacheRawBodyReader do
    @moduledoc false

    def read_body(conn, opts) do
      {:ok, body, conn} = Plug.Conn.read_body(conn, opts)
      conn = update_in(conn.assigns[:raw_body], &[body | &1 || []])
      {:ok, body, conn}
    end
  end
end
