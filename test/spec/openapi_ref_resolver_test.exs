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


  test "preserves external base for local schema refs nested inside external OpenAPI parameter refs" do
    root = Path.expand("file/external_openapi/schema_ref_root.yaml", __DIR__)
    common = Path.expand("file/external_openapi/schema_ref_common.yaml", __DIR__)

    {:ok, document} = YamlElixir.read_from_file(root)

    resolved = OpenAPIRefResolver.resolve(document, base_uri: root)
    schema = get_in(resolved, ["paths", "/users/{id}", "get", "parameters", Access.at(0), "schema"])

    assert schema == %{"$ref" => common <> "#/components/schemas/UserId"}

    assert {:ok, bundled} =
             JSONSchex.bundle_fragment(resolved,
               entry: "/paths/~1users~1{id}/get/parameters/0/schema",
               base_uri: root,
               loader: &Oasis.Spec.Document.load_external/1
             )

    assert {:ok, compiled} = JSONSchex.compile(bundled)
    assert JSONSchex.validate(compiled, 123) == :ok
    assert {:error, _} = JSONSchex.validate(compiled, "not-an-integer")
  end

  test "preserves external base for relative schema refs nested inside external OpenAPI request body refs" do
    root = Path.expand("file/external_openapi/schema_ref_root.yaml", __DIR__)
    profile = Path.expand("file/external_openapi/schemas/profile.yaml", __DIR__)

    {:ok, document} = YamlElixir.read_from_file(root)

    resolved = OpenAPIRefResolver.resolve(document, base_uri: root)

    schema =
      get_in(resolved, [
        "paths",
        "/profiles",
        "post",
        "requestBody",
        "content",
        "application/json",
        "schema"
      ])

    assert schema == %{"$ref" => profile}

    assert {:ok, bundled} =
             JSONSchex.bundle_fragment(resolved,
               entry: "#/paths/~1profiles/post/requestBody/content/application~1json/schema",
               base_uri: root,
               loader: &Oasis.Spec.Document.load_external/1
             )

    assert {:ok, compiled} = JSONSchex.compile(bundled)
    assert JSONSchex.validate(compiled, %{"name" => "Ada"}) == :ok
    assert {:error, _} = JSONSchex.validate(compiled, %{})
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

  test "preserves Schema Object `$ref` with sibling fields untouched" do
    # The OpenAPI Reference Object spec (3.0) ignored siblings of `$ref`, but the
    # *Schema Object* `$ref` (which is JSON Schema, not an OpenAPI Reference
    # Object) is a different beast: in OAS 3.1 / JSON Schema 2020-12 it lives
    # alongside `description`, `title`, `nullable`, validation keywords, etc.
    #
    # The architectural boundary requires this resolver to NEVER touch Schema
    # Object `$ref`s — they are JSONSchex's responsibility. This test pins
    # that contract: both the `$ref` and its siblings survive verbatim.
    {:ok, document} =
      YamlElixir.read_from_string("""
      components:
        schemas:
          Pet:
            type: object
            properties:
              name:
                type: string
          PetWithSiblings:
            $ref: "#/components/schemas/Pet"
            description: "A Pet, but with extra prose"
            title: "Decorated Pet"
      paths:
        /pets:
          post:
            requestBody:
              required: true
              content:
                application/json:
                  schema:
                    $ref: "#/components/schemas/PetWithSiblings"
                    description: "Inline sibling on a Schema Object ref"
                    nullable: true
      """)

    resolved = Oasis.Spec.OpenAPIRefResolver.resolve(document)

    assert get_in(resolved, ["components", "schemas", "PetWithSiblings"]) == %{
             "$ref" => "#/components/schemas/Pet",
             "description" => "A Pet, but with extra prose",
             "title" => "Decorated Pet"
           }

    assert get_in(resolved, [
             "paths",
             "/pets",
             "post",
             "requestBody",
             "content",
             "application/json",
             "schema"
           ]) == %{
             "$ref" => "#/components/schemas/PetWithSiblings",
             "description" => "Inline sibling on a Schema Object ref",
             "nullable" => true
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

  describe "resolver error kinds" do
    test ":missing_target when local component ref does not exist" do
      assert_raise Oasis.InvalidSpecError, ~r/Could not resolve OpenAPI ref/, fn ->
        OpenAPIRefResolver.resolve(%{
          "paths" => %{
            "/users" => %{
              "get" => %{
                "parameters" => [%{"$ref" => "#/components/parameters/DoesNotExist"}]
              }
            }
          }
        })
      end
    end

    test ":missing_base_uri when external ref is used without :base_uri" do
      assert_raise Oasis.InvalidSpecError,
                   ~r/external OpenAPI ref `.*` because the containing document base URI is missing/,
                   fn ->
                     OpenAPIRefResolver.resolve(%{
                       "paths" => %{
                         "/users" => %{
                           "$ref" => "./other.yaml#/components/pathItems/Users"
                         }
                       }
                     })
                   end
    end

    test ":missing_loader when external ref is used and :loader is nil" do
      assert_raise Oasis.InvalidSpecError,
                   ~r/no loader was provided/,
                   fn ->
                     OpenAPIRefResolver.resolve(
                       %{
                         "paths" => %{
                           "/users" => %{
                             "$ref" => "./other.yaml#/components/pathItems/Users"
                           }
                         }
                       },
                       base_uri: "/tmp/root.yaml",
                       loader: nil
                     )
                   end
    end

    test ":missing_external_document when external file cannot be loaded" do
      base_uri = Path.expand("file/external_openapi/root.yaml", __DIR__)

      assert_raise Oasis.InvalidSpecError,
                   ~r/Could not resolve external OpenAPI ref `.*missing.yaml/,
                   fn ->
                     OpenAPIRefResolver.resolve(
                       %{
                         "paths" => %{
                           "/users" => %{
                             "$ref" => "./missing.yaml#/components/pathItems/Users"
                           }
                         }
                       },
                       base_uri: base_uri
                     )
                   end
    end

    test ":invalid_loader_response when custom loader returns a malformed payload" do
      invalid_loader = fn _uri -> {:ok, "not-a-map"} end

      assert_raise Oasis.InvalidSpecError,
                   ~r/Invalid external OpenAPI ref loader response/,
                   fn ->
                     OpenAPIRefResolver.resolve(
                       %{
                         "paths" => %{
                           "/users" => %{
                             "$ref" => "./anything.yaml#/components/pathItems/Users"
                           }
                         }
                       },
                       base_uri: "/tmp/root.yaml",
                       loader: invalid_loader
                     )
                   end
    end

    test ":cycle_detected when two external path items reference each other" do
      base_uri = Path.expand("file/external_openapi/cycle/root.yaml", __DIR__)

      assert_raise Oasis.InvalidSpecError,
                   ~r/creates a cycle/,
                   fn ->
                     OpenAPIRefResolver.resolve(
                       %{
                         "paths" => %{
                           "/users" => %{
                             "$ref" => "./a.yaml#/cyclePath"
                           }
                         }
                       },
                       base_uri: base_uri
                     )
                   end
    end
  end
end
