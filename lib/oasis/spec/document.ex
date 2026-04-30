defmodule Oasis.Spec.Document do
  @moduledoc false

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
end
