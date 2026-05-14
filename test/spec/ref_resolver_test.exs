defmodule Oasis.Spec.RefResolverTest do
  use ExUnit.Case

  alias Oasis.Spec.RefResolver

  test "expand nested local refs across schemas parameters and request bodies" do
    yaml_str = """
      components:
        parameters:
          ContentQueryParam:
            name: content
            in: query
            schema:
              $ref: "#/components/schemas/Contents"
        schemas:
          Content:
            type: object
            required:
              - name
              - tags
            properties:
              name:
                type: string
              tags:
                type: array
                items:
                  $ref: "#/components/schemas/Tag"
          Contents:
            type: array
            items:
              $ref: "#/components/schemas/Content"
          Tag:
            type: string
      paths:
        /page:
          get:
            parameters:
              - $ref: "#/components/parameters/ContentQueryParam"
            responses:
              '200':
                description: callback successfully processed
        /contents:
          get:
            parameters:
              - $ref: "#/components/parameters/ContentQueryParam"
            responses:
              '200':
                description: callback successfully processed
          post:
            requestBody:
              description: Callback payload
              content:
                'application/json':
                  schema:
                    $ref: '#/components/schemas/Contents'
            responses:
              '200':
                description: callback successfully processed
    """

    {:ok, document} = YamlElixir.read_from_string(yaml_str)

    expanded = RefResolver.expand_local_refs(document)

    comp_schemas = get_in(expanded, ["components", "schemas"])

    ref_tag = get_in(comp_schemas, ["Content", "properties", "tags", "items"])

    assert ref_tag == %{"type" => "string"}

    ref_contents = get_in(comp_schemas, ["Contents", "items"])

    content = %{
      "type" => "object",
      "required" => ["name", "tags"],
      "properties" => %{
        "name" => %{"type" => "string"},
        "tags" => %{
          "type" => "array",
          "items" => %{"type" => "string"}
        }
      }
    }

    assert ref_contents == content

    comp_params = get_in(expanded, ["components", "parameters"])

    content_query_param = get_in(comp_params, ["ContentQueryParam"])

    assert content_query_param["schema"] == %{
             "type" => "array",
             "items" => content
           }

    page_path_get = get_in(expanded, ["paths", "/page", "get"])
    common_content_params = page_path_get["parameters"]

    assert length(common_content_params) == 1

    content_param = Enum.at(common_content_params, 0)

    assert content_param["name"] == "content" and
             content_param["in"] == "query"

    contents_path_post_request_body_schema =
      get_in(expanded, [
        "paths",
        "/contents",
        "post",
        "requestBody",
        "content",
        "application/json",
        "schema"
      ])

    assert contents_path_post_request_body_schema == %{
             "type" => "array",
             "items" => content
           }

    contents_path_get = get_in(expanded, ["paths", "/contents", "get"])
    common_content_params = contents_path_get["parameters"]

    assert length(common_content_params) == 1

    content_param = Enum.at(common_content_params, 0)

    assert content_param["name"] == "content" and
             content_param["in"] == "query"
  end

  test "schema $ref siblings are ignored" do
    document = %{
      "components" => %{
        "schemas" => %{
          "StringBase" => %{"type" => "string"},
          "ShortTag" => %{
            "$ref" => "#/components/schemas/StringBase",
            "maxLength" => 10,
            "description" => "short tag"
          },
          "BaseObject" => %{
            "type" => "object",
            "properties" => %{"id" => %{"type" => "integer"}},
            "required" => ["id"]
          },
          "MergedObject" => %{
            "$ref" => "#/components/schemas/BaseObject",
            "properties" => %{"tag" => %{"type" => "string"}},
            "required" => ["tag"]
          }
        }
      }
    }

    expanded = RefResolver.expand_local_refs(document)

    assert get_in(expanded, ["components", "schemas", "ShortTag"]) == %{
             "type" => "string"
           }

    assert get_in(expanded, ["components", "schemas", "MergedObject"]) == %{
             "type" => "object",
             "properties" => %{"id" => %{"type" => "integer"}},
             "required" => ["id"]
           }
  end

  test "resolve local refs through maps and arrays" do
    document = %{
      "components" => %{
        "schemas" => %{
          "Tag" => %{"type" => "string"}
        }
      },
      "items" => [
        %{"name" => "first"}
      ],
      "special" => %{
        "a/b" => %{
          "~value" => 1
        }
      }
    }

    assert RefResolver.resolve_local_ref!(document, "#/components/schemas/Tag") == %{
             "type" => "string"
           }

    assert RefResolver.resolve_local_ref!(document, "#/items/0/name") == "first"
    assert RefResolver.resolve_local_ref!(document, "#/special/a~1b/~0value") == 1
  end

  test "detect cyclic local refs" do
    document = %{
      "components" => %{
        "schemas" => %{
          "A" => %{"$ref" => "#/components/schemas/B"},
          "B" => %{"$ref" => "#/components/schemas/A"}
        }
      }
    }

    assert_raise Oasis.InvalidSpecError, ~r/Cyclic ref detected/, fn ->
      RefResolver.expand_local_refs(document)
    end
  end

  test "expand refs with nested $id scoped local targets" do
    document = %{
      "$id" => "https://example.com/root.json",
      "$defs" => %{
        "User" => %{
          "$id" => "schemas/user.json",
          "$defs" => %{
            "Name" => %{"type" => "string"}
          },
          "schema" => %{"$ref" => "#/$defs/Name"}
        }
      }
    }

    expanded = RefResolver.expand_local_refs(document)

    assert get_in(expanded, ["$defs", "User", "schema"]) == %{"type" => "string"}
  end

  test "expand refs keeps absolute $id when source path is a file path" do
    document = %{
      "$id" => "https://example.com/root.json",
      "$defs" => %{
        "Name" => %{"type" => "string"}
      },
      "schema" => %{"$ref" => "#/$defs/Name"}
    }

    expanded = RefResolver.expand_refs(document, source_path: "/tmp/root.yaml")

    assert expanded["schema"] == %{"type" => "string"}
  end

  test "expand local refs and ignore sibling properties when ref exists" do
    document = %{
      "components" => %{
        "pathItems" => %{
          "Common" => %{
            "get" => %{
              "parameters" => [
                %{
                  "name" => "lang",
                  "in" => "query",
                  "schema" => %{"type" => "string"}
                }
              ]
            }
          }
        },
        "schemas" => %{
          "Tag" => %{"type" => "string"},
          "Content" => %{
            "type" => "object",
            "properties" => %{
              "tag" => %{"$ref" => "#/components/schemas/Tag"}
            }
          }
        }
      },
      "paths" => %{
        "/test" => %{
          "$ref" => "#/components/pathItems/Common",
          "get" => %{
            "summary" => "ignored"
          }
        }
      }
    }

    expanded = RefResolver.expand_local_refs(document)

    assert get_in(expanded, ["components", "schemas", "Content", "properties", "tag"]) == %{
             "type" => "string"
           }

    params = get_in(expanded, ["paths", "/test", "get", "parameters"])
    assert length(params) == 1
    assert Enum.at(params, 0)["name"] == "lang"
  end
end
