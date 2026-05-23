defmodule Oasis.Spec.OpenAPIRefResolverTest do
  use ExUnit.Case

  alias Oasis.Spec.OpenAPIRefResolver

  test "resolves OpenAPI parameter refs but preserves schema refs" do
    {:ok, document} =
      YamlElixir.read_from_string("""
      components:
        parameters:
          ContentQueryParam:
            name: content
            in: query
            schema:
              $ref: "#/components/schemas/Contents"
        schemas:
          Contents:
            type: array
            items:
              $ref: "#/components/schemas/Content"
          Content:
            type: object
            properties:
              name:
                type: string
      paths:
        /contents:
          get:
            parameters:
              - $ref: "#/components/parameters/ContentQueryParam"
      """)

    resolved = OpenAPIRefResolver.resolve(document)

    assert get_in(resolved, ["paths", "/contents", "get", "parameters", Access.at(0), "name"]) == "content"

    assert get_in(resolved, [
             "paths",
             "/contents",
             "get",
             "parameters",
             Access.at(0),
             "schema"
           ]) == %{"$ref" => "#/components/schemas/Contents"}

    assert get_in(resolved, ["components", "schemas", "Contents", "items"]) == %{
             "$ref" => "#/components/schemas/Content"
           }
  end

  test "resolves path item refs and ignores sibling fields" do
    {:ok, document} =
      YamlElixir.read_from_string("""
      components:
        pathItems:
          Common:
            get:
              parameters:
                - name: lang
                  in: query
                  schema:
                    type: integer
      paths:
        /test1:
          $ref: "#/components/pathItems/Common"
          get:
            parameters:
              - name: overwritten
                in: query
                schema:
                  type: string
      """)

    resolved = OpenAPIRefResolver.resolve(document)
    params = get_in(resolved, ["paths", "/test1", "get", "parameters"])

    assert [%{"name" => "lang"}] = params
  end

  test "resolves external OpenAPI parameter refs" do
    root = Path.expand("file/external_openapi/root.yaml", __DIR__)

    {:ok, document} =
      YamlElixir.read_from_file(root)

    resolved = OpenAPIRefResolver.resolve(document, base_uri: root)

    assert get_in(resolved, ["paths", "/users/{id}", "get", "parameters", Access.at(0)]) == %{
             "name" => "id",
             "in" => "path",
             "required" => true,
             "schema" => %{"type" => "integer"}
           }
  end

  test "resolves nested external OpenAPI refs relative to loaded resource base URI" do
    root = Path.expand("file/external_openapi/nested_root.yaml", __DIR__)

    {:ok, document} =
      YamlElixir.read_from_file(root)

    resolved = OpenAPIRefResolver.resolve(document, base_uri: root)

    assert get_in(resolved, ["paths", "/users", "post", "requestBody"]) == %{
             "required" => true,
             "content" => %{
               "application/json" => %{
                 "schema" => %{
                   "type" => "object",
                   "required" => ["name"],
                   "properties" => %{"name" => %{"type" => "string"}}
                 }
               }
             }
           }
  end

  test "raises for non-string ref values" do
    assert_raise Oasis.InvalidSpecError, ~r/Expect `\$ref` value to be a string/, fn ->
      OpenAPIRefResolver.resolve(%{
        "paths" => %{
          "/users" => %{
            "get" => %{
              "parameters" => [%{"$ref" => 123}]
            }
          }
        }
      })
    end
  end
end
