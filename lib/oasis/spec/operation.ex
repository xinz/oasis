defmodule Oasis.Spec.Operation do
  @moduledoc false

  def build(path_expr, operation, global_params) do
    parameters =
      global_params
      |> concat_params(operation["parameters"])
      |> group_and_override(path_expr)

    Map.put(operation, "parameters", parameters)
  end

  defp concat_params(global_params, nil), do: global_params
  defp concat_params(global_params, []), do: global_params
  defp concat_params(global_params, operation_params), do: global_params ++ operation_params

  defp group_and_override(parameters, path_expr) do
    parameters
    |> group_by_location()
    |> override_duplicated_name(path_expr)
  end

  defp group_by_location(parameters) do
    # The location (`in` field) of the parameter, possible values are "query", "header", "path" or "cookie".
    Enum.group_by(parameters, & &1["in"])
  end

  defp override_duplicated_name(groups, path_expr) do
    Enum.reduce(groups, %{}, fn {location, parameters}, acc ->
      overrided_parameters =
        parameters
        |> Enum.reduce(%{}, fn parameter, acc ->
          Map.put(acc, parameter["name"], parameter)
        end)
        |> Map.values()
        |> Enum.sort(&(&1["name"] <= &2["name"]))
        |> Enum.map(fn parameter ->
          Oasis.Spec.Parameter.build(path_expr, parameter)
        end)
        |> Enum.filter(&(&1 != nil))

      Map.put(acc, location, overrided_parameters)
    end)
  end
end
