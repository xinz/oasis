defmodule Oasis.Spec.Utils do
  @moduledoc false

  alias Oasis.Spec.RefResolver

  @type json_schema_root :: ExJsonSchema.Schema.Root.t()

  @doc """
  Expand and place all `$ref` properties with the corresponding fragments.
  """
  @spec expand_ref(json_schema_root) :: json_schema_root
  def expand_ref(%{schema: schema} = root) do
    %{root | schema: RefResolver.expand_local_refs(schema)}
  end
end
