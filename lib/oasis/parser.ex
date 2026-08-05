defmodule Oasis.Parser do
  @moduledoc false

  alias JSONSchex.Types.{Rule, Schema}
  alias JSONSchex.URIUtil

  def parse(%Schema{} = schema, value) do
    parse_compiled(schema, value, schema, [])
  end

  def parse(type, value) when is_bitstring(value) do
    do_parse(type, value)
  end

  def parse(%{"type" => "null"}, nil), do: nil

  def parse(%{"type" => "array"} = type, value) when is_list(value) do
    do_parse_array(type, value)
  end

  def parse(%{"type" => "object"} = type, value) when is_map(value) do
    do_parse_object(type, value)
  end

  def parse(_type, value), do: value

  # JSONSchex 0.9 exposes compiled child schemas through Rule descriptors. Keep
  # all descriptor-shape knowledge in this visitor so coercion does not leak
  # compiler internals into request validation or generation code.
  defp parse_compiled(%Schema{} = schema, value, root, visited_refs) do
    rules = schema.rules || []
    value = parse_compiled_refs(rules, value, root, visited_refs)
    value = parse_local_schema(schema.raw, value)

    Enum.reduce(rules, value, fn rule, parsed ->
      parse_compiled_children(rule, parsed, root, rules)
    end)
  end

  defp parse_compiled_refs(rules, value, root, visited_refs) do
    Enum.reduce(rules, value, fn
      %Rule{name: :ref, params: %{resolved_uri: uri}}, parsed ->
        if uri in visited_refs do
          parsed
        else
          case compiled_ref_target(root, uri) do
            %Schema{} = target ->
              parse_compiled(target, parsed, root, [uri | visited_refs])

            _missing ->
              parsed
          end
        end

      _rule, parsed ->
        parsed
    end)
  end

  defp compiled_ref_target(%Schema{} = root, uri) when is_binary(uri) do
    defs = root.defs || %{}

    case Map.get(defs, uri) do
      %Schema{} = target ->
        target

      _missing ->
        compiled_scoped_ref_target(root, defs, uri)
    end
  end

  defp compiled_ref_target(_root, _uri), do: nil

  defp compiled_scoped_ref_target(root, defs, uri) do
    {base, fragment} = URIUtil.split_fragment(uri)

    with fragment when is_binary(fragment) <- fragment,
         %Schema{} = resource <- Map.get(defs, base) || root_resource(root, base),
         %Schema{} = target <- Map.get(resource.defs || %{}, URIUtil.local_ref(fragment)) do
      target
    else
      _missing -> nil
    end
  end

  defp root_resource(%Schema{source_id: base} = root, base), do: root
  defp root_resource(%Schema{} = root, ""), do: root
  defp root_resource(_root, _base), do: nil

  defp parse_local_schema(%{"type" => _type} = raw, value) when is_binary(value) do
    do_parse(raw, value)
  end

  defp parse_local_schema(_raw, value), do: value

  defp parse_compiled_children(
         %Rule{name: :unevaluatedProperties, params: %{schema: schema}},
         value,
         root,
         rules
       )
       when is_map(value) do
    if has_complex_object_applicator?(rules) do
      value
    else
      Enum.reduce(value, value, fn {name, property_value}, parsed ->
        if locally_evaluated_property?(name, rules) do
          parsed
        else
          Map.put(parsed, name, parse_compiled(schema, property_value, root, []))
        end
      end)
    end
  end

  defp parse_compiled_children(
         %Rule{name: :unevaluatedItems, params: %{schema: schema}},
         value,
         root,
         rules
       )
       when is_list(value) do
    if has_complex_array_applicator?(rules) do
      value
    else
      evaluated_count = evaluated_item_count(rules, length(value))
      {evaluated, unevaluated} = Enum.split(value, evaluated_count)
      evaluated ++ Enum.map(unevaluated, &parse_compiled(schema, &1, root, []))
    end
  end

  defp parse_compiled_children(rule, value, root, _rules) do
    parse_compiled_children(rule, value, root)
  end

  defp parse_compiled_children(%Rule{name: :properties, params: properties}, value, root)
       when is_map(value) do
    Enum.reduce(properties, value, fn {name, schema}, parsed ->
      if Map.has_key?(parsed, name) do
        Map.update!(parsed, name, &parse_compiled(schema, &1, root, []))
      else
        parsed
      end
    end)
  end

  defp parse_compiled_children(%Rule{name: :patternProperties, params: patterns}, value, root)
       when is_map(value) do
    Enum.reduce(value, value, fn {name, property_value}, parsed ->
      coerced =
        patterns
        |> Enum.filter(fn {regex, _schema} -> Regex.match?(regex, name) end)
        |> Enum.reduce(property_value, fn {_regex, schema}, candidate ->
          parse_compiled(schema, candidate, root, [])
        end)

      Map.put(parsed, name, coerced)
    end)
  end

  defp parse_compiled_children(
         %Rule{
           name: :additionalProperties,
           params: %{schema: schema, known_props: known_props, patterns: patterns}
         },
         value,
         root
       )
       when is_map(value) do
    Enum.reduce(value, value, fn {name, property_value}, parsed ->
      known? = MapSet.member?(known_props, name)
      patterned? = Enum.any?(patterns, &Regex.match?(&1, name))

      if known? or patterned? do
        parsed
      else
        Map.put(parsed, name, parse_compiled(schema, property_value, root, []))
      end
    end)
  end

  defp parse_compiled_children(%Rule{name: :prefixItems, params: schemas}, value, root)
       when is_list(value) do
    {prefix, remaining} = Enum.split(value, length(schemas))

    parsed_prefix =
      schemas
      |> Enum.zip(prefix)
      |> Enum.map(fn {schema, item} ->
        parse_compiled(schema, item, root, [])
      end)

    parsed_prefix ++ remaining
  end

  defp parse_compiled_children(
         %Rule{name: :items, params: %{start_index: start_index, schema: schema}},
         value,
         root
       )
       when is_list(value) do
    {prefix, items} = Enum.split(value, start_index)
    prefix ++ Enum.map(items, &parse_compiled(schema, &1, root, []))
  end

  defp parse_compiled_children(%Rule{name: :allOf, params: schemas}, value, root) do
    Enum.reduce(schemas, value, fn schema, parsed ->
      parse_compiled(schema, parsed, root, [])
    end)
  end

  defp parse_compiled_children(%Rule{name: name, params: schemas}, value, root)
       when name in [:anyOf, :oneOf] do
    parsed =
      schemas
      |> Enum.flat_map(fn schema ->
        try do
          candidate = parse_compiled(schema, value, root, [])
          if schema_valid?(schema, candidate, root), do: [{schema, candidate}], else: []
        rescue
          ArgumentError -> []
        end
      end)

    candidates = parsed |> Enum.map(&elem(&1, 1)) |> Enum.uniq()

    case {name, parsed, candidates} do
      {:oneOf, [_single], [candidate]} -> candidate
      {:anyOf, [_ | _], [candidate]} -> candidate
      _ambiguous_or_invalid -> value
    end
  end

  defp parse_compiled_children(
         %Rule{name: :if, params: %{if: if_schema, then: then_schema, else: else_schema}},
         value,
         root
       ) do
    branch = if schema_valid?(if_schema, value, root), do: then_schema, else: else_schema

    case branch do
      %Schema{} = schema -> parse_compiled(schema, value, root, [])
      nil -> value
    end
  end

  defp parse_compiled_children(%Rule{name: :dependentSchemas, params: schemas}, value, root)
       when is_map(value) do
    Enum.reduce(schemas, value, fn {trigger, schema}, parsed ->
      if Map.has_key?(parsed, trigger) do
        parse_compiled(schema, parsed, root, [])
      else
        parsed
      end
    end)
  end

  defp parse_compiled_children(
         %Rule{name: :dependencies, params: %{mode: mode, schemas: schemas}},
         value,
         root
       )
       when mode in [:schemas, :both] and is_map(value) do
    Enum.reduce(schemas, value, fn {trigger, schema}, parsed ->
      if Map.has_key?(parsed, trigger) do
        parse_compiled(schema, parsed, root, [])
      else
        parsed
      end
    end)
  end

  defp parse_compiled_children(_rule, value, _root), do: value

  defp locally_evaluated_property?(name, rules) do
    property? =
      Enum.any?(rules, fn
        %Rule{name: :properties, params: properties} ->
          Enum.any?(properties, fn {property, _schema} -> property == name end)

        _rule ->
          false
      end)

    pattern? =
      Enum.any?(rules, fn
        %Rule{name: :patternProperties, params: patterns} ->
          Enum.any?(patterns, fn {regex, _schema} -> Regex.match?(regex, name) end)

        _rule ->
          false
      end)

    additional? =
      Enum.any?(rules, fn
        %Rule{name: :additionalProperties, params: %{known_props: known, patterns: patterns}} ->
          not MapSet.member?(known, name) and not Enum.any?(patterns, &Regex.match?(&1, name))

        _rule ->
          false
      end)

    property? or pattern? or additional?
  end

  defp has_complex_object_applicator?(rules) do
    Enum.any?(rules, fn
      %Rule{name: name} when name in [:allOf, :anyOf, :oneOf, :if, :dependentSchemas, :dependencies] -> true
      _rule -> false
    end)
  end

  defp has_complex_array_applicator?(rules) do
    Enum.any?(rules, fn
      %Rule{name: name} when name in [:allOf, :anyOf, :oneOf, :if, :contains] -> true
      _rule -> false
    end)
  end

  defp evaluated_item_count(rules, item_count) do
    prefix_count =
      Enum.find_value(rules, 0, fn
        %Rule{name: :prefixItems, params: schemas} -> length(schemas)
        _rule -> nil
      end)

    if Enum.any?(rules, &match?(%Rule{name: :items}, &1)) do
      item_count
    else
      min(prefix_count, item_count)
    end
  end

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

  defp do_parse(%{"type" => types}, value) when is_list(types) and is_binary(value) do
    if Enum.any?(types, &matches_type_value?(&1, value)) do
      value
    else
      candidates =
        types
        |> Enum.reject(&(&1 == "null"))
        |> Enum.flat_map(fn type ->
          try do
            parsed = do_parse(%{"type" => type}, value)
            if matches_type_value?(type, parsed), do: [{type, parsed}], else: []
          rescue
            ArgumentError -> []
          end
        end)

      case candidates do
        [{_type, candidate}] ->
          candidate

        candidates ->
          integer = Enum.find(candidates, fn {type, _candidate} -> type == "integer" end)
          number = Enum.find(candidates, fn {type, _candidate} -> type == "number" end)

          case {integer, number, length(candidates)} do
            {{"integer", candidate}, {"number", _number}, 2} -> candidate
            _ambiguous_or_invalid -> value
          end
      end
    end
  end

  defp do_parse(%{"type" => type}, value)
       when is_bitstring(value) and type in ["array", "object"] do
    case Jason.decode(value) do
      {:ok, value} ->
        value

      {:error, _error} ->
        raise_argument_error()
    end
  end

  defp do_parse(%{"type" => "boolean"}, "true"), do: true
  defp do_parse(%{"type" => "boolean"}, "false"), do: false
  defp do_parse(%{"type" => "boolean"}, value), do: value

  defp do_parse(%{"type" => "number"}, value) do
    case Float.parse(value) do
      {value, ""} ->
        value

      _ ->
        raise_argument_error()
    end
  end

  defp do_parse(%{"type" => "integer"}, value) do
    String.to_integer(value)
  end

  defp do_parse(%{"type" => "string"}, value) do
    value
  end

  defp do_parse(_type, value) do
    value
  end

  defp matches_type_value?("string", value), do: is_binary(value)
  defp matches_type_value?("integer", value), do: is_integer(value)
  defp matches_type_value?("number", value), do: is_number(value)
  defp matches_type_value?("boolean", value), do: is_boolean(value)
  defp matches_type_value?("object", value), do: is_map(value)
  defp matches_type_value?("array", value), do: is_list(value)
  defp matches_type_value?("null", value), do: is_nil(value)
  defp matches_type_value?(_type, _value), do: false

  defp do_parse_array(%{"prefixItems" => prefix_items} = schema, list)
       when is_list(prefix_items) do
    parsed_prefix =
      prefix_items
      |> Enum.zip(list)
      |> Enum.map(fn {type, value} ->
        parse(type, value)
      end)

    remaining = Enum.drop(list, length(prefix_items))

    parsed_remaining =
      case Map.get(schema, "items") do
        item_schema when is_map(item_schema) or is_boolean(item_schema) ->
          Enum.map(remaining, &parse(item_schema, &1))

        _other ->
          remaining
      end

    parsed_prefix ++ parsed_remaining
  end

  defp do_parse_array(%{"items" => %{"type" => _type} = schema}, list) do
    Enum.map(list, fn value ->
      parse(schema, value)
    end)
  end

  defp do_parse_array(%{"items" => items}, list)
       when is_list(items) and length(items) == length(list) do
    items
    |> Enum.zip(list)
    |> Enum.map(fn {type, value} ->
      parse(type, value)
    end)
  end

  defp do_parse_array(%{"items" => items}, list)
       when is_list(items) and length(items) != length(list) do
    raise_argument_error()
  end

  defp do_parse_array(_, list), do: list

  defp do_parse_object(type, map) when is_map(type) and is_map(map) do
    properties =
      type
      |> Map.get("properties", %{})
      |> Map.merge(properties_from_schema_dependencies(type, map))

    patterns = pattern_properties(type)
    additional_properties = Map.get(type, "additionalProperties")

    Enum.reduce(map, map, fn {name, value}, acc ->
      schemas = schemas_to_parse_property(name, properties, patterns, additional_properties)
      parsed = Enum.reduce(schemas, value, fn schema, candidate -> parse(schema, candidate) end)
      Map.put(acc, name, parsed)
    end)
  end

  defp properties_from_schema_dependencies(type, map) do
    type
    |> Map.get("dependencies", Map.get(type, "dependentSchemas", %{}))
    |> Enum.reduce(%{}, fn
      {trigger, definition}, acc when is_map(definition) ->
        if Map.has_key?(map, trigger) do
          Map.merge(acc, Map.get(definition, "properties", %{}))
        else
          acc
        end

      _dependency, acc ->
        acc
    end)
  end

  defp pattern_properties(type) do
    type
    |> Map.get("patternProperties", %{})
    |> Enum.map(fn {pattern, definition} -> {Regex.compile!(pattern), definition} end)
  end

  defp schemas_to_parse_property(name, properties, patterns, additional_properties) do
    direct =
      case Map.fetch(properties, name) do
        {:ok, schema} -> [schema]
        :error -> []
      end

    patterned =
      for {regex, schema} <- patterns,
          Regex.match?(regex, name),
          do: schema

    case direct ++ patterned do
      [] when is_map(additional_properties) or is_boolean(additional_properties) ->
        [additional_properties]

      schemas ->
        schemas
    end
  end

  defp raise_argument_error() do
    raise ArgumentError, "argument error"
  end
end
