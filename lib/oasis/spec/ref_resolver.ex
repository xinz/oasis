defmodule Oasis.Spec.RefResolver do
  @moduledoc false

  alias Oasis.InvalidSpecError

  @spec expand_local_refs(map()) :: map()
  def expand_local_refs(document) when is_map(document) do
    expand_value(document, document)
  end

  @spec resolve_local_ref!(map(), String.t() | ExJsonSchema.Schema.Ref.t()) :: term()
  def resolve_local_ref!(document, ref) when is_map(document) and is_binary(ref) do
    ref
    |> pointer_segments!()
    |> Enum.reduce(document, &resolve_segment!/2)
  end

  def resolve_local_ref!(document, %ExJsonSchema.Schema.Ref{location: :root, fragment: fragment})
      when is_map(document) and is_list(fragment) do
    Enum.reduce(fragment, document, &resolve_segment!/2)
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
              "Defined a duplicated field: `#{key}` key as:\n#{
                inspect(%{key => nested_value}, pretty: true)
              } \n to \n#{inspect(acc, pretty: true)}"
      else
        Map.put(acc, key, expand_value(document, nested_value))
      end
    end)
  end

  defp expand_value(_document, value), do: value

  defp pointer_segments!("#"), do: []

  defp pointer_segments!("#/" <> path) do
    path
    |> String.split("/", trim: true)
    |> Enum.map(&decode_segment/1)
  end

  defp pointer_segments!(ref) do
    raise InvalidSpecError, "Expect a local JSON Pointer ref, but got: `#{ref}`"
  end

  defp resolve_segment!(segment, value) when is_map(value) do
    case Map.fetch(value, segment) do
      {:ok, resolved} -> resolved
      :error -> raise InvalidSpecError, "Could not resolve local ref segment `#{segment}`"
    end
  end

  defp resolve_segment!(segment, value) when is_list(value) and is_integer(segment) do
    case Enum.fetch(value, segment) do
      {:ok, resolved} -> resolved
      :error -> raise InvalidSpecError, "Could not resolve local ref index `#{segment}`"
    end
  end

  defp resolve_segment!(segment, _value) do
    raise InvalidSpecError, "Could not resolve local ref segment `#{segment}`"
  end

  defp decode_segment(segment) do
    decoded =
      segment
      |> String.replace("~1", "/")
      |> String.replace("~0", "~")

    case Integer.parse(decoded) do
      {index, ""} -> index
      _ -> decoded
    end
  end
end
