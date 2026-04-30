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

  test "wrap existing compiled schemas" do
    root = ExJsonSchema.Schema.resolve(%{"type" => "string"})
    schema = JSONSchema.wrap(root)

    assert JSONSchema.raw_schema(schema) == %{"type" => "string"}
    assert JSONSchema.valid?(schema, "hello")
  end

  test "normalize validation errors" do
    schema =
      JSONSchema.compile!(%{
        "type" => "object",
        "properties" => %{
          "avatar" => %{"type" => "string"}
        }
      })

    upload = %Plug.Upload{
      content_type: "image/png",
      filename: "avatar.png",
      path: "/tmp/avatar.png"
    }

    assert {:error, [error]} = JSONSchema.validate(schema, %{"avatar" => upload})

    assert error.rule == :type
    assert error.path_pointer == "#/avatar"
    assert error.path_segments == ["avatar"]
    assert error.expected == ["string"]
    assert error.actual == "object"
    assert JSONSchema.format_error(error) =~ "Expected"
  end
end
