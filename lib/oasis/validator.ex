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
          json_schema_root
          |> json_schema_validate(parsed)
          |> recheck_after_validate(json_schema_root, opts)

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



  defp json_schema_validate(%JSONSchex.Types.Schema{} = json_schema_root, parsed) do
    {JSONSchex.validate(json_schema_root, parsed), parsed}
  end

  defp recheck_after_validate({:ok, parsed}, _schema, _opts), do: {:ok, parsed}

  defp recheck_after_validate({{:error, errors}, parsed}, schema, opts) do
    errors =
      errors
      |> Enum.filter(&error_to_attention?(&1, parsed, schema, opts))
      |> Enum.sort_by(fn error -> {root_first_path(error), error_priority(error.rule)} end)

    case errors do
      [] ->
        {:ok, parsed}

      [error | _] ->
        {:error, error}
    end
  end

  # JSONSchex stores validation paths leaf-first. Keep its error untouched for
  # callers and derive a root-first path only where Oasis needs to traverse or
  # render the request value.
  defp root_first_path(%JSONSchex.Types.Error{path: path}) do
    path
    |> List.wrap()
    |> Enum.reverse()
  end

  defp error_to_attention?(%JSONSchex.Types.Error{} = error, parsed, schema, opts) do
    path = root_first_path(error)

    case value_in_path(path, parsed) do
      %Plug.Upload{} ->
        not (opts[:multipart_uploads?] == true and upload_schema?(schema, path))

      _ ->
        true
    end
  end

  defp upload_schema?(%JSONSchex.Types.Schema{} = root, path) do
    root
    |> schemas_at_path(path, root)
    |> Enum.any?(&(upload_compatibility(&1, root, []) == :compatible))
  end

  defp schemas_at_path(schema, [], _root), do: [schema]

  defp schemas_at_path(schema, [segment | rest], root) do
    schema
    |> expand_schema(root, [])
    |> Enum.flat_map(&child_schemas(&1, segment))
    |> Enum.flat_map(&schemas_at_path(&1, rest, root))
  end

  defp expand_schema(%JSONSchex.Types.Schema{} = schema, root, visited_refs) do
    expanded =
      Enum.flat_map(schema.rules || [], fn
        %JSONSchex.Types.Rule{name: :ref, params: %{resolved_uri: uri}} ->
          if uri in visited_refs do
            []
          else
            case Map.get(root.defs || %{}, uri) do
              %JSONSchex.Types.Schema{} = target ->
                expand_schema(target, root, [uri | visited_refs])

              _missing ->
                []
            end
          end

        %JSONSchex.Types.Rule{name: name, params: schemas}
        when name in [:allOf, :anyOf, :oneOf] ->
          Enum.flat_map(schemas, &expand_schema(&1, root, visited_refs))

        %JSONSchex.Types.Rule{name: :if, params: branches} ->
          branches
          |> Map.values()
          |> Enum.reject(&is_nil/1)
          |> Enum.flat_map(&expand_schema(&1, root, visited_refs))

        _rule ->
          []
      end)

    [schema | expanded]
  end

  defp child_schemas(%JSONSchex.Types.Schema{rules: rules}, segment) when is_binary(segment) do
    rules = rules || []

    properties =
      for %JSONSchex.Types.Rule{name: :properties, params: properties} <- rules,
          {^segment, schema} <- properties,
          do: schema

    patterns =
      for %JSONSchex.Types.Rule{name: :patternProperties, params: patterns} <- rules,
          {regex, schema} <- patterns,
          Regex.match?(regex, segment),
          do: schema

    additional =
      for %JSONSchex.Types.Rule{
            name: :additionalProperties,
            params: %{schema: schema, known_props: known, patterns: additional_patterns}
          } <- rules,
          not MapSet.member?(known, segment),
          not Enum.any?(additional_patterns, &Regex.match?(&1, segment)),
          do: schema

    properties ++ patterns ++ additional
  end

  defp child_schemas(%JSONSchex.Types.Schema{rules: rules}, segment) when is_integer(segment) do
    rules = rules || []

    prefix =
      for %JSONSchex.Types.Rule{name: :prefixItems, params: schemas} <- rules,
          schema = Enum.at(schemas, segment),
          schema != nil,
          do: schema

    items =
      for %JSONSchex.Types.Rule{
            name: :items,
            params: %{start_index: start_index, schema: schema}
          } <- rules,
          segment >= start_index,
          do: schema

    prefix ++ items
  end

  defp child_schemas(_schema, _segment), do: []

  defp upload_compatibility(%JSONSchex.Types.Schema{rules: rules}, root, visited_refs) do
    rules = rules || []
    local = local_upload_compatibility(rules)

    refs =
      for %JSONSchex.Types.Rule{name: :ref, params: %{resolved_uri: uri}} <- rules do
        if uri in visited_refs do
          :neutral
        else
          case Map.get(root.defs || %{}, uri) do
            %JSONSchex.Types.Schema{} = target ->
              upload_compatibility(target, root, [uri | visited_refs])

            _missing ->
              :incompatible
          end
        end
      end

    all_of =
      for %JSONSchex.Types.Rule{name: :allOf, params: schemas} <- rules,
          schema <- schemas,
          do: upload_compatibility(schema, root, visited_refs)

    base = combine_upload_all([local | refs ++ all_of])

    applicators =
      Enum.flat_map(rules, fn
        %JSONSchex.Types.Rule{name: :anyOf, params: schemas} ->
          statuses = Enum.map(schemas, &upload_compatibility(&1, root, visited_refs))
          [if(:compatible in statuses, do: :compatible, else: :incompatible)]

        %JSONSchex.Types.Rule{name: :oneOf, params: schemas} ->
          statuses = Enum.map(schemas, &upload_compatibility(&1, root, visited_refs))
          valid = Enum.reject(statuses, &(&1 == :incompatible))
          [if(valid == [:compatible], do: :compatible, else: :incompatible)]

        %JSONSchex.Types.Rule{name: name} when name in [:if, :not] ->
          [:incompatible]

        _rule ->
          []
      end)

    combine_upload_all([base | applicators])
  end

  defp local_upload_compatibility(rules) do
    type_status =
      Enum.find_value(rules, :neutral, fn
        %JSONSchex.Types.Rule{name: :type, params: "string"} -> :neutral
        %JSONSchex.Types.Rule{name: :type, params: types} when is_list(types) ->
          if "string" in types, do: :neutral, else: :incompatible

        %JSONSchex.Types.Rule{name: :type} -> :incompatible
        _rule -> nil
      end)

    format_status =
      Enum.find_value(rules, :neutral, fn
        %JSONSchex.Types.Rule{name: :format, params: format} when format in ["binary", "byte"] ->
          :compatible

        %JSONSchex.Types.Rule{name: :format} ->
          :incompatible

        _rule ->
          nil
      end)

    unsupported_string_assertion? =
      Enum.any?(rules, fn
        %JSONSchex.Types.Rule{name: name}
        when name in [:const, :enum, :pattern, :minLength, :maxLength, :contentEncoding, :contentMediaType,
                      :contentSchema] ->
          true

        _rule ->
          false
      end)

    if unsupported_string_assertion? do
      :incompatible
    else
      combine_upload_all([type_status, format_status])
    end
  end

  defp combine_upload_all(statuses) do
    cond do
      :incompatible in statuses -> :incompatible
      :compatible in statuses -> :compatible
      true -> :neutral
    end
  end

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
    do_parse_and_validate!(json_schema_root, use_in, name, value, multipart_uploads?: true)
  end

  defp process_media_type(
         "multipart/mixed" <> _boundary,
         %{"schema" => json_schema_root},
         use_in,
         name,
         value
       ) do
    do_parse_and_validate!(json_schema_root, use_in, name, value, multipart_uploads?: true)
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
