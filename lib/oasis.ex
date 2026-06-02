defmodule Oasis do
  @moduledoc false

  defmodule InvalidSpecError do
    defexception message: "use some invalid specification to generate modules"

    @moduledoc """
    Error raised when use some invalid OpenAPI specification to generate corresponding modules.
    """
  end

  defmodule FileNotFoundError do
    defexception message: "failed to open file to generate modules"

    @moduledoc """
    Error raised when use an invalid file path to generate corresponding modules.
    """
  end

  defmodule BadRequestError do
    @moduledoc """
    Error raised when some reason could not process the request due to client error.
    """
    defexception message: "invalid request", use_in: nil, param_name: nil, error: nil, plug_status: 400

    defmodule Invalid do
      @moduledoc """
      This error is used to indicate could not parse a parameter into the type due to client error.
      """
      defstruct [:value]
    end

    defmodule Required do
      @moduledoc """
      This error is used to indicate there missing a required parameter due to client error.
      """
      defstruct([])
    end

    defmodule JSONSchemaValidationFailed do
      @moduledoc """
      Indicates that a request input failed JSON Schema validation.

      This struct wraps the underlying `JSONSchex.Types.Error` so detailed
      validation context is available to custom error handlers.

      ## Fields

      - `:error` - the underlying `t:JSONSchex.Types.Error.t/0`.
      - `:path` - a JSON Pointer string addressing the offending value inside the
        request payload, e.g. `"#/name"`. Pointer segments are escaped per
        RFC 6901 (`~` → `~0`, `/` → `~1`).

      Generated Oasis modules do not embed OpenAPI source metadata at runtime;
      the route/parameter context that produced this error is already available
      from `t:Plug.Conn.t/0` (`method`, `request_path`, `path_info`, headers) plus
      the surrounding `Oasis.BadRequestError`'s `:use_in` and `:param_name`
      fields. For generation-time source locations into the OpenAPI document,
      see `Mix.Oasis.Router`'s `:source_meta` field.
      """
      defstruct [:error, :path]
    end

    defmodule InvalidToken do
      @moduledoc """
      This error is used to indicate the provided token is expired, revoked, malformed, or invalid.
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
