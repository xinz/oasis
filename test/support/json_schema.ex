defmodule Oasis.Test.JSONSchema do
  @moduledoc false

  @compile_options [format_assertion: true, content_assertion: false]

  def compile!(schema) when is_map(schema) or is_boolean(schema) do
    case JSONSchex.compile(schema, @compile_options) do
      {:ok, compiled} -> compiled
      {:error, error} -> raise ArgumentError, JSONSchex.format_error(error)
    end
  end
end
