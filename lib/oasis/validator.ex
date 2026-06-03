defmodule Oasis.Validator do
  @moduledoc false

  alias Oasis.BadRequestError

  @spec parse_and_validate!(
          param :: map() | nil,
          use_in :: String.t(),
          name :: String.t(),
          value :: term()
        ) :: term()
  def parse_and_validate!(%{"schema" => _schema} = definition, use_in, name, value) do
    definition
    |> check_required!(use_in, name, value)
    |> process()
  end

  def parse_and_validate!(%{"content" => _content} = definition, use_in, name, value) do
    definition
    |> check_required!(use_in, name, value)
    |> process()
  end

  def parse_and_validate!(_, _, _, value) do
    value
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

  defp do_parse_and_validate!(
         %JSONSchex.Types.Schema{raw: raw_schema} = json_schema_root,
         "body",
         param_name,
         %{"_json" => value} = wrapped_value
       ) do
    if unwrap_json_body?(raw_schema, value) do
      # Since `Plug.Parsers.JSON` parses a non-map body content into a "_json" key to allow proper param merging, here
      # will unwrap the "_json" key and format the input body params as a matched type to the defined OpenAPI specification.
      do_parse_and_validate!(json_schema_root, "body", param_name, value)
    else
      do_parse_and_validate_value!(json_schema_root, "body", param_name, wrapped_value)
    end
  end

  defp do_parse_and_validate!(%JSONSchex.Types.Schema{} = json_schema_root, use_in, param_name, value) do
    do_parse_and_validate_value!(json_schema_root, use_in, param_name, value)
  end

  defp do_parse_and_validate_value!(%JSONSchex.Types.Schema{raw: schema} = json_schema_root, use_in, param_name, value) do
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
              error: %BadRequestError.JSONSchemaValidationFailed{error: error, path: path_pointer(error)},
              use_in: use_in,
              param_name: param_name,
              message: "Failed to validate JSON schema with an error: #{format_error(error)}"
        end
    end
  end

  defp unwrap_json_body?(%{"type" => "string"}, value), do: is_bitstring(value)
  defp unwrap_json_body?(%{"type" => "number"}, value), do: is_number(value)
  defp unwrap_json_body?(%{"type" => "integer"}, value), do: is_integer(value)
  defp unwrap_json_body?(%{"type" => "array"}, value), do: is_list(value)
  defp unwrap_json_body?(%{"type" => "boolean"}, value), do: is_boolean(value)
  defp unwrap_json_body?(_raw_schema, _value), do: false

  defp json_schema_validate(%JSONSchex.Types.Schema{raw: raw_schema} = json_schema_root, parsed) do
    result =
      case JSONSchex.validate(json_schema_root, parsed) do
        :ok -> strict_format_validate(raw_schema, parsed)
        {:error, _errors} = error -> error
      end

    {result, parsed}
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

  defp error_to_attention?(%JSONSchex.Types.Error{rule: :type, path: path, context: context}, parsed) do
    case value_in_path(List.wrap(path), parsed) do
      %Plug.Upload{} ->
        # ignore `Plug.Upload` failed in json schema validation
        Map.get(context || %{}, :contrast) != "string"

      _ ->
        true
    end
  end

  defp error_to_attention?(_error, _parsed), do: true

  defp error_priority(:type), do: 0
  defp error_priority(:required), do: 1
  defp error_priority(:dependentRequired), do: 1
  defp error_priority(_rule), do: 9

  defp strict_format_validate(%{"format" => "email"}, value) when is_binary(value) do
    if Regex.match?(~r/^[^@\s]+@[^@\s]+\.[^@\s]+$/, value) do
      :ok
    else
      {:error,
       [
         %JSONSchex.Types.Error{
           path: [],
           rule: :format,
           context: %JSONSchex.Types.ErrorContext{contrast: "email", input: value},
           value: value
         }
       ]}
    end
  end

  defp strict_format_validate(_schema, _value), do: :ok

  defp value_in_path([], parsed), do: parsed

  defp value_in_path([segment | rest], parsed) when is_map(parsed) do
    value_in_path(rest, Map.get(parsed, segment))
  end

  defp value_in_path([segment | rest], parsed) when is_list(parsed) and is_integer(segment) do
    value_in_path(rest, Enum.at(parsed, segment))
  end

  defp value_in_path(_path, _parsed), do: nil

  defp format_error(%JSONSchex.Types.Error{rule: :minimum, context: %{contrast: minimum}}) do
    "Expected the value to be >= #{minimum}"
  end

  defp format_error(%JSONSchex.Types.Error{rule: :maximum, context: %{contrast: maximum}}) do
    "Expected the value to be <= #{maximum}"
  end

  defp format_error(%JSONSchex.Types.Error{rule: :minLength, context: %{contrast: minimum, input: actual}}) do
    "Expected value to have a minimum length of #{minimum} but was #{actual}"
  end

  defp format_error(%JSONSchex.Types.Error{rule: :maxLength, context: %{contrast: maximum, input: actual}}) do
    "Expected value to have a maximum length of #{maximum} but was #{actual}"
  end

  defp format_error(%JSONSchex.Types.Error{rule: :minItems, context: %{contrast: minimum, input: actual}}) do
    "Expected a minimum of #{minimum} items but got #{actual}"
  end

  defp format_error(%JSONSchex.Types.Error{rule: :maxItems, context: %{contrast: maximum, input: actual}}) do
    "Expected a maximum of #{maximum} items but got #{actual}"
  end

  defp format_error(%JSONSchex.Types.Error{rule: :uniqueItems}) do
    "Expected items to be unique but they were not"
  end

  defp format_error(%JSONSchex.Types.Error{rule: :pattern}) do
    "Does not match pattern"
  end

  defp format_error(%JSONSchex.Types.Error{rule: :enum}) do
    "Value is not allowed in enum."
  end

  defp format_error(%JSONSchex.Types.Error{rule: :format, context: %{contrast: "email"}}) do
    "Expected to be a valid email"
  end

  defp format_error(%JSONSchex.Types.Error{rule: :dependentRequired, context: %{input: property, contrast: [dependency]}}) do
    "Property #{property} depends on property #{dependency} to be present but it was not"
  end

  defp format_error(%JSONSchex.Types.Error{rule: :required, context: %{contrast: [property]}}) do
    "Required property #{property} was not present."
  end

  defp format_error(%JSONSchex.Types.Error{rule: :required, context: %{contrast: properties}}) when is_list(properties) do
    "Required properties #{Enum.join(properties, ", ")} were not present."
  end

  defp format_error(%JSONSchex.Types.Error{rule: :type, context: %{contrast: expected, input: actual}}) do
    "Type mismatch. Expected #{format_type(expected)} but got #{format_type(actual)}."
  end

  defp format_error(%JSONSchex.Types.Error{} = error) do
    JSONSchex.format_error(error)
  end

  defp format_type([type | _]), do: format_type(type)
  defp format_type("integer"), do: "Integer"
  defp format_type("number"), do: "Number"
  defp format_type("string"), do: "String"
  defp format_type("boolean"), do: "Boolean"
  defp format_type("object"), do: "Object"
  defp format_type("array"), do: "Array"
  defp format_type("null"), do: "Null"
  defp format_type(type), do: type |> to_string() |> String.capitalize()

  defp path_pointer(%JSONSchex.Types.Error{path: path}) do
    case List.wrap(path) do
      [] -> "#"
      segments -> "#/" <> Enum.map_join(segments, "/", &encode_pointer_segment/1)
    end
  end

  defp encode_pointer_segment(segment) when is_integer(segment), do: Integer.to_string(segment)

  defp encode_pointer_segment(segment) do
    segment
    |> to_string()
    |> String.replace("~", "~0")
    |> String.replace("/", "~1")
  end

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
