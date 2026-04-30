defmodule Oasis.Spec.RefResolverTest do
  use ExUnit.Case

  alias Oasis.Spec.RefResolver

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

    assert RefResolver.resolve_local_ref!(document, "#/components/schemas/Tag") == %{"type" => "string"}
    assert RefResolver.resolve_local_ref!(document, "#/items/0/name") == "first"
    assert RefResolver.resolve_local_ref!(document, "#/special/a~1b/~0value") == 1
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
