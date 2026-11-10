defmodule Mix.Oasis.SchemaPrunerTest do
  use ExUnit.Case, async: true

  alias Mix.Oasis.SchemaPruner

  @entry "#/paths/~1users/post/requestBody/content/application~1json/schema"
  @base_uri "/tmp/api/openapi.yaml"

  defp prepare(schema, root_spec, loader \\ nil) do
    Mix.Oasis.prepare_json_schema!(schema,
      root_spec: root_spec,
      entry: @entry,
      base_uri: @base_uri,
      loader: loader
    )
  end

  defp root_spec(schema, extra \\ %{}) do
    Map.merge(
      %{
        "openapi" => "3.1.0",
        "info" => %{"title" => "t", "version" => "1"},
        "paths" => %{
          "/users" => %{
            "post" => %{
              "requestBody" => %{"content" => %{"application/json" => %{"schema" => schema}}}
            }
          }
        }
      },
      extra
    )
  end

  defp valid?(schema, value) do
    {:ok, compiled} = JSONSchex.compile(schema, format_assertion: true, content_assertion: false)
    JSONSchex.validate(compiled, value) == :ok
  end

  defp size(term), do: byte_size(inspect(term, limit: :infinity, printable_limit: :infinity))

  test "drops the OpenAPI document parts that are not referenced" do
    schema = %{"type" => "object", "properties" => %{"name" => %{"type" => "string"}}}

    prepared = prepare(schema, root_spec(schema))

    refute Map.has_key?(prepared, "paths")
    refute Map.has_key?(prepared, "info")
    assert valid?(prepared, %{"name" => "Ada"})
    refute valid?(prepared, %{"name" => 1})
  end

  test "keeps only the referenced local components" do
    schema = %{"$ref" => "#/components/schemas/User"}

    components = %{
      "components" => %{
        "schemas" => %{
          "User" => %{
            "type" => "object",
            "required" => ["address"],
            "properties" => %{"address" => %{"$ref" => "#/components/schemas/Address"}}
          },
          "Address" => %{"type" => "object", "required" => ["city"]},
          "Unused" => %{"type" => "integer"}
        }
      }
    }

    prepared = prepare(schema, root_spec(schema, components))

    assert Map.keys(prepared["components"]["schemas"]) |> Enum.sort() == ["Address", "User"]
    assert valid?(prepared, %{"address" => %{"city" => "Aarhus"}})
    refute valid?(prepared, %{"address" => %{}})
  end

  test "keeps recursive components" do
    schema = %{"$ref" => "#/components/schemas/Node"}

    components = %{
      "components" => %{
        "schemas" => %{
          "Node" => %{
            "type" => "object",
            "required" => ["name"],
            "properties" => %{"next" => %{"$ref" => "#/components/schemas/Node"}}
          },
          "Unused" => %{"type" => "integer"}
        }
      }
    }

    prepared = prepare(schema, root_spec(schema, components))

    assert Map.keys(prepared["components"]["schemas"]) == ["Node"]
    assert valid?(prepared, %{"name" => "a", "next" => %{"name" => "b"}})
    refute valid?(prepared, %{"name" => "a", "next" => %{}})
  end

  test "keeps only the referenced parts of external documents" do
    schema = %{"$ref" => "./model.json#/components/schemas/User"}

    external = %{
      "info" => %{"title" => String.duplicate("x", 10_000)},
      "components" => %{
        "schemas" => %{
          "User" => %{
            "type" => "object",
            "required" => ["name"],
            "properties" => %{"pet" => %{"$ref" => "./model.json#/components/schemas/Pet"}}
          },
          "Pet" => %{"type" => "string"},
          "Unused" => %{"description" => String.duplicate("y", 10_000)}
        }
      }
    }

    loader = fn "/tmp/api/model.json" = base_uri -> {:ok, %{document: external, base_uri: base_uri}} end

    prepared = prepare(schema, root_spec(schema), loader)

    encoded = inspect(prepared, limit: :infinity, printable_limit: :infinity)

    assert size(prepared) < 2_000
    assert encoded =~ "Pet"
    refute encoded =~ "Unused"
    refute encoded =~ "title"
    assert valid?(prepared, %{"name" => "Ada"})
    refute valid?(prepared, %{})
  end

  test "follows refs between external documents" do
    schema = %{"$ref" => "./a.json#/components/schemas/A"}

    docs = %{
      "/tmp/api/a.json" => %{
        "components" => %{
          "schemas" => %{
            "A" => %{"properties" => %{"b" => %{"$ref" => "./b.json#/definitions/B"}}},
            "Other" => %{"type" => "boolean"}
          }
        }
      },
      "/tmp/api/b.json" => %{
        "definitions" => %{
          "B" => %{"type" => "integer"},
          "Other" => %{"type" => "boolean"}
        }
      }
    }

    loader = fn uri -> {:ok, %{document: Map.fetch!(docs, uri), base_uri: uri}} end

    prepared = prepare(schema, root_spec(schema), loader)

    encoded = inspect(prepared, limit: :infinity)
    refute encoded =~ "Other"
    assert valid?(prepared, %{"b" => 1})
    refute valid?(prepared, %{"b" => "x"})
  end

  test "returns the bundle untouched when anchors are used" do
    bundle = %{
      "$id" => "/tmp/api/openapi.yaml",
      "$ref" => "#foo",
      "paths" => %{"/users" => %{}},
      "components" => %{"schemas" => %{"Foo" => %{"$anchor" => "foo", "type" => "string"}}}
    }

    root_spec = Map.drop(bundle, ["$ref"])

    assert SchemaPruner.prune(bundle, root_spec) == bundle
  end

  test "returns the bundle untouched when a ref cannot be resolved" do
    bundle = %{
      "$id" => "/tmp/api/openapi.yaml",
      "$ref" => "#/components/schemas/Missing",
      "paths" => %{"/users" => %{}}
    }

    root_spec = Map.drop(bundle, ["$ref"])

    assert SchemaPruner.prune(bundle, root_spec) == bundle
  end
end
