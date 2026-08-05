defmodule Oasis.Plug.RequestValidator do
  @moduledoc ~S"""
  A plug to convert types and validate the HTTP request parameters by the schemas of
  the OpenAPI definition.

  The schema options can be found in the generated `pre-` plug handler file, the full list:

    * `:query_schema`
    * `:header_schema`
    * `:cookie_schema`
    * `:body_schema`

  All of these options are fully map and generated from the corresponding definition of the OpenAPI Specification.

  When the query parameters are verified by the validation of `:query_schema`, the coverted types of query parameters
  are reserved in `:query_params` and `:params` field of the `Plug.Conn`.

  When the header parameters are verified by the validation of `:header_schema`, the converted types of header parameters
  are reserved in `:req_headers` field of the `Plug.Conn`.

  When the cookie parameters are verified by the validation of `:cookie_schema`, the coverted types of cookie parameters
  are reserved in `:req_cookies` field of the `Plug.Conn`.

  When the request body is verified by the validation of `:body_schema`, the coverted types of request body are reserved
  in `:body_params` and `:params` field of the `Plug.Conn`.

  ## Primitive JSON bodies

  Oasis follows Plug's default `nest_all_json: false` behavior: Plug wraps
  non-object JSON roots in a single `_json` key and leaves object roots as direct
  maps. That representation is otherwise indistinguishable from a literal JSON
  object whose only property is named `_json`, so Oasis only unwraps it when
  raw-body provenance proves that the wire value was not an object. Generated
  routers configure the required reader automatically. Handwritten pipelines
  that accept JSON bodies must configure `Plug.Parsers` in the same way and keep
  the default `nest_all_json: false` setting:

      plug Plug.Parsers,
        parsers: [:json],
        pass: ["*/*"],
        json_decoder: Jason,
        body_reader: {Oasis.CacheRawBodyReader, :read_body, []}

      plug Oasis.Plug.RequestValidator, body_schema: body_schema

  Without that provenance, Oasis deliberately keeps the `_json` map intact and
  fails closed rather than guessing from the schema and potentially accepting a
  literal object as a primitive value. An empty parsed map is also ambiguous—it
  may represent either an absent body or the JSON object `{}`—so Oasis returns
  an actionable 415 unless framing headers prove that bytes were present. After
  successful validation, primitive roots remain available as
  `conn.body_params["_json"]` so Plug's `body_params` and `params` fields stay
  map-shaped.
  """

  import Plug.Conn

  @behaviour Plug

  require Logger

  @plug_json_wrapper_key "_json"

  def init(opts), do: opts

  def call(conn, opts) do
    conn
    |> process_query(opts[:query_schema])
    |> process_header(opts[:header_schema])
    |> process_cookie(opts[:cookie_schema])
    |> process_body(opts[:body_schema])
  end

  defp process_query(conn, query_schema) when is_map(query_schema) do
    conn = fetch_query_params(conn)

    %{query_params: query_params, path_params: path_params, params: params} = conn

    query_params = parse_and_validate(query_schema, query_params, "query")

    params = params |> Map.merge(query_params) |> Map.merge(path_params)

    %{conn | query_params: query_params, params: params}
  end

  defp process_query(conn, _) do
    conn
  end

  defp process_header(conn, header_schema) when is_map(header_schema) do
    header_params = parse_and_validate(header_schema, Map.new(conn.req_headers), "header")

    %{conn | req_headers: Map.to_list(header_params)}
  end

  defp process_header(conn, _) do
    conn
  end

  defp process_cookie(conn, cookie_schema) when is_map(cookie_schema) do
    conn = fetch_cookies(conn)

    cookie_params = parse_and_validate(cookie_schema, conn.req_cookies, "cookie")

    %{conn | req_cookies: cookie_params}
  end

  defp process_cookie(conn, _) do
    conn
  end

  defp process_body(
         %{body_params: %Plug.Conn.Unfetched{}, req_headers: req_headers} = conn,
         body_schema
       )
       when is_map(body_schema) do
    content_type = find_content_type(req_headers)

    cond do
      content_type != nil ->
        case schema_may_match_by_request(content_type, body_schema) do
          nil -> unsupported_content_type!(content_type)
          _matched -> unparsed_body!(content_type)
        end

      request_body_indicated?(conn) ->
        unsupported_content_type!(nil)

      true ->
        ensure_body_requirement!(body_schema, false)
        conn
    end
  end

  defp process_body(%{body_params: body_params, params: params, req_headers: req_headers} = conn, body_schema)
       when is_map(body_schema) do
    if request_body_present?(conn, body_params) do
      content_type = find_content_type(req_headers)
      definition = schema_may_match_by_request(content_type, body_schema)

      if definition == nil or Oasis.MediaType.validation_kind(content_type) == :unsupported do
        unsupported_content_type!(content_type)
      end

      {value, wrapper_key} = request_body_value(conn, body_params, content_type)

      prepared =
        Oasis.Validator.parse_and_validate!(
          definition,
          "body",
          "body_request",
          value,
          present?: true
        )

      body_params = preserve_plug_body_params(prepared, wrapper_key)
      %{conn | body_params: body_params, params: Map.merge(params, body_params)}
    else
      ensure_body_requirement!(body_schema, false)
      conn
    end
  end

  defp process_body(conn, _body_schema), do: conn

  defp request_body_value(conn, %{"_json" => value} = wrapped, content_type)
       when map_size(wrapped) == 1 do
    if Oasis.MediaType.json?(content_type) and non_object_json_root?(conn) do
      {value, @plug_json_wrapper_key}
    else
      {wrapped, nil}
    end
  end

  defp request_body_value(_conn, body_params, _content_type), do: {body_params, nil}

  defp preserve_plug_body_params(prepared, @plug_json_wrapper_key),
    do: %{@plug_json_wrapper_key => prepared}

  defp preserve_plug_body_params(prepared, nil) when is_map(prepared), do: prepared
  defp preserve_plug_body_params(prepared, nil), do: %{@plug_json_wrapper_key => prepared}

  defp non_object_json_root?(%{assigns: %{raw_body: chunks}}) when is_list(chunks) do
    chunks
    |> Enum.reverse()
    |> IO.iodata_to_binary()
    |> String.trim_leading()
    |> case do
      "" -> false
      "{" <> _rest -> false
      _non_object_json -> true
    end
  end

  defp non_object_json_root?(_conn), do: false

  defp request_body_present?(%{assigns: %{raw_body: chunks}}, _body_params) when is_list(chunks) do
    IO.iodata_to_binary(chunks) != ""
  end

  defp request_body_present?(%{req_headers: req_headers} = conn, body_params) when body_params == %{} do
    if request_body_indicated?(conn) do
      true
    else
      case find_content_type(req_headers) do
        nil ->
          false
        content_type ->
          missing_body_provenance!(content_type)
      end
    end
  end

  # A fetched non-empty parsed value is present even when a handwritten parser
  # did not install the raw-body reader.
  defp request_body_present?(_conn, _body_params), do: true

  defp request_body_indicated?(conn) do
    positive_content_length? =
      conn
      |> get_req_header("content-length")
      |> Enum.any?(fn value ->
        case Integer.parse(value) do
          {length, ""} when length > 0 ->
            true
          _invalid_or_empty ->
            false
        end
      end)

    positive_content_length? or get_req_header(conn, "transfer-encoding") != []
  end

  defp ensure_body_requirement!(body_schema, present?) do
    Oasis.Validator.parse_and_validate!(
      body_schema,
      "body",
      "body_request",
      nil,
      present?: present?
    )
  end

  defp unsupported_content_type!(content_type) do
    raise Oasis.BadRequestError,
      error: %Oasis.BadRequestError.Invalid{value: content_type},
      use_in: "header",
      param_name: "content-type",
      plug_status: 415,
      message: "Unsupported request Content-Type: #{inspect(content_type)}"
  end

  defp unparsed_body!(content_type) do
    raise Oasis.BadRequestError,
      error: %Oasis.BadRequestError.Invalid{value: content_type},
      use_in: "body",
      param_name: "body_request",
      plug_status: 415,
      message:
        "Request body Content-Type #{inspect(content_type)} matched the OpenAPI definition but was not parsed; configure a compatible Plug.Parsers parser before Oasis.Plug.RequestValidator"
  end

  defp missing_body_provenance!(content_type) do
    raise Oasis.BadRequestError,
      error: %Oasis.BadRequestError.Invalid{value: content_type},
      use_in: "body",
      param_name: "body_request",
      plug_status: 415,
      message:
        "Could not distinguish an empty request body from an empty parsed object for Content-Type #{inspect(content_type)}; configure Oasis.CacheRawBodyReader as Plug.Parsers' body_reader"
  end

  defp parse_and_validate(schemas, input_params, use_in) when is_map(input_params) do
    Enum.reduce(schemas, input_params, fn {param_name, definition}, acc ->
      input_value = input_params[param_name]

      prepared_value =
        Oasis.Validator.parse_and_validate!(definition, use_in, param_name, input_value)

      if prepared_value == nil and input_value == nil do
        acc
      else
        Map.put(acc, param_name, prepared_value)
      end
    end)
  end

  defp find_content_type(req_headers) do
    case List.keyfind(req_headers, "content-type", 0) do
      {_, content} -> content
      nil -> nil
    end
  end

  defp schema_may_match_by_request(content_type, %{"content" => content} = definition)
       when is_binary(content_type) do
    case Oasis.MediaType.select(content, content_type) do
      {_media_range, media_type} -> %{definition | "content" => %{content_type => media_type}}
      nil -> nil
    end
  end

  defp schema_may_match_by_request(_content_type, _definition), do: nil
end
