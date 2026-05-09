defmodule Oasis.Spec.RefResolver do
  @moduledoc false

  alias Oasis.InvalidSpecError

  @spec expand_local_refs(map()) :: map()
  def expand_local_refs(document) when is_map(document) do
    expand_value(document, document)
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

  defp expand_value(document, value) when is_list(value) do
    Enum.map(value, &expand_value(document, &1))
  end

  defp expand_value(document, %{"$ref" => ref}) do
    document
    |> resolve_local_ref!(ref)
    |> then(&expand_value(document, &1))
  end

  defp expand_value(document, value) when is_map(value) do
    Enum.reduce(value, %{}, fn {key, nested_value}, acc ->
      if Map.has_key?(acc, key) do
        raise InvalidSpecError,
              "Defined a duplicated field: `#{key}` key as:\n#{inspect(%{key => nested_value}, pretty: true)} \n to \n#{inspect(acc, pretty: true)}"
      else
        Map.put(acc, key, expand_value(document, nested_value))
      end
    end)
  end

  defp expand_value(_document, value), do: value

  defp validate_local_ref!("#"), do: :ok
  defp validate_local_ref!("#/" <> _path), do: :ok

  defp validate_local_ref!(ref) do
    raise InvalidSpecError, "Expect a local JSON Pointer ref, but got: `#{ref}`"
  end
end
