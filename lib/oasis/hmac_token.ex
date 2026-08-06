defmodule Oasis.HMACToken do
  @moduledoc """
  ## Callback

  There are two callback functions reserved for use in the generated modules when we use the hmac security
  scheme of the OpenAPI Specification.

  * `c:crypto_config/3`, provides a way to define the crypto-related key information for the high level usage,
    it required to return a `#{inspect(__MODULE__)}.Crypto` struct (or nil).
  * `c:verify/3`, an optional function to provide a way to custom the verification of the token, you may
    want to validate request datetime, HTTP body or other more rules to verify it.


  ## Example

  Here is an example to verify that HTTP request time does not exceed the current time by 1 minute.

  ```elixir
  defmodule Oasis.Gen.HMACAuth do
    @behaviour Oasis.HMACToken
    alias Oasis.HMACToken.Crypto

    # in seconds
    @max_diff 60

    @impl true
    def crypto_config(_conn, _opts, _credential) do
      %Crypto{
        credential: "...",
        secret: "..."
      }
    end

    @impl true
    def verify(conn, token, opts) do
      with {:ok, _} <- Oasis.HMACToken.verify(conn, token, opts),
           {:ok, timestamp} <- conn |> get_header_date() |> parse_header_date() do
        timestamp_now = DateTime.utc_now() |> DateTime.to_unix()

        if abs(timestamp_now - timestamp) < @max_diff do
          {:ok, timestamp}
        else
          {:error, "expired"}
        end
      end
    end

    defp get_header_date(conn) do
      conn
      |> Plug.Conn.get_req_header("x-oasis-date")
      |> case do
        [date] -> date
        _ -> nil
      end
    end

    defp parse_header_date(str) when is_binary(str) do
      with {:ok, datetime, 0} <- DateTime.from_iso8601(str) do
        {:ok, DateTime.to_unix(datetime)}
      end
    end

    defp parse_header_date(_otherwise), do: {:error, "expired"}
  end
  ```
  """

  defmodule Crypto do
    @moduledoc """
    In general, when we define a hmac security scheme of the OpenAPI Specification,
    the generated module will use this struct to define the required crypto-related
    key information.
    """

    @enforce_keys [:credential, :secret]

    defstruct [
      :credential,
      :secret
    ]

    @type t :: %__MODULE__{
            credential: String.t(),
            secret: String.t()
          }
  end

  @type opts :: Plug.opts()

  @type token :: %{credential: String.t(), signed_headers: String.t(), signature: String.t()}

  @typedoc """
  String status code used in `verify_error()`.

  Allowed values are:

  - `"header_mismatch"`
  - `"invalid_credential"`
  - `"invalid_token"`
  - `"expired"`

  Elixir typespecs cannot enumerate string literals directly, so this remains
  `String.t()` at the type level and the fixed set is documented here.
  """
  @type verify_error_status :: String.t()

  @typedoc """
  Structured verification error returned by `verify/3`.

  The second tuple element is a fixed string status code rather than an atom.
  """
  @type verify_error :: {:error, verify_error_status()}

  @callback crypto_config(conn :: Plug.Conn.t(), opts :: Keyword.t(), credential :: String.t()) ::
              Crypto.t() | nil

  @callback verify(conn :: Plug.Conn.t(), token :: token(), opts :: opts()) ::
              {:ok, term()} | verify_error()

  @optional_callbacks verify: 3

  @doc """
  Default implementation of the callback `verify`, only verify the signature.

  Error statuses are normalized to strings for Oasis's public callback
  contract.
  """
  @spec verify(
          conn :: Plug.Conn.t(),
          token :: token(),
          opts :: Oasis.Plug.HMACAuth.opts()
        ) :: {:ok, term()} | verify_error()
  def verify(conn, token, opts) do
    algorithm = opts[:algorithm]
    signed_headers = opts[:signed_headers]

    with {:ok, crypto} <- load_crypto(conn, opts, token),
         signature <- sign(conn, signed_headers, crypto.secret, algorithm),
         {:ok, _} <- validate_signature(token, signature) do
      {:ok, token}
    end
  end

  @doc """
  Sign HTTP requests according to settings.
  """
  @spec sign(
          conn :: Plug.Conn.t(),
          signed_headers :: String.t(),
          secret :: String.t(),
          algorithm :: Oasis.Plug.HMACAuth.algorithm()
        ) :: String.t()
  def sign(conn, signed_headers, secret, algorithm) do
    method = conn.method |> to_string() |> String.upcase()
    path_and_query = build_path_and_query(conn.request_path, conn.query_string)

    signed_header_values = values_of_req_headers(conn, signed_headers)

    string_to_sign =
      method
      |> Kernel.<>("\n")
      |> Kernel.<>(path_and_query)
      |> Kernel.<>("\n")
      |> Kernel.<>(signed_header_values)

    Base.encode64(:crypto.mac(:hmac, algorithm, secret, string_to_sign))
  end

  defp values_of_req_headers(%Plug.Conn{req_headers: req_headers} = conn, signed_headers) when is_binary(signed_headers) do
    signed_headers
    |> String.split(";")
    |> Enum.reduce([], fn
      "host", acc ->
        [conn.host | acc]
      header, acc ->
        case List.keyfind(req_headers, header, 0) do
          nil -> acc
          {_header, value} -> [value | acc]
        end
    end)
    |> Enum.reverse()
    |> Enum.join(";")
  end

  defp build_path_and_query(path, ""), do: path
  defp build_path_and_query(path, query), do: path <> "?" <> query

  defp load_crypto(conn, opts, token) do
    security = opts[:security]

    security.crypto_config(conn, opts, token.credential)
    |> case do
      nil -> {:error, "invalid_credential"}
      crypto -> {:ok, crypto}
    end
  end

  defp validate_signature(token, signature) do
    if token.signature == signature do
      {:ok, token}
    else
      {:error, "invalid_token"}
    end
  end
end
