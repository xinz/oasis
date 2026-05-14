defmodule Oasis.Spec.Document do
  @moduledoc false

  alias Oasis.JSON
  alias Oasis.{FileNotFoundError, InvalidSpecError}

  @enforce_keys [:schema]
  defstruct [:schema, :source_path, :format]

  @type t :: %__MODULE__{
          schema: map(),
          source_path: String.t() | nil,
          format: String.t() | nil
        }

  @spec new(map(), keyword()) :: t()
  def new(schema, opts \\ []) when is_map(schema) do
    %__MODULE__{
      schema: schema,
      source_path: opts[:source_path],
      format: opts[:format]
    }
  end

  @spec load(String.t()) :: {:ok, {map(), keyword()}} | {:error, Exception.t()}
  def load(path) when is_binary(path) do
    case load_file(path) do
      {:ok, %{document: document, source: source, format: format}} ->
        {:ok, {document, [source_path: source, format: format]}}

      {:error, {:missing_file, _path, message}} when is_binary(message) ->
        {:error, %FileNotFoundError{message: message}}

      {:error, {:missing_file, path, posix}} ->
        {:error, %FileNotFoundError{message: "Failed to open file #{inspect(path)} with error #{posix}"}}

      {:error, {:yaml_parse_error, _path, message}} ->
        {:error, %InvalidSpecError{message: "Failed to parse yaml file: #{message}"}}

      {:error, {:json_parse_error, _path, content}} ->
        {:error, %InvalidSpecError{message: "Failed to parse json file: `#{content}`"}}

      {:error, {:unsupported_format, _path, ext}} ->
        {:error,
         %InvalidSpecError{
           message: "Expect a yml/yaml or json format file, but got: `#{ext}`"
         }}

      {:error, {:yaml_load_error, path, reason}} ->
        {:error,
         %InvalidSpecError{message: "Failed to load yaml file `#{path}`: #{inspect(reason)}"}}
    end
  end

  @spec load_external(String.t()) :: JSONSchex.Ref.loader_result()
  def load_external(path) when is_binary(path) do
    case load_file(path) do
      {:ok, %{document: document, source: source}} ->
        {:ok, %{document: document, source: source}}

      {:error, {:missing_file, path, _details}} ->
        {:error, {:missing_file, path}}

      {:error, {:yaml_parse_error, path, message}} ->
        {:error, {:yaml_parse_error, path, message}}

      {:error, {:json_parse_error, path, _content}} ->
        {:error, {:json_parse_error, path}}

      {:error, {:unsupported_format, path, ext}} ->
        {:error, {:unsupported_format, path, ext}}

      {:error, {:yaml_load_error, path, reason}} ->
        {:error, {:yaml_load_error, path, reason}}
    end
  end

  defp load_file(path) do
    ext = String.downcase(Path.extname(path))

    case ext do
      ext when ext in [".yaml", ".yml"] ->
        load_yaml(path, ext)

      ".json" ->
        load_json(path)

      _other ->
        {:error, {:unsupported_format, path, ext}}
    end
  end

  defp load_yaml(path, ext) do
    case YamlElixir.read_from_file(path) do
      {:ok, document} ->
        {:ok, %{document: document, source: path, format: format_from_ext(ext)}}

      {:error, %YamlElixir.FileNotFoundError{message: message}} ->
        {:error, {:missing_file, path, message}}

      {:error, %YamlElixir.ParsingError{message: message}} ->
        {:error, {:yaml_parse_error, path, message}}

      {:error, reason} ->
        {:error, {:yaml_load_error, path, reason}}
    end
  end

  defp load_json(path) do
    case File.read(path) do
      {:ok, content} ->
        case JSON.decode(content) do
          {:ok, document} ->
            {:ok, %{document: document, source: path, format: "json"}}

          {:error, _reason} ->
            {:error, {:json_parse_error, path, content}}
        end

      {:error, posix} ->
        {:error, {:missing_file, path, posix}}
    end
  end

  defp format_from_ext(".yaml"), do: "yaml"
  defp format_from_ext(ext), do: ext
end
