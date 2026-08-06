defmodule Oasis.Validator do
  @moduledoc false

  alias Oasis.BadRequestError

  @spec parse_and_validate!(
          param :: map() | nil,
          use_in :: String.t(),
          name :: String.t(),
          value :: term()
        ) :: term()
  def parse_and_validate!(definition, use_in, name, value) do
    parse_and_validate!(definition, use_in, name, value, present?: value != nil)
  end

  @doc false
  @spec parse_and_validate!(
          param :: map() | nil,
          use_in :: String.t(),
          name :: String.t(),
          value :: term(),
          opts :: keyword()
        ) :: term()
  def parse_and_validate!(%{"schema" => _schema} = definition, use_in, name, value, opts) do
    definition
    |> check_required!(use_in, name, value, Keyword.get(opts, :present?, value != nil))
    |> process()
  end

  def parse_and_validate!(%{"content" => _content} = definition, use_in, name, value, opts) do
    definition
    |> check_required!(use_in, name, value, Keyword.get(opts, :present?, value != nil))
    |> process()
  end

  def parse_and_validate!(_definition, _use_in, _name, value, _opts), do: value

  defp check_required!(%{"required" => true}, use_in, param_name, _value, false) do
    raise BadRequestError,
      error: %BadRequestError.Required{},
      use_in: use_in,
      param_name: param_name,
      message: "Missing a required parameter"
  end

  defp check_required!(definition, use_in, name, value, present?) do
    {definition, use_in, name, value, present?}
  end

  defp process({_definition, _use_in, _name, value, false}), do: value

  defp process({%{"schema" => json_schema_root}, use_in, name, value, true}) do
    do_parse_and_validate!(json_schema_root, use_in, name, value)
  end

  defp process({%{"content" => content}, use_in, name, value, true}) do
    [{content_type, media_type} | _] = Map.to_list(content)
    process_media_type(content_type, media_type, use_in, name, value)
  end

  defp do_parse_and_validate!(
         %JSONSchex.Types.Schema{} = json_schema_root,
         use_in,
         param_name,
         value,
         opts \\ []
       ) do
    do_parse_and_validate_value!(json_schema_root, use_in, param_name, value, opts)
  end

  defp do_parse_and_validate_value!(
         %JSONSchex.Types.Schema{} = json_schema_root,
         use_in,
         param_name,
         value,
         opts
       ) do
    try do
      Oasis.Parser.parse(json_schema_root, value)
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
          if opts[:multipart_uploads?] == true do
            Oasis.MultipartUpload.validate(json_schema_root, parsed)
          else
            Oasis.MultipartUpload.validate_non_multipart(json_schema_root, parsed)
          end

        case result do
          :ok ->
            parsed

          {:error, errors} ->
            error = first_error!(errors)

            raise BadRequestError,
              error: %BadRequestError.JSONSchemaValidationFailed{error: error, path: path_pointer(error)},
              use_in: use_in,
              param_name: param_name,
              message: "Failed to validate JSON schema with an error: #{format_error(error)}"
        end
    end
  end



  defp first_error!([%JSONSchex.Types.Error{} | _] = errors) do
    Enum.min_by(errors, fn error -> {root_first_path(error), error_priority(error.rule)} end)
  end

  # JSONSchex stores validation paths leaf-first. Keep its error untouched for
  # callers and derive a root-first path only for deterministic selection and
  # public JSON Pointer rendering.
  defp root_first_path(%JSONSchex.Types.Error{path: path}) do
    path
    |> List.wrap()
    |> Enum.reverse()
  end

  defp error_priority(:type), do: 0
  defp error_priority(:required), do: 1
  defp error_priority(:dependentRequired), do: 1
  defp error_priority(_rule), do: 9

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

  defp format_type(types) when is_list(types) do
    types
    |> Enum.map(&format_type/1)
    |> Enum.join(" or ")
  end
  defp format_type("integer"), do: "Integer"
  defp format_type("number"), do: "Number"
  defp format_type("string"), do: "String"
  defp format_type("boolean"), do: "Boolean"
  defp format_type("object"), do: "Object"
  defp format_type("array"), do: "Array"
  defp format_type("null"), do: "Null"
  defp format_type(type), do: type |> to_string() |> String.capitalize()

  defp path_pointer(%JSONSchex.Types.Error{} = error) do
    error
    |> root_first_path()
    |> ExJSONPointer.encode_path(format: "uri_fragment")
  end

  defp process_media_type(
         content_type,
         %{"schema" => json_schema_root},
         use_in,
         name,
         value
       ) do
    case Oasis.MediaType.validation_kind(content_type) do
      :multipart ->
        do_parse_and_validate!(json_schema_root, use_in, name, value, multipart_uploads?: true)

      kind when kind in [:json, :form, :text] ->
        do_parse_and_validate!(json_schema_root, use_in, name, value)

      :unsupported ->
        value
    end
  end

  defp process_media_type(_content_type, _schema, _use_in, _name, value), do: value

end
