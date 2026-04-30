defmodule Oasis.Spec.Utils do
  @moduledoc false

  alias Oasis.Spec.{Document, RefResolver}

  @type schema_container :: Document.t() | %{schema: map()}

  @doc """
  Expand and place all `$ref` properties with the corresponding fragments.
  """
  @spec expand_ref(schema_container) :: schema_container
  def expand_ref(%{schema: schema} = root) do
    %{root | schema: RefResolver.expand_local_refs(schema)}
  end
end
