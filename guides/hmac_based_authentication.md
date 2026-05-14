# HMAC-based Authentication

## Background

*STATEMENT*: Currently there is no standard HMAC authentication definition in the OpenAPI v3.1.0 specification.
Oasis adds an `hmac-<algorithm>` value as the corresponding `scheme` field for an HTTP security scheme object in a YAML or JSON specification.
These public HMAC service designs are useful references:

  * [Azure REST API Authentication HMAC](https://docs.microsoft.com/en-us/azure/azure-app-configuration/rest-api-authentication-hmac)
  * [AWS S3 sigv4 Authentication](https://docs.aws.amazon.com/AmazonS3/latest/API/sigv4-auth-using-authorization-header.html)
  * [AWS general sigv4 Authentication example](https://docs.aws.amazon.com/general/latest/gr/sigv4-signed-request-examples.html)

We need a mechanism based on the [HTTP Authorization Header](https://developer.mozilla.org/en-US/docs/Web/HTTP/Headers/Authorization)
to authenticate access permissions and meet the following requirements:

1. Make sure that the request is from a trusted client.
2. Make sure that some key HTTP headers are not tampered with.
3. *(Optional)* Make sure that the HTTP body is not tampered.
4. *(Optional)* Make sure that the interval between the request send-time and the server received-time does not exceed a certain critical value.

Oasis provides a complete set of scaffolding to make this kind of authentication service easier to build.

## Protocol

In production, HTTP requests should be sent over `TLS/SSL`.

### HTTP Authorization Header

The client request must contain an `Authorization` HTTP header in this syntax:

    Authorization: HMAC-<Algorithm> Credential=<value1>&SignedHeaders=<value2>&Signature=<value3>

* `<Algorithm>`, the algorithm name (in uppercase, for example `SHA256`) used to compute an HMAC. For supported algorithms,
  see [here](Oasis.Plug.HMACAuth.html#module-supported-algorithms).
* `Credential`, the access key ID used by the server to identify the client.
* `SignedHeaders`, the HTTP header names separated by semicolons (`;`). The values of these headers are included in the signature in your defined order.
  These headers must also be present in the request, and header names should not contain spaces.
* `Signature`, the base64-encoded HMAC digest computed from the `String-to-Sign` and the secret associated with `Credential`.

The `String-to-Sign` is built like this:

*String-to-Sign* =
  *HTTP_METHOD* + "\n" +
  *path_and_query_string* + "\n" +
  *values_of_signed_headers*

| Variable | Description |
| --- | --- |
| *HTTP_METHOD* | The HTTP method of the request in uppercase, e.g. "POST" |
| *path_and_query_string* | The absolute URI with query string (if present) of the request, e.g. "/foo/bar?a=1" |
| *values_of_signed_headers* | The values of all HTTP request headers listed in `SignedHeaders`, use semicolons(`;`) to separate the values in order of `SignedHeaders`. |

Example:

    String-to-Sign =
        "POST" + "\n" +
        "/new?version=1" + "\n" +
        "2021-11-24 06:43:20.393420Z;foo.bar.host;{\"name\":\"test\",\"type\":1}"

Let's take this pair of access key for example:

Access Key ID | Access Key Secret
----- | -----
*mykey_abc* | *123456789*

Notice: the access key secret should be known only to the client and server, and it must not be transmitted in plaintext.

The corresponding HTTP headers of the request are:

    Host: foo.bar.host
    Date: 2021-11-24 06:43:20.393420Z
    Authorization: HMAC-SHA256 Credential=mykey_abc&SignedHeaders=date;host;body&Signature=oSBomxpJWcwlhVkif5LV80zecDLpts9Z13+cth1NKV4=
    Body: "{\"name\":\"test\",\"type\":1}"

As a best practice, try to include the dynamic parts of the request in the signature.

The way to concatenate the `String-To-Sign` is fixed, but you can flexibly choose which HTTP headers to sign through the `SignedHeaders` field.
Keep the values of the signed headers available for server-side verification. For example:

    x-oasis-content-sha256: base64_encode(SHA256(body))
    x-oasis-content-md5: base64_encode(MD5(body))

## Tutorial

### 1. Define schema in OpenAPI Specification

```yaml
# priv/oas/main.yaml

openapi: "3.1.0"
info:
  title: My API Title
  version: "1.0"
paths:
  /test_hmac:
    post:
      # this API (/test_hmac) should be authenticated by HMAC-based Authentication
      security:
        - HMACAuth: [ ]
      requestBody:
        content:
          application/json:
            schema:
              type: object
              properties:
                a:
                  type: string
      responses:
        "200":
          description: OK
  /other:
    get:
      # and this API will not be authenticated
      responses:
        "200":
          description: OK
    
components:
  securitySchemes:
    HMACAuth:
      type: http
      # will use hmac hash sha256 algorithm
      scheme: hmac-sha256
      # will verify host, request datetime and body hash
      x-oasis-signed-headers: host;x-oasis-date;x-oasis-body-sha256
```

The `x-oasis-signed-headers` field is a specification extension that defines which HTTP headers are included in the signature.

Some HTTP client libraries do not let you set the HTTP `Date` header. In that case, you can define an arbitrary header name (it should start with `x-`) to represent date-related information. In the example above, that header is `x-oasis-date`.

In the same example, `x-oasis-body-sha256` is a custom HTTP header field. You can choose another arbitrary name as long as it starts with `x-`.

### 2. Generate Code

```shell
# in the shell
mix oas.gen.plug --file priv/oas/main.yaml
```

Then you will get generated files similar to these:

```elixir
# lib/oasis/gen/pre_post_test_hmac.ex
defmodule Oasis.Gen.PrePostTestHMAC do
  # NOTICE: Do not write business code in this module. It is always overwritten when
  # `mix oas.gen.plug` runs with the OpenAPI specification file.
  use Oasis.Controller
  use Plug.ErrorHandler
  require JSONSchex.Schema

  plug(
    Plug.Parsers,
    parsers: [:json],
    json_decoder: Oasis.JSON,
    pass: ["*/*"],
    body_reader: {Oasis.CacheRawBodyReader, :read_body, []}
  )

  plug(
    Oasis.Plug.RequestValidator,
    body_schema: %{
      "content" => %{
        "application/json" => %{
          "schema" =>
            JSONSchex.Schema.compile!(
              %{
                "properties" => %{"a" => %{"type" => "string"}},
                "type" => "object"
              },
              format_assertion: true,
              content_assertion: false
            )
        }
      }
    }
  )

  plug(
    Oasis.Plug.HMACAuth,
    signed_headers: "host;x-oasis-date;x-oasis-body-sha256",
    algorithm: :sha256,
    security: Oasis.Gen.HMACAuth
  )

  def call(conn, opts) do
    conn |> super(opts) |> Oasis.Gen.PostTestHMACWithBody.call(opts) |> halt()
  end

  defdelegate handle_errors(conn, error), to: Oasis.Gen.PostTestHMACWithBody
end
```

```elixir
# lib/oasis/gen/hmac_auth.ex
defmodule Oasis.Gen.HMACAuth do
  # NOTICE: This module is generated the first time `mix oas.gen.plug` runs with the OpenAPI specification file.
  # After this file exists, future generation commands do not modify it,
  # so write the crypto-related configuration in this module.
  @behaviour Oasis.HMACToken
  alias Oasis.HMACToken.Crypto

  @impl true
  def crypto_config(_conn, _opts, _credential) do
    # ...
    nil
  end

  @impl true
  def verify(conn, token, opts) do
    with {:ok, _} <- Oasis.HMACToken.verify(conn, token, opts) do
      {:ok, token}
    end
  end
end
```

### 3. Implement your `crypto_config/3` and `verify/3` callbacks.

```elixir
# lib/oasis/gen/hmac_auth.ex
defmodule Oasis.Gen.HMACAuth do
  # NOTICE: This module is generated the first time `mix oas.gen.plug` runs with the OpenAPI specification file.
  # After this file exists, future generation commands do not modify it,
  # so write the crypto-related configuration in this module.
  @behaviour Oasis.HMACToken
  alias Oasis.HMACToken.Crypto

  # in seconds
  @max_diff 60

  @impl true
  def crypto_config(_conn, _opts, _credential) do
    # This is only an example.
    # You should provide these sensitive values from configuration or a database.
    %Crypto{
      credential: "mykey_abc",
      secret: "123456789"
    }
  end

  @impl true
  def verify(conn, token, opts) do
    with {:ok, _} <- Oasis.HMACToken.verify(conn, token, opts),
         {:ok, _} <- verify_date(conn, token, opts),
         {:ok, _} <- verify_body(conn, token, opts) do
      {:ok, token}
    end
  end

  defp verify_date(conn, _token, _opts) do
    with {:ok, timestamp} <- conn |> get_header("x-oasis-date") |> parse_header_date() do
      timestamp_now = DateTime.utc_now() |> DateTime.to_unix()

      if abs(timestamp_now - timestamp) < @max_diff do
        {:ok, timestamp}
      else
        {:error, :expired}
      end
    end
  end

  defp verify_body(conn, token, opts) do
    algorithm = opts[:algorithm]
    raw_body = conn.assigns.raw_body
    crypto = crypto_config(conn, opts, token.credential)
    body_hmac = hmac(algorithm, crypto.secret, raw_body)
    body_hmac_header = get_header(conn, "x-oasis-body-sha256")

    if body_hmac == body_hmac_header do
      {:ok, token}
    else
      {:error, :invalid_token}
    end
  end

  defp get_header(conn, key) do
    conn
    |> Plug.Conn.get_req_header(key)
    |> case do
      [value] -> value
      _ -> nil
    end
  end

  defp parse_header_date(str) when is_binary(str) do
    with {:ok, datetime} <- Timex.parse(str, "%a, %d %b %Y %H:%M:%S GMT", :strftime),
         timestamp when is_integer(timestamp) <- Timex.to_unix(datetime) do
      {:ok, timestamp}
    end
  end

  defp parse_header_date(_otherwise), do: {:error, :expired}

  defp hmac(subtype, secret, content) do
    Base.encode64(:crypto.mac(:hmac, subtype, secret, content))
  end
end
```
