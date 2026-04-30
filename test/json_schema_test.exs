defmodule Oasis.JSONSchemaTest do
  use ExUnit.Case

  alias Oasis.JSONSchema

  test "compile and validate raw schemas" do
    {:ok, schema} = JSONSchema.compile(%{"type" => "integer", "minimum" => 2})

    assert JSONSchema.raw_schema(schema) == %{"type" => "integer", "minimum" => 2}
    assert JSONSchema.valid?(schema, 2)
    refute JSONSchema.valid?(schema, 1)
    refute JSONSchema.valid?(schema, "2")
  end

  test "formats JSONSchex validation errors" do
    schema = JSONSchema.compile!(%{"type" => "string", "minLength" => 3})

    assert {:error, [error]} = JSONSchema.validate(schema, "a")
    assert error.rule in [:minLength, :min_length]
    assert JSONSchema.path_pointer(error) == "#"
    assert JSONSchema.format_error(error) =~ "less than minimum 3"
  end

  test "compilation errors bubble up from JSONSchex" do
    assert_raise ArgumentError, ~r/Keyword `?type`? must be one of|Keyword 'type' must be one of/, fn ->
      JSONSchema.compile!(%{"type" => "UNKNOWN_JSON_SCHEMA"})
    end
  end
end
