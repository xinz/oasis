defmodule Oasis.Spec.OpenAPIRefResolver do
  @moduledoc """
  Resolves the structural OpenAPI Reference Objects selected by Oasis preparation.

  This module is intentionally OpenAPI-aware and deliberately **not** a generic
  JSON Schema `$ref` expander. It selects structural OpenAPI Reference Object
  locations such as:

  - Path Item Objects
  - Parameter Objects
  - Request Body Objects
  - Response Objects
  - Security Scheme Objects

  The generic `$ref` mechanics are delegated to `JSONSchex.Ref.resolve_selected/2`:
  URI resolution, JSON Pointer lookup, external loading, base URI propagation,
  and cycle detection.

  Schema Object `$ref` values are not selected here. They are preserved so
  `JSONSchex.bundle_fragment/2` can resolve the schema graph with proper JSON
  Schema Draft 2020-12 semantics.

  ## Selection rules

  `openapi_reference_object?/2` returns `true` only for the following
  structural OpenAPI Reference Object locations, and `false` everywhere else
  (including any Schema Object location):

  - `#/paths/{url}` — Path Item Object
  - `#/paths/{url}/parameters/{i}` — path-item-level Parameter Object
  - `#/paths/{url}/{verb}/parameters/{i}` — operation-level Parameter Object
  - `#/paths/{url}/{verb}/requestBody` — Request Body Object
  - `#/paths/{url}/{verb}/responses/{status}` — Response Object
  - `#/components/securitySchemes/{name}` — Security Scheme Object

  where `{url}` starts with `/` and `{verb}` is one of the standard HTTP
  methods Oasis generates routes for (`get`, `head`, `post`, `put`, `patch`,
  `delete`, `options`). Anything outside this list — Schema Object refs,
  callbacks, links, examples, server objects, etc. — is left intact.

  ## Loader

  External OpenAPI references (e.g. `./common.yaml#/components/parameters/UserId`)
  are loaded through `JSONSchex.Ref.resolve_selected/2`'s `:loader` option.
  `resolve/2` defaults `:loader` to `&Oasis.Spec.Document.load_external/1`
  via `Keyword.put_new/3`, so callers may override it by passing their own
  loader. JSONSchex accepts `{:ok, schema}` or an atom-keyed metadata wrapper
  `{:ok, %{document: schema, base_uri: base_uri}}`.

  JSONSchex owns resource base propagation for loaded documents. Oasis's role in
  this resolver is limited to choosing which OpenAPI Reference Objects should be
  resolved before generation.

  ## Caller `opts` contract

  `resolve/2` is deliberately opinionated about the options it forwards to
  `JSONSchex.Ref.resolve_selected/2`:

  - `:select` — **force-overridden** to `&openapi_reference_object?/2`. A
    caller-supplied `:select` is silently discarded. This is intentional:
    the whole point of this module is to fix the OpenAPI selection policy
    so the Oasis/JSONSchex boundary (Schema Object refs are preserved for
    JSONSchex) stays consistent across all callers.
  - `:loader` — **defaulted** via `Keyword.put_new/3`. Callers may override
    it with a custom loader, or pass `loader: nil` to opt out of external
    loading entirely.
  - `:base_uri` — **caller-controlled**. Used by JSONSchex to resolve
    relative external OpenAPI refs. The `resolve/1` arity-1 form sets it to
    `document.source_path` automatically; the arity-2 form takes whatever
    the caller passes.
  - Any other option recognized by `JSONSchex.Ref.resolve_selected/2` is
    forwarded unchanged.
  """

  alias JSONSchex.Ref
  alias Oasis.InvalidSpecError
  alias Oasis.Spec.Document

  @operation_fields Oasis.Spec.Path.supported_http_verbs()

  @doc """
  Resolves OpenAPI Reference Objects inside a loaded `Oasis.Spec.Document`.

  The returned document keeps Schema Object refs intact, but selected path items,
  parameters, request bodies, responses, and security schemes are dereferenced.
  Response refs are prepared eagerly even though current request-handler
  generation does not otherwise consume response schemas; a missing selected
  response resource therefore remains an invalid specification.
  """
  @spec resolve(Document.t()) :: Document.t()
  def resolve(%Document{schema: schema} = document) do
    %{document | schema: resolve(schema, base_uri: document.source_path)}
  end

  @doc """
  Resolves OpenAPI Reference Objects in a decoded OpenAPI map.

  ## Options

  - `:base_uri` — file path or URI used to resolve relative external OpenAPI
    refs. Required when the document contains external refs.
  - `:loader` — optional. Defaults to `&Oasis.Spec.Document.load_external/1`. Pass
    a custom function to use your own loader, or `nil` to disable external loading.
    Success may return `{:ok, schema}` or an atom-keyed metadata wrapper
    `{:ok, %{document: schema, base_uri: base_uri}}`.
  - Any other option recognized by `JSONSchex.Ref.resolve_selected/2` is
    forwarded unchanged.

  ## Reserved options

  - `:select` — **force-overridden** to `&openapi_reference_object?/2`. A
    caller-supplied `:select` is silently discarded. See the moduledoc
    "Caller `opts` contract" section for the rationale.
  """
  @spec resolve(map(), keyword()) :: map()
  def resolve(%{} = schema, opts \\ []) do
    opts =
      opts
      |> Keyword.put(:select, &openapi_reference_object?/2)
      |> Keyword.put_new(:loader, &Document.load_external/1)

    case Ref.resolve_selected(schema, opts) do
      {:ok, resolved} ->
        validate_reference_object_targets!(resolved, opts)

      {:error, %Ref.Error{} = error} ->
        location = source_pointer(Enum.reverse(error.path), opts[:base_uri])
        raise InvalidSpecError, message: "#{invalid_spec_message(error)} at `#{location}`"
    end
  end

  @doc """
  Returns `true` when the path/node pair represents an OpenAPI Reference Object
  location that Oasis needs to dereference before generation.

  Schema Object locations intentionally return `false` so JSON Schema refs remain
  available for JSONSchex fragment compilation/bundling.
  """
  @spec openapi_reference_object?(list(), map()) :: boolean()
  def openapi_reference_object?(["paths", path], %{"$ref" => _}) when is_binary(path) do
    String.starts_with?(path, "/")
  end

  def openapi_reference_object?(["paths", path, "parameters", index], %{"$ref" => _})
      when is_binary(path) and is_integer(index) do
    String.starts_with?(path, "/")
  end

  def openapi_reference_object?(["paths", path, method, "parameters", index], %{"$ref" => _})
      when is_binary(path) and method in @operation_fields and is_integer(index) do
    String.starts_with?(path, "/")
  end

  def openapi_reference_object?(["paths", path, method, "requestBody"], %{"$ref" => _})
      when is_binary(path) and method in @operation_fields do
    String.starts_with?(path, "/")
  end

  def openapi_reference_object?(["paths", path, method, "responses", status], %{"$ref" => _})
      when is_binary(path) and method in @operation_fields and is_binary(status) do
    String.starts_with?(path, "/") and response_object_field?(status)
  end

  def openapi_reference_object?(["components", "securitySchemes", name], %{"$ref" => _})
      when is_binary(name),
      do: true

  def openapi_reference_object?(_path, _node), do: false

  defp validate_reference_object_targets!(schema, opts) do
    schema
    |> reference_object_targets()
    |> Enum.each(fn {path, target} ->
      unless is_map(target) do
        raise InvalidSpecError,
          message:
            "Resolved OpenAPI Reference Object at `#{source_pointer(path, opts[:base_uri])}` must be an object, got: #{inspect(target)}"
      end
    end)

    schema
  end

  defp reference_object_targets(schema) do
    security_scheme_targets(schema) ++ path_targets(schema)
  end

  defp security_scheme_targets(%{"components" => %{"securitySchemes" => schemes}})
       when is_map(schemes) do
    Enum.map(schemes, fn {name, scheme} ->
      {["components", "securitySchemes", name], scheme}
    end)
  end

  defp security_scheme_targets(_schema), do: []

  defp path_targets(%{"paths" => paths}) when is_map(paths) do
    Enum.flat_map(paths, fn
      {path, path_item} when is_binary(path) ->
        if String.starts_with?(path, "/") do
          path = ["paths", path]
          [{path, path_item} | nested_path_item_targets(path, path_item)]
        else
          []
        end

      _other ->
        []
    end)
  end

  defp path_targets(_schema), do: []

  defp nested_path_item_targets(path, path_item) when is_map(path_item) do
    parameter_targets(path_item["parameters"], path ++ ["parameters"]) ++
      Enum.flat_map(@operation_fields, fn method ->
        operation_targets(path ++ [method], path_item[method])
      end)
  end

  defp nested_path_item_targets(_path, _path_item), do: []

  defp operation_targets(path, operation) when is_map(operation) do
    parameter_targets(operation["parameters"], path ++ ["parameters"]) ++
      optional_object_target(operation, "requestBody", path) ++
      response_targets(operation["responses"], path ++ ["responses"])
  end

  defp operation_targets(_path, _operation), do: []

  defp parameter_targets(parameters, path) when is_list(parameters) do
    parameters
    |> Enum.with_index()
    |> Enum.map(fn {parameter, index} -> {path ++ [index], parameter} end)
  end

  defp parameter_targets(_parameters, _path), do: []

  defp optional_object_target(container, key, path) do
    if Map.has_key?(container, key), do: [{path ++ [key], container[key]}], else: []
  end

  defp response_targets(responses, path) when is_map(responses) do
    responses
    |> Enum.filter(fn {status, _response} -> response_object_field?(status) end)
    |> Enum.map(fn {status, response} -> {path ++ [status], response} end)
  end

  defp response_targets(_responses, _path), do: []

  defp response_object_field?("x-" <> _extension), do: false
  defp response_object_field?(_status), do: true

  defp source_pointer(path, nil), do: ExJSONPointer.encode_path(path, format: "uri_fragment")

  defp source_pointer(path, base_uri) do
    to_string(base_uri) <> ExJSONPointer.encode_path(path, format: "uri_fragment")
  end

  defp invalid_spec_message(%Ref.Error{kind: :invalid_ref_value, ref: ref}) do
    "Expect `$ref` value to be a string, but got: `#{inspect(ref)}`"
  end

  defp invalid_spec_message(%Ref.Error{kind: :missing_base_uri, ref: ref}) do
    "Could not resolve external OpenAPI ref `#{ref}` because the containing document base URI is missing"
  end

  defp invalid_spec_message(%Ref.Error{kind: :missing_loader, ref: ref, uri: uri}) do
    "Could not resolve external OpenAPI ref `#{ref}` as `#{uri}` because no loader was provided"
  end

  defp invalid_spec_message(%Ref.Error{kind: :missing_external_document, ref: ref, uri: uri, reason: reason}) do
    "Could not resolve external OpenAPI ref `#{ref}` as `#{uri}`: #{inspect(reason)}"
  end

  defp invalid_spec_message(%Ref.Error{kind: :missing_target, ref: ref, uri: uri, reason: reason}) do
    "Could not resolve OpenAPI ref `#{ref}` as `#{uri}`: #{reason}"
  end

  defp invalid_spec_message(%Ref.Error{kind: :cycle_detected, ref: ref, uri: uri}) do
    "Could not resolve OpenAPI ref `#{ref}` because it creates a cycle at `#{uri}`"
  end

  defp invalid_spec_message(%Ref.Error{kind: :invalid_loader_response, ref: ref, uri: uri, reason: reason}) do
    "Invalid external OpenAPI ref loader response for `#{ref}` as `#{uri}`: #{inspect(reason)}"
  end

  defp invalid_spec_message(%Ref.Error{} = error), do: Exception.message(error)
end
