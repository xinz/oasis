# Proposal to JSONSchex: Reachable Fragment Bundling and Deep Rebasing for Unselected `$ref` Nodes

- Status: Implemented
- Created: 2026-07-10
- Implemented: 2026-07-22
- Originating use case: Oasis OpenAPI Reference Object resolution followed by JSON Schema fragment bundling
- Target project: `jsonschex`
- Target release: `0.9.0`

## Summary

Oasis uses two JSONSchex APIs to maintain a strict ownership boundary:

- `JSONSchex.Ref.resolve_selected/2` resolves structural OpenAPI Reference Objects while leaving Schema Object `$ref`s available for JSON Schema processing.
- `JSONSchex.bundle_fragment/2` turns one schema entrypoint inside an OpenAPI document into a standalone schema for generated code.

JSONSchex `0.8.1` fixed the original external-resource base loss for a direct unselected nested `$ref`. This proposal addressed two related graph-traversal gaps:

1. `bundle_fragment/2` scanned the entire merged containing document for external refs, so unreachable refs could trigger unrelated loading failures.
2. `resolve_selected/2` rebased an unselected node's direct `$ref`, but stopped walking that node, so refs inside valid `$ref` siblings and deeper descendants kept the wrong resource base.

Both fixes were implemented in JSONSchex because they require reference-graph reachability and resource-base semantics. Oasis does not need to duplicate that logic.

## Implementation Outcome

The public function signatures and existing options remain unchanged.

### `JSONSchex.bundle_fragment/2`

The final implementation:

- starts reference discovery from the selected entry schema
- follows active JSON Schema child locations and reachable `$ref` / `$dynamicRef` edges
- resolves reachable local pointers, anchors, dynamic anchors, nested `$id` resources, and external fragments
- loads each requested, loader-effective, or canonical external resource identity only once
- keeps recursive and dynamic-scope traversal finite
- does not follow refs found only in inactive definitions, unrelated components, examples, or extension data
- prevents `$id` metadata in opaque containing-document data from overriding authoritative schema resources
- preserves caller-owned `$defs` entries and chooses collision-safe internal `jsonschex_*` mount keys
- returns structured `invalid_defs` and `ambiguous_anchor` errors instead of raising, overwriting caller data, or choosing duplicate fallback anchors by map iteration order
- returns a standalone bundle that can be compiled and validated without the original loader for every reachable reference

The bundle may still retain complete containing or external resource documents. Reachability controls loader invocation and failure behavior; it does not guarantee byte-minimal output.

### `JSONSchex.Ref.resolve_selected/2`

The final implementation:

- preserves an unselected `$ref` node
- continues recursively through all sibling maps and lists
- invokes `:select` for descendant `$ref` nodes beneath an unselected ref map
- rebases every descendant ref that remains unselected
- honors loader-provided effective `:base_uri`, canonical root `$id`, ancestor `$id` values along pointer paths, and nested resource boundaries
- does not load or dereference unselected direct or descendant refs
- caches requested, effective, and canonical identities for loaded selected-ref resources

Selectors with side effects should account for callback invocations at descendant paths that JSONSchex `0.8.1` skipped.

### Shared internal support

The implementation introduced:

- `JSONSchex.ResourceContext` for decoded JSON Pointer traversal, array indexes, containing-resource discovery, and inherited/effective base calculation
- `JSONSchex.SchemaTraversal` for centralized active, metadata, and scope schema-child traversal

`JSONSchex.Compiler.Fragment.Bundle`, `JSONSchex.Ref`, and `JSONSchex.ScopeScanner` now share these mechanics instead of maintaining independent pointer walkers and schema-keyword lists.

## Problem 1: Fragment Bundling Loaded Unreachable External Refs

### JSONSchex 0.8.1 behavior

Given a containing OpenAPI-like document:

```elixir
document = %{
  "schema" => %{"type" => "string"},
  "components" => %{
    "schemas" => %{
      "Unused" => %{"$ref" => "./missing.yaml"}
    }
  }
}
```

and this call:

```elixir
JSONSchex.bundle_fragment(document,
  entry: "#/schema",
  base_uri: "/api/openapi.yaml",
  loader: loader
)
```

`#/schema` is self-contained and cannot reach `components.schemas.Unused`. Nevertheless, JSONSchex `0.8.1` merges the full containing document with the entry schema and recursively collects external refs from the merged map. It therefore tries to load `/api/missing.yaml`.

Generation fails because of an unrelated, unreachable schema.

### Why this is incorrect for a fragment API

The purpose of a fragment API is to compile or bundle the schema graph reachable from one entrypoint while retaining the containing document as reference context.

Containing-document context does not imply that every `$ref`-shaped value in the document is reachable. This distinction is especially important for OpenAPI documents, which may contain:

- many unrelated component schemas
- unused external schemas
- examples or extension data containing `$ref`-shaped maps
- external refs used by operations that are not being generated

An unreachable reference should not require a loader and should not make the selected entrypoint fail.

### Implemented behavior

`bundle_fragment/2` now discovers and loads resources by traversing the schema graph reachable from `:entry`.

It continues to support:

- local refs from the entrypoint into the containing document
- transitive local refs
- relative and absolute external refs
- external refs with fragments
- `$id` resource boundaries
- anchors and dynamic anchors
- recursive graphs

It does not load an external resource merely because an unrelated subtree of the containing document contains a `$ref`.

## Problem 2: Unselected `$ref` Siblings Were Not Traversed

### JSONSchex 0.8.1 behavior

Consider an OpenAPI Parameter Object selected from an external document. Its Schema Object contains a direct `$ref` and a valid Draft 2020-12 sibling:

```elixir
%{
  "name" => "id",
  "in" => "path",
  "required" => true,
  "schema" => %{
    "$ref" => "./schemas/base.yaml",
    "allOf" => [
      %{"$ref" => "./schemas/constraints.yaml"}
    ]
  }
}
```

When the Parameter Object is selected and inlined from `/api/common.yaml`, the Schema Object itself remains unselected. JSONSchex `0.8.1` produces behavior equivalent to:

```elixir
%{
  "$ref" => "/api/schemas/base.yaml",
  "allOf" => [
    %{"$ref" => "./schemas/constraints.yaml"}
  ]
}
```

The direct `$ref` is correctly rebased, but the sibling descendant is not. Once this object is inlined into `/api/openapi.yaml`, the `allOf` ref resolves against the wrong resource.

### JSONSchex 0.8.1 root cause

The selected-ref walker treated any map containing `$ref` as a terminal reference node:

- selected node: resolve and walk its target
- unselected node: rebase its direct `$ref` and return immediately

For JSON Schema Draft 2019-09 and 2020-12, `$ref` siblings are meaningful. Returning immediately skips valid sibling schemas and any refs nested beneath them.

### Implemented behavior

When a `$ref` node is unselected, JSONSchex now:

1. Keep the node as a `$ref`; do not resolve it.
2. Rebase the direct `$ref` when the node originated in an external selected target.
3. Continue walking sibling values with the same resource-origin context.
4. Rebase any unselected descendant refs that would otherwise lose their original resource base.
5. Do not eagerly load or dereference those unselected refs.

This is implemented as generic recursive reference preservation, not as an Oasis-specific list of JSON Schema keywords such as `allOf`, `properties`, or `$defs`.

## Why These Fixes Belong in JSONSchex

Oasis knows which OpenAPI Reference Object locations it needs before generation, but it should not implement:

- JSON Schema graph reachability
- `$id` and resource-base propagation
- anchor resolution
- recursive graph traversal
- external resource discovery
- rebasing of nested JSON Schema refs

Implementing either workaround in Oasis would make it maintain a partial JSON Schema engine and would violate the intended boundary:

- Oasis owns OpenAPI selection policy and generated Plug structure.
- JSONSchex owns JSON Schema reference graphs, resource identity, bundling, and compilation.

## Implemented Semantics

### `JSONSchex.bundle_fragment/2`

Without changing the public API, bundling now operates from the selected entrypoint:

1. Resolve `:entry` in the containing document.
2. Treat that schema as the graph root.
3. Follow only refs reachable from that root.
4. Resolve local refs against the containing document/resource context.
5. Load only reachable external resources.
6. Preserve recursive edges without infinite expansion.
7. Return a standalone schema whose reachable refs compile without the original loader.

The output does not need to be minimal byte-for-byte, but loader invocation and failure behavior must be reachability-based.

### `JSONSchex.Ref.resolve_selected/2`

For an unselected map containing `$ref`, JSONSchex now:

1. Rebase the direct ref when necessary.
2. Recursively walk all sibling values.
3. Preserve the node as a ref node.
4. Do not invoke the loader for the unselected ref or its unselected descendants.

The selection callback continues to control dereferencing, while origin preservation applies independently to all unselected refs inside a selected external target.

## Implemented Test Coverage

The original five acceptance examples below were integrated into the project test suite using in-memory loaders. The final suite also covers local-to-external chains, inactive definitions and opaque metadata, all supported schema-bearing keywords, external fragments, recursive and dynamic refs, dynamic-scope overrides, nested `$id` resources, loader aliases, canonical IDs, generated-definition collisions, ambiguous anchors, selector callback paths, and shared resource-context traversal.

### Original acceptance examples

### Test 1: Unreachable external refs are not loaded

```elixir
defmodule JSONSchex.BundleFragmentReachabilityTest do
  use ExUnit.Case, async: true

  test "does not load an external ref unreachable from the selected entry" do
    document = %{
      "schema" => %{"type" => "string"},
      "components" => %{
        "schemas" => %{
          "Unused" => %{"$ref" => "./missing.yaml"}
        }
      }
    }

    test_pid = self()

    loader = fn uri ->
      # Any loader call proves bundling scanned outside the reachable graph.
      send(test_pid, {:loaded, uri})
      {:error, :unexpected_load}
    end

    assert {:ok, bundled} =
             JSONSchex.bundle_fragment(document,
               entry: "#/schema",
               base_uri: "/api/openapi.yaml",
               loader: loader
             )

    refute_received {:loaded, _uri}

    assert {:ok, compiled} = JSONSchex.compile(bundled)
    assert JSONSchex.validate(compiled, "ok") == :ok
    assert {:error, _} = JSONSchex.validate(compiled, 123)
  end
end
```

### Test 2: Reachable external refs are still loaded

```elixir
defmodule JSONSchex.BundleFragmentReachableExternalTest do
  use ExUnit.Case, async: true

  test "loads an external resource reachable from the selected entry" do
    document = %{
      "schema" => %{"$ref" => "./schemas/user.yaml"},
      "components" => %{
        "schemas" => %{
          "Unused" => %{"$ref" => "./missing.yaml"}
        }
      }
    }

    user_schema = %{
      "type" => "object",
      "required" => ["name"],
      "properties" => %{"name" => %{"type" => "string"}}
    }

    test_pid = self()

    loader = fn
      "/api/schemas/user.yaml" = uri ->
        send(test_pid, {:loaded, uri})
        {:ok, %{document: user_schema, base_uri: uri}}

      uri ->
        send(test_pid, {:unexpected_load, uri})
        {:error, :unexpected_load}
    end

    assert {:ok, bundled} =
             JSONSchex.bundle_fragment(document,
               entry: "#/schema",
               base_uri: "/api/openapi.yaml",
               loader: loader
             )

    assert_received {:loaded, "/api/schemas/user.yaml"}
    refute_received {:unexpected_load, "/api/missing.yaml"}

    assert {:ok, compiled} = JSONSchex.compile(bundled)
    assert JSONSchex.validate(compiled, %{"name" => "Ada"}) == :ok
    assert {:error, _} = JSONSchex.validate(compiled, %{})
  end
end
```

### Test 3: Rebase direct and sibling-descendant refs

```elixir
defmodule JSONSchex.ResolveSelectedDeepRebaseTest do
  use ExUnit.Case, async: true

  test "rebases refs beneath siblings of an unselected ref node" do
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
            "schema" => %{
              "$ref" => "./schemas/base.yaml",
              "allOf" => [
                %{"$ref" => "./schemas/constraints.yaml"}
              ]
            }
          }
        }
      }
    }

    loader = fn
      "/api/common.yaml" ->
        {:ok, %{document: common, base_uri: "/api/common.yaml"}}
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

    schema =
      get_in(resolved, [
        "paths",
        "/users/{id}",
        "get",
        "parameters",
        Access.at(0),
        "schema"
      ])

    assert schema == %{
             "$ref" => "/api/schemas/base.yaml",
             "allOf" => [
               %{"$ref" => "/api/schemas/constraints.yaml"}
             ]
           }
  end
end
```

### Test 4: Deep rebasing does not eagerly resolve refs

```elixir
defmodule JSONSchex.ResolveSelectedDeepRebaseNoEagerLoadTest do
  use ExUnit.Case, async: true

  test "preserves nested refs without loading their targets" do
    root = %{
      "parameter" => %{"$ref" => "./common.yaml#/parameter"}
    }

    common = %{
      "parameter" => %{
        "name" => "id",
        "in" => "query",
        "schema" => %{
          "$ref" => "./schemas/base.yaml",
          "allOf" => [%{"$ref" => "./schemas/constraints.yaml"}]
        }
      }
    }

    test_pid = self()

    loader = fn
      "/api/common.yaml" = uri ->
        send(test_pid, {:loaded, uri})
        {:ok, %{document: common, base_uri: uri}}

      uri ->
        send(test_pid, {:unexpected_load, uri})
        {:error, :unexpected_load}
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

    assert_received {:loaded, "/api/common.yaml"}
    refute_received {:unexpected_load, _uri}

    assert get_in(resolved, ["parameter", "schema"]) == %{
             "$ref" => "/api/schemas/base.yaml",
             "allOf" => [%{"$ref" => "/api/schemas/constraints.yaml"}]
           }
  end
end
```

### Test 5: Loader wrapper `:base_uri` remains authoritative for deep rebasing

```elixir
defmodule JSONSchex.ResolveSelectedDeepRebaseLoaderBaseTest do
  use ExUnit.Case, async: true

  test "rebases direct and sibling refs against the loader's effective base_uri" do
    root = %{
      "parameter" => %{
        "$ref" => "https://example.test/common#/parameter"
      }
    }

    common = %{
      "parameter" => %{
        "name" => "id",
        "in" => "query",
        "schema" => %{
          "$ref" => "./schemas/base.yaml",
          "allOf" => [%{"$ref" => "./schemas/constraints.yaml"}]
        }
      }
    }

    loader = fn
      "https://example.test/common" ->
        {:ok,
         %{
           document: common,
           base_uri: "file:///mirror/common.yaml"
         }}
    end

    assert {:ok, resolved} =
             JSONSchex.Ref.resolve_selected(root,
               loader: loader,
               select: fn
                 ["parameter"], %{"$ref" => _} -> true
                 _path, _node -> false
               end
             )

    assert get_in(resolved, ["parameter", "schema"]) == %{
             "$ref" => "file:///mirror/schemas/base.yaml",
             "allOf" => [
               %{"$ref" => "file:///mirror/schemas/constraints.yaml"}
             ]
           }
  end
end
```

## Acceptance Criteria

### Reachable fragment bundling

- [x] `bundle_fragment/2` loads only external resources reachable from `:entry`.
- [x] Unreachable missing external refs do not cause bundling to fail.
- [x] Reachable local and external refs still resolve correctly.
- [x] Recursive reachable graphs terminate and remain valid.
- [x] Loader wrapper `:base_uri` remains authoritative.
- [x] Existing public options remain compatible.
- [x] Existing loader failures retain the established error structure.
- [x] New malformed or ambiguous input cases return structured `invalid_defs` and `ambiguous_anchor` errors.

### Deep unselected-ref rebasing

- [x] Selection still controls dereferencing; unselected refs remain refs.
- [x] The direct `$ref` of an unselected node is rebased when necessary.
- [x] Refs beneath sibling values are recursively rebased using the same origin context.
- [x] No unselected direct or descendant ref is eagerly loaded or expanded.
- [x] The behavior is generic and does not depend on an Oasis-maintained JSON Schema keyword list.
- [x] Loader wrapper `:base_uri` remains authoritative for all rebased descendants.
- [x] Ancestor and nested `$id` resource boundaries remain authoritative.
- [x] Requested, loader-effective, and canonical resource identities share the selected-ref cache.

## Final Differences and Deliberate Trade-offs

1. Generated `$defs` mount names are internal implementation details. They use the `jsonschex_*` prefix and receive deterministic numeric suffixes when caller-owned keys collide. Callers must not construct refs to these generated paths; resource identity remains based on `$id` and anchors.
2. A unique anchor found only in opaque containing-document data remains eligible as a fallback target. JSONSchex cannot distinguish an OpenAPI component schema from extension data without domain-specific container policy. Multiple distinct fallback locations declaring the same anchor return `ambiguous_anchor` without invoking the loader.
3. The output remains intentionally non-minimal. Whole containing or external documents may be retained even though only reachable external resources are loaded.
4. Large-document benchmarking and optional byte-size compaction are deferred. They are optimizations rather than acceptance requirements.
5. Entry resolution still performs one JSON Pointer lookup for the public fragment API and one shared resource-context traversal for inherited base/resource information. The previous additional indexing walk was removed.

## Validation Result

At implementation completion:

```text
mix test
21 doctests, 2374 tests, 0 failures
```

Project diagnostics and `git diff --check` were clean. `mix format` was intentionally not run.

## Oasis Follow-up

After JSONSchex releases these fixes, Oasis should:

1. Upgrade its minimum JSONSchex dependency to the fixed version.
2. Add integration tests matching the unreachable-ref and `$ref`-sibling cases.
3. Remove any Oasis-side compaction or context-retention logic that becomes unnecessary with a reachable standalone bundle.
4. Keep `Oasis.Spec.OpenAPIRefResolver` limited to OpenAPI selection policy.
5. Avoid adding JSON Schema keyword traversal or resource-base rewriting to Oasis.
