defmodule Oasis.Spec.Path do
  @moduledoc false

  alias Oasis.Spec.{Document, Operation}

  @supported_http_verbs [
    "delete",
    "get",
    "head",
    "options",
    "patch",
    "post",
    "put"
  ]

  require Logger

  @doc """
  Format Path object's URI template into `Plug.Router` definition.

  For example:

    format /users/{id} to /users/:id
    format /users/{id*} to /users/:id
    format /users/{.id} to /users/:id
    format /users/{.id*} to /users/:id
    format /users/{;id} to /users/:id
    format /users/{;id*} to /users/:id
  """
  def format_url(url) do
    Regex.replace(~r/{.*?}/, url, fn matched, _ ->
      ":#{String.replace(matched, ["{", "}", ".", ";", "*"], "")}"
    end)
  end

  def supported_http_verbs(), do: @supported_http_verbs

  def build(%Document{normalized?: true} = root), do: root

  def build(%Document{schema: %{"paths" => paths}}) when not is_map(paths) do
    raise Oasis.InvalidSpecError,
          "OpenAPI Paths Object must be an object, got: #{inspect(paths, pretty: true)}"
  end

  def build(%Document{schema: schema} = root) do
    paths = schema["paths"] || %{}

    {paths, aliases, schema_sources} =
      Enum.reduce(paths, {%{}, %{}, %{}}, fn
        {"/" <> _ = path_expr, info}, {paths_acc, aliases_acc, sources_acc} ->
          formatted = format_url(path_expr)
          {mapped_path, path_sources} =
            map_path(
              path_expr,
              formatted,
              info,
              root.allow_normalized_parameters?
            )

          {
            Map.put(paths_acc, formatted, mapped_path),
            Map.put(aliases_acc, formatted, path_expr),
            Map.merge(sources_acc, path_sources)
          }

        {field, value}, {paths_acc, aliases_acc, sources_acc} ->
          {Map.put(paths_acc, field, value), aliases_acc, sources_acc}
      end)

    normalized_schema = Map.put(schema, "paths", paths)

    aliases =
      Map.merge(root.url_aliases || %{}, aliases, fn formatted, original, rebuilt ->
        if rebuilt == formatted, do: original, else: rebuilt
      end)

    schema_sources = Map.merge(root.schema_sources || %{}, schema_sources)

    %{
      root
      | schema: normalized_schema,
        reference_schema: root.reference_schema || schema,
        url_aliases: aliases,
        schema_sources: schema_sources,
        normalized?: true
    }
  end

  def build(schema) when is_map(schema) do
    schema
    |> Document.new()
    |> build()
  end

  defp map_path(path_expr, _formatted_path, info, _allow_normalized_parameters?)
       when not is_map(info) do
    raise Oasis.InvalidSpecError,
          "Path Item Object at `#{path_expr}` must be an object, got: #{inspect(info, pretty: true)}"
  end

  defp map_path(path_expr, formatted_path, info, allow_normalized_parameters?) do
    {global_params, rest} = Map.pop(info, "parameters", [])

    Enum.reduce(rest, {%{}, %{}}, fn {field, value}, {path_acc, sources_acc} ->
      {value, sources} =
        map_path_item_object(
          field,
          path_expr,
          formatted_path,
          value,
          global_params,
          allow_normalized_parameters?
        )

      {Map.put(path_acc, field, value), Map.merge(sources_acc, sources)}
    end)
  end

  defp map_path_item_object(
         http_verb,
         path_expr,
         formatted_path,
         operation,
         global_params,
         allow_normalized_parameters?
       )
       when http_verb in @supported_http_verbs do
    {operation, parameter_sources} =
      Operation.build_with_sources(
        path_expr,
        http_verb,
        operation,
        global_params,
        allow_normalized_parameters?
      )

    schema_sources =
      Map.new(parameter_sources, fn {{location, name}, source} ->
        {{:parameter, formatted_path, http_verb, location, name}, source}
      end)

    {operation, schema_sources}
  end

  defp map_path_item_object(
         "trace",
         path_expr,
         _formatted_path,
         _operation,
         _global_params,
         _allow_normalized_parameters?
       ) do
    raise Oasis.InvalidSpecError, "Not Support `trace` http method from `#{path_expr}` path"
  end

  defp map_path_item_object(
         _other_field,
         _path_expr,
         _formatted_path,
         value,
         _global_params,
         _allow_normalized_parameters?
       ) do
    {value, %{}}
  end
end
