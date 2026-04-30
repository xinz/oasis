defmodule Oasis.JSONSchema.Error do
  @moduledoc false

  defstruct [
    :rule,
    :path_pointer,
    :message,
    :expected,
    :actual,
    :raw,
    path_segments: []
  ]

  @type t :: %__MODULE__{
          rule: atom() | nil,
          path_segments: [String.t() | non_neg_integer()],
          path_pointer: String.t(),
          message: String.t(),
          expected: term(),
          actual: term(),
          raw: term()
        }

  @spec from_validation_error(ExJsonSchema.Validator.Error.t()) :: t()
  def from_validation_error(%ExJsonSchema.Validator.Error{error: error, path: path} = validation_error) do
    %__MODULE__{
      rule: derive_rule(error),
      path_segments: pointer_to_segments(path),
      path_pointer: normalize_pointer(path),
      message: to_string(error),
      expected: map_field(error, :expected),
      actual: map_field(error, :actual),
      raw: validation_error
    }
  end

  defp derive_rule(%module{}) do
    module
    |> Module.split()
    |> List.last()
    |> Macro.underscore()
    |> String.to_atom()
  end

  defp derive_rule(_), do: nil

  defp map_field(value, field) when is_map(value), do: Map.get(value, field)
  defp map_field(_value, _field), do: nil

  defp normalize_pointer(nil), do: "#"
  defp normalize_pointer(""), do: "#"
  defp normalize_pointer(path) when is_binary(path), do: path

  defp pointer_to_segments(nil), do: []
  defp pointer_to_segments(""), do: []
  defp pointer_to_segments("#"), do: []

  defp pointer_to_segments("#/" <> path) do
    path
    |> String.split("/", trim: true)
    |> Enum.map(&decode_segment/1)
  end

  defp pointer_to_segments(_path), do: []

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

defimpl String.Chars, for: Oasis.JSONSchema.Error do
  def to_string(%Oasis.JSONSchema.Error{message: message}), do: message
end
