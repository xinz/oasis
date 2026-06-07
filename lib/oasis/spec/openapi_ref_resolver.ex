defmodule Oasis.Spec.OpenAPIRefResolver do
  @moduledoc """
  Resolves OpenAPI Reference Objects needed by Oasis generation.

  This module is intentionally OpenAPI-aware and deliberately **not** a generic
  JSON Schema `$ref` expander. It selects structural OpenAPI Reference Object
  locations such as:

  - Path Item Objects
  - Parameter Objects
  - Request Body Objects
  - Response Objects

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

  where `{url}` starts with `/` and `{verb}` is one of the standard HTTP
  methods Oasis generates routes for (`get`, `head`, `post`, `put`, `patch`,
  `delete`, `options`). Anything outside this list — Schema Object refs,
  callbacks, links, examples, server objects, etc. — is left intact.

  ## Loader

  External OpenAPI references (e.g. `./common.yaml#/components/parameters/UserId`)
  are loaded through `JSONSchex.Ref.resolve_selected/2`'s `:loader` option.
  `resolve/2` defaults `:loader` to `&Oasis.Spec.Document.load_external/1`
  via `Keyword.put_new/3`, so callers may override it by passing their own
  loader. Loader wrapper responses use atom metadata keys only:
  `{:ok, %{document: schema, base_uri: base_uri}}` (see the JSONSchex docs).

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

  The returned document keeps Schema Object refs intact, but path items,
  parameters, request bodies, and responses that Oasis needs for generation are
  dereferenced.
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
    Loader wrapper responses must use atom metadata keys only: `{:ok, %{document: schema,
    base_uri: base_uri}}`.
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
        resolved

      {:error, %Ref.Error{} = error} ->
        raise InvalidSpecError, message: invalid_spec_message(error)
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

  def openapi_reference_object?(["paths", path, method, "responses", _status], %{"$ref" => _})
      when is_binary(path) and method in @operation_fields do
    String.starts_with?(path, "/")
  end

  def openapi_reference_object?(_path, _node), do: false

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
