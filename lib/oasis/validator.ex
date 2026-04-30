defmodule Oasis.Validator do
  @moduledoc false

  alias Oasis.{BadRequestError, JSONSchema}

  @spec parse_and_validate!(
          param :: map() | nil,
          use_in :: String.t(),
          name :: String.t(),
          value :: term()
        ) :: term()
  def parse_and_validate!(%{"schema" => _schema} = definition, use_in, name, value) do
    definition
    |> prepare()
    |> check_required!(use_in, name, value)
    |> process()
  end

  def parse_and_validate!(%{"content" => _content} = definition, use_in, name, value) do
    definition
    |> prepare()
    |> check_required!(use_in, name, value)
    |> process()
  end

  def parse_and_validate!(_, _, _, value) do
    value
  end

  defp prepare(definition) when is_map(definition) do
    required = if definition["required"] == true, do: true, else: false

    Map.put(definition, "required", required)
  end

  defp check_required!(%{"required" => true}, use_in, param_name, nil) do
    raise BadRequestError,
      error: %BadRequestError.Required{},
      use_in: use_in,
      param_name: param_name,
      message: "Missing a required parameter"
  end

  defp check_required!(definition, use_in, name, value) do
    {definition, use_in, name, value}
  end

  defp process({_, _use_in, _name, nil}) do
    nil
  end

  defp process({%{"schema" => json_schema_root}, use_in, name, value}) do
    do_parse_and_validate!(json_schema_root, use_in, name, value)
  end

  defp process({%{"content" => content}, use_in, name, value}) do
    [{content_type, media_type} | _] = Map.to_list(content)

    content_type
    |> String.downcase()
    |> process_media_type(media_type, use_in, name, value)
  end

  defp do_parse_and_validate!(json_schema_root, "body", param_name, %{"_json" => value} = wrapped_value) do
    if unwrap_json_body?(json_schema_root, value) do
      # Since `Plug.Parsers.JSON` parses a non-map body content into a "_json" key to allow proper param merging, here
      # will unwrap the "_json" key and format the input body params as a matched type to the defined OpenAPI specification.
      do_parse_and_validate!(json_schema_root, "body", param_name, value)
    else
      do_parse_and_validate_value!(json_schema_root, "body", param_name, wrapped_value)
    end
  end

  defp do_parse_and_validate!(json_schema_root, use_in, param_name, value) do
    do_parse_and_validate_value!(json_schema_root, use_in, param_name, value)
  end

  defp do_parse_and_validate_value!(json_schema_root, use_in, param_name, value) do
    schema = JSONSchema.raw_schema(json_schema_root)

    try do
      Oasis.Parser.parse(schema, value)
    rescue
      ArgumentError ->
        raise BadRequestError,
          error: %BadRequestError.Invalid{value: value},
          use_in: use_in,
          param_name: param_name,
          message: "Failed to convert parameter"

    else
      parsed ->

        result =
          json_schema_root
          |> json_schema_validate(parsed)
          |> recheck_after_validate()

        case result do
          {:ok, ^parsed} ->
            parsed

          {:error, %JSONSchex.Types.Error{} = error} ->
            raise BadRequestError,
              error: %BadRequestError.JsonSchemaValidationFailed{
                error: error,
                path: JSONSchema.path_pointer(error)
              },
              use_in: use_in,
              param_name: param_name,
              message: "Failed to validate JSON schema with an error: #{JSONSchema.format_error(error)}"
        end
    end
  end

  defp unwrap_json_body?(json_schema_root, value) do
    case JSONSchema.raw_schema(json_schema_root) do
      %{"type" => "string"} -> is_bitstring(value)
      %{"type" => "number"} -> is_number(value)
      %{"type" => "integer"} -> is_integer(value)
      %{"type" => "array"} -> is_list(value)
      %{"type" => "boolean"} -> is_boolean(value)
      _ -> false
    end
  end

  defp json_schema_validate(json_schema_root, parsed) do
    {JSONSchema.validate(json_schema_root, parsed), parsed}
  end

  defp recheck_after_validate({:ok, parsed}), do: {:ok, parsed}

  defp recheck_after_validate({{:error, errors}, parsed}) do
    errors =
      errors
      |> Enum.filter(&error_to_attention?(&1, parsed))
      |> Enum.sort_by(fn error -> {List.wrap(error.path), error_priority(error.rule)} end)

    case errors do
      [] ->
        {:ok, parsed}

      [error | _] ->
        {:error, error}
    end
  end

  defp error_to_attention?(%JSONSchex.Types.Error{} = error, parsed) do
    not ignore_upload_error?(error, parsed)
  end

  defp error_to_attention?(_error, _parsed), do: true

  defp ignore_upload_error?(%JSONSchex.Types.Error{rule: :type, path: path, context: context}, parsed) do
    case value_in_path(List.wrap(path), parsed) do
      %Plug.Upload{} ->
        # ignore `Plug.Upload` failed in json schema validation
        Map.get(context, :contrast) == "string" and Map.get(context, :input) in ["object", "map"]

      _ ->
        false
    end
  end

  defp ignore_upload_error?(_error, _parsed), do: false

  defp error_priority(:type), do: 0
  defp error_priority(:required), do: 1
  defp error_priority(:dependentRequired), do: 1
  defp error_priority(_rule), do: 9

  defp value_in_path([], parsed), do: parsed

  defp value_in_path([segment | rest], parsed) when is_map(parsed) do
    value_in_path(rest, Map.get(parsed, segment))
  end

  defp value_in_path([segment | rest], parsed) when is_list(parsed) and is_integer(segment) do
    value_in_path(rest, Enum.at(parsed, segment))
  end

  defp value_in_path(_path, _parsed), do: nil

  defp process_media_type(
         "text/plain" <> _charset,
         %{"schema" => json_schema_root},
         use_in,
         name,
         value
       ) do
    do_parse_and_validate!(json_schema_root, use_in, name, value)
  end

  defp process_media_type(
         "application/json" <> _charset,
         %{"schema" => json_schema_root},
         use_in,
         name,
         value
       ) do
    do_parse_and_validate!(json_schema_root, use_in, name, value)
  end

  defp process_media_type(
         "application/x-www-form-urlencoded" <> _charset,
         %{"schema" => json_schema_root},
         use_in,
         name,
         value
       ) do
    do_parse_and_validate!(json_schema_root, use_in, name, value)
  end

  defp process_media_type(
         "multipart/form-data" <> _boundary,
         %{"schema" => json_schema_root},
         use_in,
         name,
         value
       ) do
    do_parse_and_validate!(json_schema_root, use_in, name, value)
  end

  defp process_media_type(
         "multipart/mixed" <> _boundary,
         %{"schema" => json_schema_root},
         use_in,
         name,
         value
       ) do
    do_parse_and_validate!(json_schema_root, use_in, name, value)
  end

  defp process_media_type(
         "application/" <> subtype,
         %{"schema" => json_schema_root},
         use_in,
         name,
         value
       ) do
    if String.ends_with?(subtype, "+json") do
      do_parse_and_validate!(json_schema_root, use_in, name, value)
    else
      value
    end
  end

  defp process_media_type(_content_type, _schema, _use_in, _name, value) do
    value
  end

end
