defmodule Oasis.Spec.RefExpander do
  @moduledoc false

  alias JSONSchex.Ref
  alias JSONSchex.Ref.Error
  alias Oasis.InvalidSpecError
  alias Oasis.Spec.Document

  @spec expand_refs(map(), keyword()) :: map()
  def expand_refs(document, opts \\ []) when is_map(document) do
    source_path = opts[:source_path]

    expand_value(document, document, source_path, source_path, [], [])
  end

  @spec expand_local_refs(map()) :: map()
  def expand_local_refs(document) when is_map(document) do
    expand_refs(document)
  end

  @spec resolve_local_ref!(map(), String.t()) :: term()
  def resolve_local_ref!(document, ref) when is_map(document) and is_binary(ref) do
    validate_local_ref!(ref)

    case ExJSONPointer.resolve(document, ref) do
      {:ok, resolved} ->
        resolved

      {:error, "not found"} ->
        raise InvalidSpecError, "Could not resolve local ref `#{ref}`"

      {:error, _reason} ->
        raise InvalidSpecError, "Expect a local JSON Pointer ref, but got: `#{ref}`"
    end
  end

  defp expand_value(root_document, value, source_path, base_uri, path, ref_stack)
       when is_list(value) do
    value
    |> Enum.with_index()
    |> Enum.map(fn {item, index} ->
      expand_value(root_document, item, source_path, base_uri, path ++ [index], ref_stack)
    end)
  end

  defp expand_value(root_document, %{"$ref" => ref}, source_path, base_uri, path, ref_stack) do
    case Ref.resolve(root_document, ref,
           source: source_path,
           base_uri: base_uri,
           loader: &Document.load_external/1
         ) do
      {:ok, resolution} ->
        ref_key = resolution.target_uri || ref

        ensure_acyclic_ref!(ref_key, ref, path, ref_stack)

        expand_value(
          resolution.target_document,
          resolution.target_value,
          resolution.target_source || source_path,
          next_base_uri(resolution, base_uri),
          path,
          [ref_key | ref_stack]
        )

      {:error, error} ->
        raise_ref_resolution_error!(error, ref)
    end
  end

  defp expand_value(root_document, value, source_path, base_uri, path, ref_stack)
       when is_map(value) do
    base_uri =
      case Map.get(value, "$id") do
        id when is_binary(id) -> resolve_base_uri(base_uri, id)
        _other -> base_uri
      end

    Enum.reduce(value, %{}, fn {key, nested_value}, acc ->
      if Map.has_key?(acc, key) do
        raise InvalidSpecError,
              "Defined a duplicated field: `#{key}` key as:\n#{inspect(%{key => nested_value}, pretty: true)} \n to \n#{inspect(acc, pretty: true)}"
      else
        Map.put(
          acc,
          key,
          expand_value(root_document, nested_value, source_path, base_uri, path ++ [key], ref_stack)
        )
      end
    end)
  end

  defp expand_value(_root_document, value, _source_path, _base_uri, _path, _ref_stack), do: value

  defp next_base_uri(%{target_uri: target_uri}, _base_uri) when is_binary(target_uri) do
    target_uri
    |> URI.parse()
    |> Map.put(:fragment, nil)
    |> URI.to_string()
    |> case do
      "" -> nil
      uri -> uri
    end
  end

  defp next_base_uri(%{target_source: target_source}, _base_uri) when is_binary(target_source) do
    target_source
  end

  defp next_base_uri(_resolution, base_uri), do: base_uri

  defp resolve_base_uri(nil, id), do: id

  defp resolve_base_uri(base_uri, ""), do: base_uri

  defp resolve_base_uri(base_uri, id) do
    case URI.parse(id).scheme do
      nil ->
        resolve_relative_base_uri(base_uri, id)

      _scheme ->
        # Absolute `$id` values must replace the current base URI as-is.
        #
        # This matters when Oasis starts from a filesystem `source_path` like
        # `/tmp/root.yaml` but the schema declares an absolute `$id` such as
        # `https://example.com/root.json`. If we treated that absolute `$id`
        # as relative, later fragment refs like `#/$defs/Name` would resolve
        # against the file path instead of the declared URI base.
        id
    end
  end

  defp resolve_relative_base_uri(base_uri, "#" <> _ = id) do
    base_uri
    |> URI.parse()
    |> Map.put(:fragment, String.trim_leading(id, "#"))
    |> URI.to_string()
  end

  defp resolve_relative_base_uri("/" <> _ = base_uri, id) do
    Path.expand(id, Path.dirname(base_uri))
  end

  defp resolve_relative_base_uri(base_uri, id) do
    URI.merge(base_uri, id) |> URI.to_string()
  end

  defp raise_ref_resolution_error!(%Error{kind: :missing_document, details: details}, _ref) do
    raise InvalidSpecError, missing_document_message(details)
  end

  defp raise_ref_resolution_error!(%Error{kind: :missing_target} = error, ref) do
    raise InvalidSpecError, missing_target_message(error, ref)
  end

  defp raise_ref_resolution_error!(%Error{kind: :invalid_ref}, ref) do
    raise InvalidSpecError,
          "Expect a local JSON Pointer ref or a relative file ref, but got: `#{ref}`"
  end

  defp raise_ref_resolution_error!(%Error{kind: :invalid_loader_response, details: details}, _ref) do
    raise InvalidSpecError, "Invalid external ref loader response: #{inspect(details)}"
  end

  defp missing_document_message({:missing_file, path}) do
    "Could not load external ref file `#{path}`"
  end

  defp missing_document_message({:yaml_parse_error, path, message}) do
    "Failed to parse external ref file `#{path}`: #{message}"
  end

  defp missing_document_message({:json_parse_error, path}) do
    "Failed to parse external ref file `#{path}` as json"
  end

  defp missing_document_message({:unsupported_format, path, ext}) do
    "Expect an external ref file be yaml/yml or json format, but got: `#{ext}` from `#{path}`"
  end

  defp missing_document_message(details) do
    "Failed to load external ref file: #{inspect(details)}"
  end

  defp missing_target_message(%Error{target_uri: nil, details: :unknown_local_resource}, ref) do
    "Could not resolve ref `#{ref}` because the local resource scope could not be determined"
  end

  defp missing_target_message(%Error{target_uri: target_uri, details: :missing_external_resource}, ref) do
    "Could not resolve ref `#{ref}` because the external resource `#{resource_uri(target_uri)}` was not available after loading"
  end

  defp missing_target_message(%Error{target_uri: target_uri, details: detail}, ref)
       when is_binary(target_uri) and detail in ["not found", :"not found"] do
    "Could not resolve ref `#{ref}` because target `#{target_uri}` was not found"
  end

  defp missing_target_message(%Error{target_uri: target_uri, details: detail}, ref)
       when is_binary(target_uri) and is_binary(detail) do
    "Could not resolve ref `#{ref}` because target `#{target_uri}` was not found (`#{detail}`)"
  end

  defp missing_target_message(%Error{target_uri: target_uri, details: detail}, ref)
       when is_binary(target_uri) do
    "Could not resolve ref `#{ref}` because target `#{target_uri}` was not found (#{inspect(detail)})"
  end

  defp missing_target_message(%Error{details: detail}, ref) do
    "Could not resolve ref `#{ref}` (#{inspect(detail)})"
  end

  defp resource_uri(target_uri) when is_binary(target_uri) do
    target_uri
    |> URI.parse()
    |> Map.put(:fragment, nil)
    |> URI.to_string()
  end

  defp ensure_acyclic_ref!(ref_key, ref, path, ref_stack) do
    if ref_key in ref_stack do
      raise InvalidSpecError,
            "Cyclic ref detected while expanding `#{ref}` at `#{format_path(path)}`"
    end
  end

  defp format_path([]), do: "#"

  defp format_path(path) do
    segments = Enum.map_join(path, "/", &path_segment_to_string/1)
    "#/#{segments}"
  end

  defp path_segment_to_string(segment) when is_integer(segment), do: Integer.to_string(segment)
  defp path_segment_to_string(segment) when is_binary(segment), do: segment
  defp path_segment_to_string(segment), do: inspect(segment)

  defp validate_local_ref!("#"), do: :ok
  defp validate_local_ref!("#/" <> _path), do: :ok

  defp validate_local_ref!(ref) do
    raise InvalidSpecError, "Expect a local JSON Pointer ref, but got: `#{ref}`"
  end
end
