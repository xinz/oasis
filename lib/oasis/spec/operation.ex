defmodule Oasis.Spec.Operation do
  @moduledoc false

  alias Oasis.InvalidSpecError
  alias Oasis.Spec.Parameter

  def build(path_expr, operation, global_params) do
    {operation, _sources} = build_with_sources(path_expr, nil, operation, global_params, false)
    operation
  end

  @doc false
  def build_with_sources(path_expr, http_verb, operation, global_params) do
    build_with_sources(path_expr, http_verb, operation, global_params, false)
  end

  @doc false
  def build_with_sources(
        path_expr,
        http_verb,
        %{"parameters" => parameters} = operation,
        global_params,
        true
      )
      when is_map(parameters) and global_params in [nil, []] do
    if normalized_parameter_groups?(parameters) do
      # Preserve the legacy map input accepted by Mix.Oasis.new/2, but require
      # the complete normalized shape instead of treating every map as prepared.
      {operation, %{}}
    else
      raise InvalidSpecError,
            "Operation `#{http_verb}` parameters in path `#{path_expr}` must be an array or normalized location map, got: #{inspect(parameters, pretty: true)}"
    end
  end

  def build_with_sources(path_expr, http_verb, operation, _global_params, _allow_normalized_parameters?)
      when not is_map(operation) do
    raise InvalidSpecError,
          "Operation Object for `#{http_verb}` in path `#{path_expr}` must be an object, got: #{inspect(operation, pretty: true)}"
  end

  def build_with_sources(
        path_expr,
        http_verb,
        operation,
        global_params,
        _allow_normalized_parameters?
      ) do
    global_params = parameter_list!(global_params, path_expr, "Path Item")
    operation_params = parameter_list!(operation["parameters"], path_expr, "Operation `#{http_verb}`")

    global_params =
      global_params
      |> Enum.with_index()
      |> Enum.map(fn {parameter, index} ->
        {parameter, ["paths", path_expr, "parameters", index]}
      end)

    operation_params =
      operation_params
      |> Enum.with_index()
      |> Enum.map(fn {parameter, index} ->
        {parameter, ["paths", path_expr, http_verb, "parameters", index]}
      end)

    {parameters, sources} =
      (global_params ++ operation_params)
      |> group_by_location()
      |> override_duplicated_name(path_expr)

    {Map.put(operation, "parameters", parameters), sources}
  end

  defp normalized_parameter_groups?(parameters) do
    allowed_locations = ["query", "header", "cookie", "path"]

    Enum.all?(parameters, fn {location, definitions} ->
      location in allowed_locations and is_list(definitions) and Enum.all?(definitions, &is_map/1)
    end)
  end

  defp parameter_list!(nil, _path_expr, _owner), do: []
  defp parameter_list!(parameters, _path_expr, _owner) when is_list(parameters), do: parameters

  defp parameter_list!(parameters, path_expr, owner) do
    raise InvalidSpecError,
          "#{owner} parameters in path `#{path_expr}` must be an array, got: #{inspect(parameters, pretty: true)}"
  end

  defp group_by_location(parameters) do
    # The location (`in` field) is one of query, header, path, or cookie.
    Enum.group_by(parameters, fn {parameter, _source} -> parameter["in"] end)
  end

  defp override_duplicated_name(groups, path_expr) do
    Enum.reduce(groups, {%{}, %{}}, fn {location, parameters}, {groups_acc, sources_acc} ->
      parameters =
        parameters
        |> Enum.reduce(%{}, fn {parameter, _source} = candidate, acc ->
          # Operation-level parameters follow path-level parameters and therefore
          # replace them for the OpenAPI identity `(in, name)`.
          Map.put(acc, parameter["name"], candidate)
        end)
        |> Map.values()
        |> Enum.sort_by(fn {parameter, _source} -> parameter["name"] end)

      {parameters, sources} =
        Enum.reduce(parameters, {[], sources_acc}, fn {parameter, source}, {parameters_acc, sources_acc} ->
          case Parameter.build(path_expr, parameter) do
            nil ->
              {parameters_acc, sources_acc}

            built ->
              source_key = {location, built["name"]}
              {parameters_acc ++ [built], Map.put(sources_acc, source_key, source)}
          end
        end)

      {Map.put(groups_acc, location, parameters), sources}
    end)
  end
end
