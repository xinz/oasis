defmodule Oasis.Spec.Operation do
  @moduledoc false

  alias Oasis.Spec.Parameter

  def build(path_expr, operation, global_params) do
    {operation, _sources} = build_with_sources(path_expr, nil, operation, global_params)
    operation
  end

  @doc false
  def build_with_sources(_path_expr, _http_verb, %{"parameters" => parameters} = operation, global_params)
      when is_map(parameters) and global_params in [nil, []] do
    # `Path.build/1` is intentionally tolerant of an already-normalized operation.
    # This keeps the map overload used by existing generator callers idempotent.
    {operation, %{}}
  end

  def build_with_sources(path_expr, http_verb, operation, global_params) do
    global_params = List.wrap(global_params)
    operation_params = List.wrap(operation["parameters"])

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
