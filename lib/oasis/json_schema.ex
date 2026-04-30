defmodule Oasis.JSONSchema do
  @moduledoc false

  @default_compile_options [format_assertion: true, content_assertion: false]

  defstruct [:schema, :compiled, engine: :jsonschex, options: []]

  @opaque t :: %__MODULE__{
            schema: map(),
            compiled: JSONSchex.Types.Schema.t(),
            engine: atom(),
            options: keyword()
          }

  @type schema_ref :: t() | ExJsonSchema.Schema.Root.t() | map()

  @spec compile(map(), keyword()) :: {:ok, t()} | {:error, JSONSchex.Types.Error.t()}
  def compile(schema, opts \\ []) when is_map(schema) and not is_struct(schema) do
    compile_options = compile_options(opts)

    case JSONSchex.compile(schema, compile_options) do
      {:ok, compiled} ->
        {:ok, %__MODULE__{schema: schema, compiled: compiled, options: compile_options}}

      {:error, %JSONSchex.Types.Error{} = error} ->
        {:error, error}
    end
  end

  @spec compile!(map(), keyword()) :: t()
  def compile!(schema, opts \\ []) do
    case compile(schema, opts) do
      {:ok, compiled} -> compiled
      {:error, error} -> raise ArgumentError, JSONSchex.format_error(error)
    end
  end

  @spec wrap(schema_ref()) :: t()
  def wrap(%__MODULE__{} = schema), do: schema

  def wrap(%ExJsonSchema.Schema.Root{schema: schema}) do
    compile!(schema)
  end

  def wrap(schema) when is_map(schema) and not is_struct(schema) do
    compile!(schema)
  end

  @spec raw_schema(schema_ref()) :: map()
  def raw_schema(%__MODULE__{schema: schema}), do: schema
  def raw_schema(%ExJsonSchema.Schema.Root{schema: schema}), do: schema
  def raw_schema(schema) when is_map(schema) and not is_struct(schema), do: schema

  @spec validate(schema_ref(), term()) :: :ok | {:error, [JSONSchex.Types.Error.t()]}
  def validate(schema, data) do
    schema = wrap(schema)
    JSONSchex.validate(schema.compiled, data)
  end

  @spec valid?(schema_ref(), term()) :: boolean()
  def valid?(schema, data) do
    validate(schema, data) == :ok
  end

  @spec format_error(JSONSchex.Types.Error.t()) :: String.t()
  def format_error(%JSONSchex.Types.Error{} = error), do: JSONSchex.format_error(error)

  @spec path_pointer(JSONSchex.Types.Error.t()) :: String.t()
  def path_pointer(%JSONSchex.Types.Error{path: path}) do
    case List.wrap(path) do
      [] ->
        "#"

      segments ->
        encoded = Enum.map_join(segments, "/", &encode_segment/1)
        "#/#{encoded}"
    end
  end

  defp compile_options(opts) do
    Keyword.merge(@default_compile_options, opts)
  end

  defp encode_segment(segment) when is_integer(segment), do: Integer.to_string(segment)

  defp encode_segment(segment) do
    segment
    |> to_string()
    |> String.replace("~", "~0")
    |> String.replace("/", "~1")
  end
end
