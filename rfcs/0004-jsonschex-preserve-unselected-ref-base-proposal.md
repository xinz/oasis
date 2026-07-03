# Proposal to JSONSchex: Preserve Resource Base for Unselected Nested `$ref`s in Selected External Refs

- Status: Implemented in JSONSchex `0.8.1`; verified in Oasis
- Created: 2026-06-10
- Originating use case: Oasis OpenAPI Reference Object resolution followed by JSON Schema fragment bundling
- Target project: `jsonschex`

## Summary

`JSONSchex.Ref.resolve_selected/2` correctly lets a caller resolve only selected `$ref` nodes while leaving other `$ref` nodes untouched. This is useful for OpenAPI tooling such as Oasis, where OpenAPI Reference Objects must be resolved before generation, but Schema Object `$ref`s must remain available for JSON Schema compilation/bundling.

Before JSONSchex `0.8.1`, when the selected `$ref` pointed into an external document, any **unselected nested `$ref`** inside the returned selected object lost the external document's resource base once that object was inlined into the root document.

That means a nested Schema Object ref like:

```yaml
# common.yaml
components:
  parameters:
    UserId:
      name: id
      in: path
      required: true
      schema:
        $ref: '#/components/schemas/UserId'
  schemas:
    UserId:
      type: integer
```

is selected through:

```yaml
# openapi.yaml
paths:
  /users/{id}:
    get:
      parameters:
        - $ref: './common.yaml#/components/parameters/UserId'
```

Before JSONSchex `0.8.1`, selected-ref resolution returned a root document like:

```elixir
%{
  "paths" => %{
    "/users/{id}" => %{
      "get" => %{
        "parameters" => [
          %{
            "name" => "id",
            "in" => "path",
            "required" => true,
            "schema" => %{"$ref" => "#/components/schemas/UserId"}
          }
        ]
      }
    }
  }
}
```

In that pre-`0.8.1` behavior, the nested schema `$ref` incorrectly resolved against `openapi.yaml`. It should retain the fact that it came from `common.yaml`, so a later `JSONSchex.bundle_fragment/2` can resolve it as:

```text
/common.yaml#/components/schemas/UserId
```

not:

```text
/openapi.yaml#/components/schemas/UserId
```

## Why this belongs in JSONSchex, not Oasis

Oasis can identify OpenAPI Reference Objects, but it should not implement JSON Schema resource-base logic. An Oasis-side workaround would require it to:

- traverse Schema Object internals
- understand JSON Schema applicator keywords such as `allOf`, `properties`, `$defs`, etc.
- rewrite or bundle nested schema refs manually
- duplicate JSONSchex reference-resolution behavior

That violates the intended boundary:

- Oasis owns OpenAPI selection policy and code generation.
- JSONSchex owns `$ref`, resource base, loader, and JSON Schema graph semantics.

`JSONSchex.Ref.resolve_selected/2` already knows when it loaded an external document and what its effective `base_uri` is. Therefore it is the best place to preserve enough context for unselected nested `$ref`s before returning the selected object to the caller.

## Behavior Before JSONSchex `0.8.1`

Given:

```elixir
root = %{
  "paths" => %{
    "/users/{id}" => %{
      "get" => %{
        "parameters" => [
          %{"$ref" => "./common.yaml#/components/parameters/UserId"}
        ]
      }
    }
  }
}

common = %{
  "components" => %{
    "parameters" => %{
      "UserId" => %{
        "name" => "id",
        "in" => "path",
        "required" => true,
        "schema" => %{"$ref" => "#/components/schemas/UserId"}
      }
    },
    "schemas" => %{
      "UserId" => %{"type" => "integer"}
    }
  }
}
```

and a selected-ref call:

```elixir
JSONSchex.Ref.resolve_selected(root,
  base_uri: "/api/openapi.yaml",
  loader: fn "/api/common.yaml" ->
    {:ok, %{document: common, base_uri: "/api/common.yaml"}}
  end,
  select: fn
    ["paths", "/users/{id}", "get", "parameters", 0], %{"$ref" => _} -> true
    _path, _node -> false
  end
)
```

Before JSONSchex `0.8.1`, the selected external Parameter Object was inlined, but its nested Schema Object `$ref` remained `#/components/schemas/UserId` with no indication that it belonged to `/api/common.yaml`.

A later call like this could fail or validate against the wrong root document:

```elixir
JSONSchex.bundle_fragment(resolved,
  entry: "/paths/~1users~1{id}/get/parameters/0/schema",
  base_uri: "/api/openapi.yaml",
  loader: loader
)
```

## Implemented Behavior

As of JSONSchex `0.8.1`, when `resolve_selected/2` returns a selected target from an external resource, unselected nested `$ref` nodes inside that target preserve their original resource base.

The downstream result allows `JSONSchex.bundle_fragment/2` to resolve the nested refs correctly.

Implementation strategies considered:

1. **Rebase unselected nested `$ref` values inside external selected targets**

   Convert:

   ```elixir
   %{"schema" => %{"$ref" => "#/components/schemas/UserId"}}
   ```

   into:

   ```elixir
   %{"schema" => %{"$ref" => "/api/common.yaml#/components/schemas/UserId"}}
   ```

   This is simple and visible, but it mutates string values.

2. **Attach resource-base metadata internally while walking selected targets**

   JSONSchex could carry origin metadata for values returned from external documents and teach fragment bundling/compilation to use that metadata. This avoids changing user-visible `$ref` strings, but is likely more invasive in Elixir because ordinary maps do not carry metadata.

3. **Wrap selected external targets in an internal resource boundary before returning**

   For example, JSONSchex could embed enough `$id` / resource context into the returned selected target so local refs remain local to the loaded resource. This must be done carefully because adding `$id` to arbitrary non-schema OpenAPI objects is not always semantically correct for JSON Schema evaluation.

JSONSchex `0.8.1` implements the visible rebasing approach: unselected nested `$ref`s under a selected external target are rebased before the selected target is inlined into the root document. This keeps later `bundle_fragment/2` calls working without Oasis-specific schema traversal.

## Important Constraint: Do Not Resolve Unselected Refs

The nested `$ref` must remain a `$ref`; it must not be eagerly expanded.

For Oasis, the key distinction is:

- selected OpenAPI Reference Objects are replaced with their target objects
- unselected Schema Object `$ref`s remain `$ref`s for JSON Schema compilation/bundling

So the implemented behavior is rebasing/preserving origin, not dereferencing all nested refs.

## Test Cases Proposed for JSONSchex and Verified by Oasis

These tests were written as copy-ready ExUnit cases for JSONSchex. Oasis also verifies the same behavior through `Oasis.Spec.OpenAPIRefResolver` and `Mix.Oasis.new/2` integration tests. They assume the existing public APIs:

- `JSONSchex.Ref.resolve_selected/2`
- `JSONSchex.bundle_fragment/2`
- `JSONSchex.compile/2`
- `JSONSchex.validate/2`

They use in-memory documents/loaders so no fixture files are required.

### Test 1: Selected external object rebases nested local unselected `$ref`

```elixir
defmodule JSONSchex.Ref.ResolveSelectedExternalBaseTest do
  use ExUnit.Case, async: true

  test "selected external target preserves base for nested local unselected refs" do
    root = %{
      "paths" => %{
        "/users/{id}" => %{
          "get" => %{
            "parameters" => [
              %{"$ref" => "./common.yaml#/components/parameters/UserId"}
            ]
          }
        }
      }
    }

    common = %{
      "components" => %{
        "parameters" => %{
          "UserId" => %{
            "name" => "id",
            "in" => "path",
            "required" => true,
            "schema" => %{"$ref" => "#/components/schemas/UserId"}
          }
        },
        "schemas" => %{
          "UserId" => %{"type" => "integer"}
        }
      }
    }

    loader = fn
      "/api/common.yaml" -> {:ok, %{document: common, base_uri: "/api/common.yaml"}}
    end

    assert {:ok, resolved} =
             JSONSchex.Ref.resolve_selected(root,
               base_uri: "/api/openapi.yaml",
               loader: loader,
               select: fn
                 ["paths", "/users/{id}", "get", "parameters", 0], %{"$ref" => _} -> true
                 _path, _node -> false
               end
             )

    schema = get_in(resolved, ["paths", "/users/{id}", "get", "parameters", Access.at(0), "schema"])

    # JSONSchex 0.8.1 uses visible rebasing for the preserved external resource base.
    assert schema == %{"$ref" => "/api/common.yaml#/components/schemas/UserId"}

    assert {:ok, bundled} =
             JSONSchex.bundle_fragment(resolved,
               entry: "/paths/~1users~1{id}/get/parameters/0/schema",
               base_uri: "/api/openapi.yaml",
               loader: loader
             )

    assert {:ok, compiled} = JSONSchex.compile(bundled)
    assert JSONSchex.validate(compiled, 123) == :ok
    assert {:error, _} = JSONSchex.validate(compiled, "not-an-integer")
  end
end
```

### Test 2: Selected external object rebases nested relative unselected `$ref`

```elixir
defmodule JSONSchex.Ref.ResolveSelectedExternalRelativeRefTest do
  use ExUnit.Case, async: true

  test "selected external target preserves base for nested relative unselected refs" do
    root = %{
      "paths" => %{
        "/profiles" => %{
          "post" => %{
            "requestBody" => %{"$ref" => "./common.yaml#/components/requestBodies/ProfileBody"}
          }
        }
      }
    }

    common = %{
      "components" => %{
        "requestBodies" => %{
          "ProfileBody" => %{
            "required" => true,
            "content" => %{
              "application/json" => %{
                "schema" => %{"$ref" => "./schemas/profile.yaml"}
              }
            }
          }
        }
      }
    }

    profile = %{
      "type" => "object",
      "required" => ["name"],
      "properties" => %{"name" => %{"type" => "string"}}
    }

    loader = fn
      "/api/common.yaml" -> {:ok, %{document: common, base_uri: "/api/common.yaml"}}
      "/api/schemas/profile.yaml" -> {:ok, %{document: profile, base_uri: "/api/schemas/profile.yaml"}}
    end

    assert {:ok, resolved} =
             JSONSchex.Ref.resolve_selected(root,
               base_uri: "/api/openapi.yaml",
               loader: loader,
               select: fn
                 ["paths", "/profiles", "post", "requestBody"], %{"$ref" => _} -> true
                 _path, _node -> false
               end
             )

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

    # JSONSchex 0.8.1 uses visible rebasing for the preserved external resource base.
    assert schema == %{"$ref" => "/api/schemas/profile.yaml"}

    assert {:ok, bundled} =
             JSONSchex.bundle_fragment(resolved,
               entry: "#/paths/~1profiles/post/requestBody/content/application~1json/schema",
               base_uri: "/api/openapi.yaml",
               loader: loader
             )

    assert {:ok, compiled} = JSONSchex.compile(bundled)
    assert JSONSchex.validate(compiled, %{"name" => "Ada"}) == :ok
    assert {:error, _} = JSONSchex.validate(compiled, %{})
  end
end
```

### Test 3: Unselected nested refs are not eagerly resolved

```elixir
defmodule JSONSchex.Ref.ResolveSelectedDoesNotResolveNestedRefsTest do
  use ExUnit.Case, async: true

  test "unselected nested refs remain refs after selected external target is inlined" do
    root = %{
      "parameter" => %{"$ref" => "./common.yaml#/components/parameters/UserId"}
    }

    common = %{
      "components" => %{
        "parameters" => %{
          "UserId" => %{
            "name" => "id",
            "in" => "path",
            "schema" => %{"$ref" => "#/components/schemas/UserId"}
          }
        },
        "schemas" => %{
          "UserId" => %{"type" => "integer"}
        }
      }
    }

    loader = fn
      "/api/common.yaml" -> {:ok, %{document: common, base_uri: "/api/common.yaml"}}
    end

    assert {:ok, resolved} =
             JSONSchex.Ref.resolve_selected(root,
               base_uri: "/api/openapi.yaml",
               loader: loader,
               select: fn
                 ["parameter"], %{"$ref" => _} -> true
                 _path, _node -> false
               end
             )

    schema = get_in(resolved, ["parameter", "schema"])

    assert %{"$ref" => ref} = schema
    assert is_binary(ref)
    assert ref == "/api/common.yaml#/components/schemas/UserId"
    refute Map.has_key?(schema, "type")
  end
end
```

### Test 4: Loader wrapper `:base_uri` is authoritative

This test ensures rebasing uses the loaded resource's effective `:base_uri`, not necessarily the URI that was requested.

```elixir
defmodule JSONSchex.Ref.ResolveSelectedLoaderBaseUriTest do
  use ExUnit.Case, async: true

  test "nested unselected refs are rebased against loader wrapper base_uri" do
    root = %{
      "parameter" => %{"$ref" => "https://example.test/common#/components/parameters/UserId"}
    }

    common = %{
      "components" => %{
        "parameters" => %{
          "UserId" => %{
            "name" => "id",
            "in" => "path",
            "schema" => %{"$ref" => "./schemas/user-id.yaml"}
          }
        }
      }
    }

    loader = fn
      "https://example.test/common" ->
        {:ok, %{document: common, base_uri: "file:///mirror/common.yaml"}}
    end

    assert {:ok, resolved} =
             JSONSchex.Ref.resolve_selected(root,
               loader: loader,
               select: fn
                 ["parameter"], %{"$ref" => _} -> true
                 _path, _node -> false
               end
             )

    schema = get_in(resolved, ["parameter", "schema"])

    assert schema == %{"$ref" => "file:///mirror/schemas/user-id.yaml"}
  end
end
```

## Acceptance Criteria

A JSONSchex fix should satisfy all of the following:

1. `JSONSchex.Ref.resolve_selected/2` still resolves only selected `$ref` nodes.
2. Unselected nested `$ref` nodes remain `$ref`s; they are not eagerly dereferenced.
3. When a selected target comes from an external resource, unselected nested refs inside that target preserve the external resource base.
4. Relative nested refs are resolved against the loaded resource's effective `:base_uri`.
5. Loader wrapper `:base_uri` is authoritative over the originally requested URI.
6. The resolved document can be passed to `JSONSchex.bundle_fragment/2` and then `JSONSchex.compile/2` without the caller doing Oasis-specific rebasing.

## Oasis Follow-up After JSONSchex Fix

Oasis added integration coverage for:

- external OpenAPI Parameter Object refs whose nested `schema.$ref` points to local `#/components/schemas/...` in the external file
- external OpenAPI Request Body refs whose nested media type schema points to a relative external schema file
- `Mix.Oasis.new/2` generation using those resolved OpenAPI refs without any Oasis-side schema traversal/rebasing

Oasis should not add JSON Schema keyword traversal to `Oasis.Spec.OpenAPIRefResolver`.
