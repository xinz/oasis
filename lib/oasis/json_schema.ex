defmodule Oasis.JSONSchema do
  @moduledoc false

  alias __MODULE__.Error

  defstruct [:schema, :compiled, engine: :ex_json_schema, options: []]

  @opaque t :: %__MODULE__{
            schema: map(),
            compiled: term(),
            engine: atom(),
            options: keyword()
          }

  @type schema_ref :: t() | ExJsonSchema.Schema.Root.t() | map()

  @spec compile(map(), keyword()) :: {:ok, t()}
  def compile(schema, opts \\ []) when is_map(schema) and not is_struct(schema) do
    compiled = ExJsonSchema.Schema.resolve(schema, opts)
    {:ok, %__MODULE__{schema: schema, compiled: compiled, options: opts}}
  end

  @spec compile!(map(), keyword()) :: t()
  def compile!(schema, opts \\ []) do
    {:ok, compiled} = compile(schema, opts)
    compiled
  end

  @spec wrap(schema_ref()) :: t()
  def wrap(%__MODULE__{} = schema), do: schema

  def wrap(%ExJsonSchema.Schema.Root{schema: schema} = compiled) do
    %__MODULE__{schema: schema, compiled: compiled}
  end

  def wrap(schema) when is_map(schema) and not is_struct(schema) do
    compile!(schema)
  end

  @spec raw_schema(schema_ref()) :: map()
  def raw_schema(%__MODULE__{schema: schema}), do: schema
  def raw_schema(%ExJsonSchema.Schema.Root{schema: schema}), do: schema
  def raw_schema(schema) when is_map(schema) and not is_struct(schema), do: schema

  @spec validate(schema_ref(), term()) :: :ok | {:error, [Error.t()]}
  def validate(schema, data) do
    schema = wrap(schema)

    case ExJsonSchema.Validator.validate(schema.compiled, data, error_formatter: false) do
      :ok ->
        :ok

      {:error, errors} ->
        {:error, Enum.map(errors, &Error.from_validation_error/1)}
    end
  end

  @spec valid?(schema_ref(), term()) :: boolean()
  def valid?(schema, data) do
    validate(schema, data) == :ok
  end

  @spec format_error(Error.t()) :: String.t()
  def format_error(%Error{message: message}), do: message
end
