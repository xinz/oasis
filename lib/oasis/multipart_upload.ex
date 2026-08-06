defmodule Oasis.MultipartUpload do
  @moduledoc false

  alias JSONSchex.Types.{Error, ErrorContext, Rule, Schema}
  alias JSONSchex.URIUtil

  @unsupported_upload_keywords [
    "const",
    "contentEncoding",
    "contentMediaType",
    "contentSchema",
    "enum",
    "maxLength",
    "minLength",
    "pattern"
  ]

  @spec validate_non_multipart(Schema.t(), term()) :: :ok | {:error, [Error.t()]}
  def validate_non_multipart(%Schema{} = root, value) do
    uploads = collect_uploads(value, [], [])
    original_errors = validation_errors(JSONSchex.validate(root, value))

    case uploads do
      [] ->
        validation_result(original_errors)

      uploads ->
        upload_errors =
          Enum.flat_map(uploads, fn {path, upload} ->
            if original_error_at_path(original_errors, path) do
              []
            else
              [authorization_error(path, upload)]
            end
          end)

        {:error, original_errors ++ upload_errors}
    end
  end

  @spec validate(Schema.t(), term()) :: :ok | {:error, [Error.t()]}
  def validate(%Schema{} = root, value) do
    {projected, uploads} = project_uploads(value, [])

    case uploads do
      [] ->
        JSONSchex.validate(root, value)

      uploads ->
        original_errors = validation_errors(JSONSchex.validate(root, value))

        case JSONSchex.validate(root, projected) do
          {:error, projected_errors} ->
            {:error, prefer_original_upload_errors(projected_errors, original_errors, uploads)}

          :ok ->
            unauthorized =
              Enum.reject(uploads, fn {path, _upload} ->
                upload_status(root, projected, path, root, %{}) == :grant
              end)

            case unauthorized do
              [] ->
                :ok

              uploads ->
                errors =
                  Enum.map(uploads, fn {path, upload} ->
                    original_error_at_path(original_errors, path) || authorization_error(path, upload)
                  end)

                {:error, errors}
            end
        end
    end
  end

  defp collect_uploads(%Plug.Upload{} = upload, reversed_path, uploads) do
    [{Enum.reverse(reversed_path), upload} | uploads]
  end

  defp collect_uploads(value, reversed_path, uploads) when is_map(value) do
    Enum.reduce(value, uploads, fn {key, child}, acc ->
      collect_uploads(child, [key | reversed_path], acc)
    end)
  end

  defp collect_uploads(value, reversed_path, uploads) when is_list(value) do
    value
    |> Enum.with_index()
    |> Enum.reduce(uploads, fn {child, index}, acc ->
      collect_uploads(child, [index | reversed_path], acc)
    end)
  end

  defp collect_uploads(_value, _reversed_path, uploads), do: uploads

  defp project_uploads(%Plug.Upload{} = upload, reversed_path) do
    path = Enum.reverse(reversed_path)
    marker = "oasis-upload:" <> ExJSONPointer.encode_path(path, format: "uri_fragment")
    {marker, [{path, upload}]}
  end

  defp project_uploads(value, reversed_path) when is_map(value) do
    Enum.reduce(value, {%{}, []}, fn {key, child}, {projected, uploads} ->
      {projected_child, child_uploads} = project_uploads(child, [key | reversed_path])
      {Map.put(projected, key, projected_child), prepend_uploads(child_uploads, uploads)}
    end)
  end

  defp project_uploads(value, reversed_path) when is_list(value) do
    value
    |> Enum.with_index()
    |> Enum.map_reduce([], fn {child, index}, uploads ->
      {projected_child, child_uploads} = project_uploads(child, [index | reversed_path])
      {projected_child, prepend_uploads(child_uploads, uploads)}
    end)
  end

  defp project_uploads(value, _reversed_path), do: {value, []}

  defp prepend_uploads(child_uploads, uploads) do
    Enum.reduce(child_uploads, uploads, fn upload, acc -> [upload | acc] end)
  end

  defp validation_errors(:ok), do: []
  defp validation_errors({:error, errors}), do: errors

  defp validation_result([]), do: :ok
  defp validation_result(errors), do: {:error, errors}

  defp prefer_original_upload_errors(projected_errors, original_errors, uploads) do
    upload_paths = MapSet.new(uploads, &elem(&1, 0))

    Enum.map(projected_errors, fn error ->
      path = root_first_path(error)

      if MapSet.member?(upload_paths, path) do
        original_error_at_path(original_errors, path, error.rule) ||
          original_error_at_path(original_errors, path) ||
          error
      else
        error
      end
    end)
  end

  defp original_error_at_path(errors, path, rule \\ nil) do
    Enum.find(errors, fn error ->
      root_first_path(error) == path and (rule == nil or error.rule == rule)
    end)
  end

  defp authorization_error(path, upload) do
    %Error{
      path: Enum.reverse(path),
      rule: :type,
      context: %ErrorContext{contrast: "string", input: "object"},
      value: upload
    }
  end

  defp root_first_path(%Error{path: path}) do
    path
    |> List.wrap()
    |> Enum.reverse()
  end

  defp upload_status(%Schema{} = schema, value, [], root, visited_refs) do
    rules = schema.rules || []

    [
      local_upload_status(schema),
      dynamic_ref_status(rules),
      ref_status(rules, schema, value, [], root, visited_refs),
      all_of_status(rules, value, [], root, visited_refs),
      alternatives_status(rules, value, [], root, visited_refs),
      conditional_status(rules, value, [], root, visited_refs),
      negation_status(rules, value, [], root, visited_refs)
    ]
    |> combine_all()
  end

  defp upload_status(%Schema{} = schema, value, [segment | rest] = path, root, visited_refs) do
    rules = schema.rules || []

    [
      dynamic_ref_status(rules),
      ref_status(rules, schema, value, path, root, visited_refs),
      all_of_status(rules, value, path, root, visited_refs),
      alternatives_status(rules, value, path, root, visited_refs),
      conditional_status(rules, value, path, root, visited_refs),
      negation_status(rules, value, path, root, visited_refs),
      dependent_status(rules, value, path, root, visited_refs),
      child_status(rules, value, segment, rest, root, visited_refs)
    ]
    |> combine_all()
  end

  defp dynamic_ref_status(rules) do
    if Enum.any?(rules, &match?(%Rule{name: :dynamicRef}, &1)), do: :deny, else: :neutral
  end

  defp ref_status(rules, current, value, path, root, visited_refs) do
    rules
    |> Enum.flat_map(fn
      %Rule{name: :ref, params: %{resolved_uri: uri} = params} when is_binary(uri) ->
        visit_key = {uri, path}

        if Map.has_key?(visited_refs, visit_key) do
          []
        else
          case compiled_ref_target(root, current, params) do
            %Schema{} = target ->
              visited_refs = Map.put(visited_refs, visit_key, true)
              [upload_status(target, value, path, root, visited_refs)]

            _missing ->
              [:deny]
          end
        end

      _rule ->
        []
    end)
    |> combine_all()
  end

  defp all_of_status(rules, value, path, root, visited_refs) do
    rules
    |> Enum.flat_map(fn
      %Rule{name: :allOf, params: schemas} ->
        Enum.map(schemas, &upload_status(&1, value, path, root, visited_refs))

      _rule ->
        []
    end)
    |> combine_all()
  end

  defp alternatives_status(rules, value, path, root, visited_refs) do
    rules
    |> Enum.flat_map(fn
      %Rule{name: :anyOf, params: schemas} ->
        statuses =
          schemas
          |> Enum.filter(&schema_valid?(&1, value, root))
          |> Enum.map(&upload_status(&1, value, path, root, visited_refs))

        [combine_any(statuses)]

      %Rule{name: :oneOf, params: schemas} ->
        statuses =
          schemas
          |> Enum.filter(&schema_valid?(&1, value, root))
          |> Enum.map(&upload_status(&1, value, path, root, visited_refs))

        [if(length(statuses) == 1, do: hd(statuses), else: :deny)]

      _rule ->
        []
    end)
    |> combine_all()
  end

  defp conditional_status(rules, value, path, root, visited_refs) do
    rules
    |> Enum.flat_map(fn
      %Rule{name: :if, params: %{if: if_schema, then: then_schema, else: else_schema}} ->
        if content_sensitive_at_path?(if_schema, value, path, root, visited_refs) do
          [:deny]
        else
          branch = if schema_valid?(if_schema, value, root), do: then_schema, else: else_schema

          case branch do
            %Schema{} = schema -> [upload_status(schema, value, path, root, visited_refs)]
            nil -> []
          end
        end

      _rule ->
        []
    end)
    |> combine_all()
  end

  defp negation_status(rules, value, path, root, visited_refs) do
    rules
    |> Enum.flat_map(fn
      %Rule{name: :not, params: %Schema{} = schema} ->
        if content_sensitive_at_path?(schema, value, path, root, visited_refs),
          do: [:deny],
          else: []

      _rule ->
        []
    end)
    |> combine_all()
  end

  defp dependent_status(rules, value, path, root, visited_refs) when is_map(value) do
    rules
    |> Enum.flat_map(fn
      %Rule{name: :dependentSchemas, params: schemas} ->
        for {trigger, schema} <- schemas, Map.has_key?(value, trigger) do
          upload_status(schema, value, path, root, visited_refs)
        end

      %Rule{name: :dependencies, params: %{mode: mode, schemas: schemas}}
      when mode in [:schemas, :both] ->
        for {trigger, schema} <- schemas, Map.has_key?(value, trigger) do
          upload_status(schema, value, path, root, visited_refs)
        end

      _rule ->
        []
    end)
    |> combine_all()
  end

  defp dependent_status(_rules, _value, _path, _root, _visited_refs), do: :neutral

  defp child_status(rules, value, segment, rest, root, visited_refs)
       when is_map(value) and is_binary(segment) do
    child = Map.get(value, segment)

    direct_schemas =
      property_schemas(rules, segment) ++
        pattern_schemas(rules, segment) ++ additional_property_schemas(rules, segment)

    direct_status =
      direct_schemas
      |> Enum.map(&upload_status(&1, child, rest, root, visited_refs))
      |> combine_all()

    unevaluated_status =
      unevaluated_property_status(rules, value, segment, rest, root, visited_refs, direct_schemas)

    combine_all([direct_status, unevaluated_status])
  end

  defp child_status(rules, value, segment, rest, root, visited_refs)
       when is_list(value) and is_integer(segment) do
    child = Enum.at(value, segment)
    direct_schemas = prefix_item_schemas(rules, segment) ++ item_schemas(rules, segment)

    direct_status =
      direct_schemas
      |> Enum.map(&upload_status(&1, child, rest, root, visited_refs))
      |> combine_all()

    unevaluated_status =
      unevaluated_item_status(rules, child, segment, rest, root, visited_refs, direct_schemas)

    combine_all([direct_status, unevaluated_status])
  end

  defp child_status(_rules, _value, _segment, _rest, _root, _visited_refs), do: :deny

  defp property_schemas(rules, segment) do
    for %Rule{name: :properties, params: properties} <- rules,
        {^segment, schema} <- properties,
        do: schema
  end

  defp pattern_schemas(rules, segment) do
    for %Rule{name: :patternProperties, params: patterns} <- rules,
        {regex, schema} <- patterns,
        Regex.match?(regex, segment),
        do: schema
  end

  defp additional_property_schemas(rules, segment) do
    for %Rule{
          name: :additionalProperties,
          params: %{schema: schema, known_props: known, patterns: patterns}
        } <- rules,
        not MapSet.member?(known, segment),
        not Enum.any?(patterns, &Regex.match?(&1, segment)),
        do: schema
  end

  defp prefix_item_schemas(rules, segment) do
    for %Rule{name: :prefixItems, params: schemas} <- rules,
        schema = Enum.at(schemas, segment),
        schema != nil,
        do: schema
  end

  defp item_schemas(rules, segment) do
    for %Rule{name: :items, params: %{start_index: start_index, schema: schema}} <- rules,
        segment >= start_index,
        do: schema
  end

  defp unevaluated_property_status(
         rules,
         value,
         segment,
         rest,
         root,
         visited_refs,
         direct_schemas
       ) do
    schemas =
      for %Rule{name: :unevaluatedProperties, params: %{schema: schema}} <- rules,
          do: schema

    cond do
      schemas == [] or direct_schemas != [] ->
        :neutral

      complex_object_applicator?(rules) ->
        :deny

      true ->
        child = Map.get(value, segment)

        schemas
        |> Enum.map(&upload_status(&1, child, rest, root, visited_refs))
        |> combine_all()
    end
  end

  defp unevaluated_item_status(rules, child, _segment, rest, root, visited_refs, direct_schemas) do
    schemas =
      for %Rule{name: :unevaluatedItems, params: %{schema: schema}} <- rules,
          do: schema

    cond do
      schemas == [] or direct_schemas != [] ->
        :neutral

      complex_array_applicator?(rules) ->
        :deny

      true ->
        schemas
        |> Enum.map(&upload_status(&1, child, rest, root, visited_refs))
        |> combine_all()
    end
  end

  defp content_sensitive_at_path?(%Schema{} = schema, value, [], root, visited_refs) do
    rules = schema.rules || []

    local_content_sensitive?(schema) or
      Enum.any?(rules, fn
        %Rule{name: :dynamicRef} ->
          true

        %Rule{name: :ref, params: %{resolved_uri: uri} = params} when is_binary(uri) ->
          visit_key = {:content_sensitive, uri, []}

          if Map.has_key?(visited_refs, visit_key) do
            false
          else
            case compiled_ref_target(root, schema, params) do
              %Schema{} = target ->
                content_sensitive_at_path?(target, value, [], root, Map.put(visited_refs, visit_key, true))

              _missing ->
                true
            end
          end

        %Rule{name: name, params: schemas} when name in [:allOf, :anyOf, :oneOf] ->
          Enum.any?(schemas, &content_sensitive_at_path?(&1, value, [], root, visited_refs))

        %Rule{name: :not, params: %Schema{} = nested} ->
          content_sensitive_at_path?(nested, value, [], root, visited_refs)

        %Rule{name: :if, params: branches} ->
          branches
          |> Map.values()
          |> Enum.reject(&is_nil/1)
          |> Enum.any?(&content_sensitive_at_path?(&1, value, [], root, visited_refs))

        _rule ->
          false
      end)
  end

  defp content_sensitive_at_path?(
         %Schema{} = schema,
         value,
         [segment | rest] = path,
         root,
         visited_refs
       ) do
    rules = schema.rules || []

    ref_sensitive? =
      Enum.any?(rules, fn
        %Rule{name: :dynamicRef} ->
          true

        %Rule{name: :ref, params: %{resolved_uri: uri} = params} when is_binary(uri) ->
          visit_key = {:content_sensitive, uri, path}

          if Map.has_key?(visited_refs, visit_key) do
            false
          else
            case compiled_ref_target(root, schema, params) do
              %Schema{} = target ->
                content_sensitive_at_path?(
                  target,
                  value,
                  path,
                  root,
                  Map.put(visited_refs, visit_key, true)
                )

              _missing ->
                true
            end
          end

        _rule ->
          false
      end)

    applicator_sensitive? =
      Enum.any?(rules, fn
        %Rule{name: name, params: schemas} when name in [:allOf, :anyOf, :oneOf] ->
          Enum.any?(schemas, &content_sensitive_at_path?(&1, value, path, root, visited_refs))

        %Rule{name: :not, params: %Schema{} = nested} ->
          content_sensitive_at_path?(nested, value, path, root, visited_refs)

        %Rule{name: :if, params: branches} ->
          branches
          |> Map.values()
          |> Enum.reject(&is_nil/1)
          |> Enum.any?(&content_sensitive_at_path?(&1, value, path, root, visited_refs))

        _rule ->
          false
      end)

    dependent_sensitive? =
      if is_map(value) do
        Enum.any?(rules, fn
          %Rule{name: :dependentSchemas, params: schemas} ->
            Enum.any?(schemas, fn {trigger, nested} ->
              Map.has_key?(value, trigger) and
                content_sensitive_at_path?(nested, value, path, root, visited_refs)
            end)

          %Rule{name: :dependencies, params: %{mode: mode, schemas: schemas}}
          when mode in [:schemas, :both] ->
            Enum.any?(schemas, fn {trigger, nested} ->
              Map.has_key?(value, trigger) and
                content_sensitive_at_path?(nested, value, path, root, visited_refs)
            end)

          _rule ->
            false
        end)
      else
        false
      end

    child_sensitive? =
      cond do
        is_map(value) and is_binary(segment) ->
          child = Map.get(value, segment)

          schemas =
            property_schemas(rules, segment) ++
              pattern_schemas(rules, segment) ++
              additional_property_schemas(rules, segment) ++
              unevaluated_property_schemas(rules)

          Enum.any?(schemas, &content_sensitive_at_path?(&1, child, rest, root, visited_refs))

        is_list(value) and is_integer(segment) ->
          child = Enum.at(value, segment)

          schemas =
            prefix_item_schemas(rules, segment) ++
              item_schemas(rules, segment) ++
              unevaluated_item_schemas(rules) ++ contains_schemas(rules)

          Enum.any?(schemas, &content_sensitive_at_path?(&1, child, rest, root, visited_refs))

        true ->
          false
      end

    ref_sensitive? or applicator_sensitive? or dependent_sensitive? or child_sensitive?
  end

  defp local_content_sensitive?(%Schema{rules: rules, raw: raw}) do
    unsupported_keyword? =
      is_map(raw) and Enum.any?(@unsupported_upload_keywords, &Map.has_key?(raw, &1))

    content_sensitive_format? =
      Enum.any?(rules || [], fn
        %Rule{name: :format, params: format} when format in ["binary", "byte"] -> false
        %Rule{name: :format} -> true
        _rule -> false
      end)

    unsupported_keyword? or content_sensitive_format?
  end

  defp unevaluated_property_schemas(rules) do
    for %Rule{name: :unevaluatedProperties, params: %{schema: schema}} <- rules, do: schema
  end

  defp unevaluated_item_schemas(rules) do
    for %Rule{name: :unevaluatedItems, params: %{schema: schema}} <- rules, do: schema
  end

  defp contains_schemas(rules) do
    for %Rule{name: :contains, params: %{schema: schema}} <- rules, do: schema
  end

  defp local_upload_status(%Schema{rules: rules, raw: raw}) do
    rules = rules || []

    type_status =
      Enum.find_value(rules, :neutral, fn
        %Rule{name: :boolean_schema, params: false} -> :deny
        %Rule{name: :type, params: "string"} -> :neutral
        %Rule{name: :type, params: types} when is_list(types) ->
          if "string" in types, do: :neutral, else: :deny

        %Rule{name: :type} -> :deny
        _rule -> nil
      end)

    format_status =
      Enum.find_value(rules, :neutral, fn
        %Rule{name: :format, params: format} when format in ["binary", "byte"] -> :grant
        %Rule{name: :format} -> :deny
        _rule -> nil
      end)

    unsupported? =
      is_map(raw) and Enum.any?(@unsupported_upload_keywords, &Map.has_key?(raw, &1))

    if unsupported?, do: :deny, else: combine_all([type_status, format_status])
  end

  defp compiled_ref_target(root, current, %{resolved_uri: uri}) do
    defs = root.defs || %{}
    Map.get(defs, uri) || compiled_scoped_ref_target(root, current, defs, uri)
  end

  defp compiled_scoped_ref_target(root, current, defs, uri) when is_binary(uri) do
    {base, fragment} = URIUtil.split_fragment(uri)
    local_ref = URIUtil.local_ref(fragment)

    [Map.get(defs, base), resource_for_base(current, base), resource_for_base(root, base)]
    |> Enum.find_value(fn
      %Schema{defs: resource_defs} -> Map.get(resource_defs || %{}, local_ref)
      _missing -> nil
    end)
  end

  defp compiled_scoped_ref_target(_root, _current, _defs, _uri), do: nil

  defp resource_for_base(%Schema{source_id: nil} = schema, ""), do: schema

  defp resource_for_base(%Schema{source_id: source_id} = schema, base) when is_binary(source_id) do
    {source_base, _fragment} = URIUtil.split_fragment(source_id)
    if source_base == base, do: schema
  end

  defp resource_for_base(_schema, _base), do: nil

  defp schema_valid?(%Schema{} = schema, value, root) do
    schema = %{
      schema
      | defs: root.defs,
        loader: root.loader,
        format_assertion: root.format_assertion,
        content_assertion: root.content_assertion
    }

    JSONSchex.validate(schema, value) == :ok
  end

  defp complex_object_applicator?(rules) do
    Enum.any?(rules, fn
      %Rule{name: name} when name in [:allOf, :anyOf, :oneOf, :if, :ref, :dependentSchemas, :dependencies] ->
        true

      _rule ->
        false
    end)
  end

  defp complex_array_applicator?(rules) do
    Enum.any?(rules, fn
      %Rule{name: name} when name in [:allOf, :anyOf, :oneOf, :if, :ref, :contains] -> true
      _rule -> false
    end)
  end



  defp combine_all(statuses) do
    cond do
      :deny in statuses -> :deny
      :grant in statuses -> :grant
      true -> :neutral
    end
  end

  defp combine_any(statuses) do
    cond do
      :grant in statuses -> :grant
      :neutral in statuses -> :neutral
      true -> :deny
    end
  end
end
