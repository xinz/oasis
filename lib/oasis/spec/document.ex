defmodule Oasis.Spec.Document do
  @moduledoc """
  Internal representation of a loaded OpenAPI document.

  `Oasis.Spec.Document` is responsible only for loading and tracking source
  metadata for YAML/JSON OpenAPI documents. It intentionally does not interpret
  OpenAPI structures or JSON Schema semantics.

  The `:source_path` field is important because it becomes the base URI/path used
  by:

  - `Oasis.Spec.OpenAPIRefResolver` when resolving external OpenAPI Reference Objects
  - `JSONSchex.bundle_fragment/2` when schema refs need relative file resolution

  External loading returns JSONSchex-compatible loader metadata with `:base_uri`
  so loaded files can resolve their own relative refs correctly.
  """

  alias Oasis.{FileNotFoundError, InvalidSpecError}

  @enforce_keys [:schema]
  defstruct [:schema, :source_path, :format, url_aliases: %{}]

  @type t :: %__MODULE__{
          schema: map(),
          source_path: String.t() | nil,
          format: String.t() | nil,
          url_aliases: %{optional(String.t()) => String.t()}
        }

  @doc """
  Wraps a decoded OpenAPI map with source metadata.

  Options:

  - `:source_path` - file path the document was loaded from (used as base URI).
  - `:format` - `"yaml"`, `"yml"`, or `"json"`.
  - `:url_aliases` - map of post-processed (Plug-style) URL key to the original
    OpenAPI URL key. Populated by `Oasis.Spec.Path.build/1`; preserved here so
    downstream code can report locations using the user's original spec syntax.
  """
  @spec new(map(), keyword()) :: t()
  def new(schema, opts \\ []) when is_map(schema) do
    %__MODULE__{
      schema: schema,
      source_path: opts[:source_path],
      format: opts[:format],
      url_aliases: Keyword.get(opts, :url_aliases, %{})
    }
  end

  @doc """
  Loads a root OpenAPI document from a YAML/YML or JSON file.

  On success this returns the decoded document with options suitable for
  `new/2`. On failure it returns Oasis user-facing file/spec exceptions.
  """
  @spec load(String.t()) :: {:ok, {map(), keyword()}} | {:error, Exception.t()}
  def load(path) when is_binary(path) do
    case load_file(path) do
      {:ok, %{document: document, source: source, format: format}} when is_map(document) ->
        {:ok, {document, [source_path: source, format: format]}}

      {:ok, %{source: source}} ->
        {:error, %InvalidSpecError{message: "OpenAPI document root must be an object: #{inspect(source)}"}}

      {:error, {"missing_file", _path, message}} when is_binary(message) ->
        {:error, %FileNotFoundError{message: message}}

      {:error, {"missing_file", path, posix}} ->
        {:error, %FileNotFoundError{message: "Failed to open file #{inspect(path)} with error #{posix}"}}

      {:error, {"yaml_parse_error", _path, message}} ->
        {:error, %InvalidSpecError{message: "Failed to parse yaml file: #{message}"}}

      {:error, {"json_parse_error", _path, content}} ->
        {:error, %InvalidSpecError{message: "Failed to parse json file: `#{content}`"}}

      {:error, {"unsupported_format", _path, ext}} ->
        {:error,
         %InvalidSpecError{
           message: "Expect a yml/yaml or json format file, but got: `#{ext}`"
         }}
    end
  end

  @typedoc """
  String status code used in `load_external_error()`.

  Allowed values are:

  - `"missing_file"`
  - `"yaml_parse_error"`
  - `"json_parse_error"`
  - `"unsupported_format"`

  Elixir typespecs cannot enumerate string literals directly, so this remains
  `String.t()` at the type level and the fixed set is documented here.
  """
  @type load_external_error_status :: String.t()

  @typedoc """
  Structured error returned by `load_external/1`.

  The first tuple element is a fixed string status code rather than an atom.
  The remaining elements carry the offending file path plus any extra detail so
  callers (most importantly the JSONSchex loader pipeline and
  `Oasis.Spec.OpenAPIRefResolver`) can build precise diagnostics.
  """
  @type load_external_error ::
          {load_external_error_status(), String.t()}
          | {load_external_error_status(), String.t(), String.t()}
          | {load_external_error_status(), String.t(), term()}

  @doc """
  Loader callback for external OpenAPI and JSON Schema resources.

  ## Contract

  `load_external/1` implements the JSONSchex loader contract:

      load_external(path :: String.t()) ::
          {:ok, %{document: map() | boolean(), base_uri: String.t()}}
        | {:error, load_external_error()}

  - **`:document`** — the decoded YAML/JSON document. OpenAPI resources are
    expected to be maps; JSON Schema resources may also be boolean schemas.
  - **`:base_uri`** — the resolved file path. Used by JSONSchex (and by
    `Oasis.Spec.OpenAPIRefResolver`) to resolve relative refs that appear
    **inside** the loaded document against the right base.

  ## Where it is used

  - Default `:loader` for `JSONSchex.bundle_fragment/2` calls inside
    `Mix.Oasis.prepare_json_schema!/2`.
  - Default `:loader` for `Oasis.Spec.OpenAPIRefResolver.resolve/2` when
    following external OpenAPI Reference Objects (e.g.
    `$ref: "./common.yaml#/components/parameters/UserId"`).

  Callers wanting in-memory or test-only loaders may override `:loader` with
  any function matching this signature, or pass `loader: nil` to opt out of
  external loading entirely (any unresolved external `$ref` then raises).
  """
  @spec load_external(String.t()) ::
          {:ok, %{document: map() | boolean(), base_uri: String.t()}}
          | {:error, load_external_error()}
  def load_external(path) when is_binary(path) do
    case load_file(path) do
      {:ok, %{document: document, source: source}} ->
        {:ok, %{document: document, base_uri: source}}

      {:error, {"missing_file", path, _details}} ->
        {:error, {"missing_file", path}}

      {:error, {"yaml_parse_error", path, message}} ->
        {:error, {"yaml_parse_error", path, message}}

      {:error, {"json_parse_error", path, _content}} ->
        {:error, {"json_parse_error", path}}

      {:error, {"unsupported_format", path, ext}} ->
        {:error, {"unsupported_format", path, ext}}
    end
  end

  defp load_file(path) do
    source_path = normalize_local_path(path)
    ext = String.downcase(Path.extname(path))

    case ext do
      ext when ext in [".yaml", ".yml"] ->
        load_yaml(source_path, path, ext)

      ".json" ->
        load_json(source_path, path)

      _other ->
        {:error, {"unsupported_format", path, ext}}
    end
  end

  defp load_yaml(source_path, display_path, ext) do
    case YamlElixir.read_from_file(source_path) do
      {:ok, document} ->
        {:ok, %{document: document, source: source_path, format: format_from_ext(ext)}}

      {:error, %YamlElixir.FileNotFoundError{message: message}} ->
        {:error, {"missing_file", display_path, rewrite_message_path(message, source_path, display_path)}}

      {:error, %YamlElixir.ParsingError{message: message}} ->
        {:error, {"yaml_parse_error", display_path, message}}
    end
  end

  defp load_json(source_path, display_path) do
    case File.read(source_path) do
      {:ok, content} ->
        case Jason.decode(content) do
          {:ok, document} ->
            {:ok, %{document: document, source: source_path, format: "json"}}

          {:error, _reason} ->
            {:error, {"json_parse_error", display_path, content}}
        end

      {:error, posix} ->
        {:error, {"missing_file", display_path, posix}}
    end
  end

  defp rewrite_message_path(message, source_path, display_path) do
    String.replace(message, inspect(source_path), inspect(display_path))
  end

  defp normalize_local_path(path) do
    case URI.parse(path) do
      %URI{scheme: nil} -> Path.expand(path)
      _uri -> path
    end
  end

  defp format_from_ext(".yaml"), do: "yaml"
  defp format_from_ext(ext), do: String.trim_leading(ext, ".")
end
