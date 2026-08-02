# Proposal to JSONSchex: Selected `$ref` Resolution for JSON-like Documents

- Status: Implemented in JSONSchex `0.8.0`; integrated in Oasis
- Created: 2026-05-21
- Updated: 2026-06-09
- Originating use case: Oasis OpenAPI Reference Object resolution
- Target project: `jsonschex`

## Summary

Oasis now uses `JSONSchex.bundle_fragment/2` for generated JSON Schema fragments. That cleanly moves JSON Schema graph semantics to JSONSchex.

However, Oasis still needs to resolve OpenAPI Reference Objects such as Path Item Objects, Parameter Objects, Request Body Objects, and Response Objects before generating Plug routers. Those refs use the same `$ref` mechanics as JSON Schema refs:

- same-document JSON Pointer resolution
- external file/resource loading
- relative URI/base URI resolution
- JSON Pointer target lookup
- recursive/cycle safety

The original Oasis implementation, `Oasis.Spec.OpenAPIRefResolver`, owned this mechanics manually. JSONSchex now exposes a generic selected-ref resolver:

```/dev/null/example.ex#L1
JSONSchex.Ref.resolve_selected(document, opts)
```

The key idea is simple:

> JSONSchex resolves `$ref` mechanics, while the caller decides which `$ref` nodes are selected for resolution.

This keeps JSONSchex independent from OpenAPI while allowing Oasis to remove duplicated ref-resolution code.

## Motivation

OpenAPI Reference Objects and JSON Schema `$ref` keywords are different semantic concepts, but their low-level resolution mechanics are the same.

Oasis should know this:

- `#/paths/~1users/get/parameters/0` is an OpenAPI Parameter Object location.
- `#/paths/~1users/post/requestBody` is an OpenAPI Request Body Object location.
- `#/paths/~1users/post/requestBody/content/application~1json/schema` is a Schema Object location.

JSONSchex should know this:

- how to resolve `#/components/parameters/UserId`
- how to resolve `./common.yaml#/components/parameters/UserId`
- how to use `:base_uri`
- how to call a loader
- how to carry the loaded resource's own base URI
- how to detect missing targets and cycles

The missing abstraction is a generic way for callers to say:

> Resolve this `$ref` only if this node is selected by my policy.

## Current Oasis Example

Root OpenAPI document:

```/dev/null/example.yaml#L1
paths:
  /users/{id}:
    get:
      parameters:
        - $ref: './common.yaml#/components/parameters/UserId'
      responses:
        '200':
          description: OK
```

External OpenAPI fragment file:

```/dev/null/example.yaml#L1
components:
  parameters:
    UserId:
      name: id
      in: path
      required: true
      schema:
        type: integer
```

Oasis needs the parameter object resolved before route generation:

```/dev/null/example.ex#L1
%{
  "name" => "id",
  "in" => "path",
  "required" => true,
  "schema" => %{"type" => "integer"}
}
```

But Oasis must not eagerly resolve schema refs such as:

```/dev/null/example.yaml#L1
schema:
  $ref: './schemas/user.yaml#/User'
```

Those schema refs should remain available for `JSONSchex.bundle_fragment/2`.

## Implemented API

JSONSchex provides:

```/dev/null/example.ex#L1
JSONSchex.Ref.resolve_selected(document, opts)
```

Minimum option set:

```/dev/null/example.ex#L1
JSONSchex.Ref.resolve_selected(document,
  base_uri: base_uri,
  loader: loader,
  select: select_fun
)
```

Return:

```/dev/null/example.ex#L1
{:ok, resolved_document} | {:error, JSONSchex.Ref.Error.t()}
```

## Options

### `:select` required

A function that decides whether the current `$ref` node should be resolved.

Suggested callback shape:

```/dev/null/example.ex#L1
(path, node -> boolean())
```

Where:

- `path` is the path to the node containing `$ref`, not to the `$ref` key itself.
- `node` is the map containing `$ref`.

Example:

```/dev/null/example.ex#L1
select = fn
  ["paths", path, "get", "parameters", index], %{"$ref" => _}
  when is_binary(path) and is_integer(index) ->
    true

  ["paths", path, "post", "requestBody"], %{"$ref" => _}
  when is_binary(path) ->
    true

  _path, _node ->
    false
end
```

This keeps OpenAPI knowledge outside JSONSchex.

### `:base_uri` optional

Starting base URI/path for resolving relative external refs.

If omitted, same-document refs can still be resolved, but relative external refs should fail with a structured error when selected.

### `:loader` optional

Loader for external resources.

The loader should follow the existing JSONSchex loader contract:

```/dev/null/example.ex#L1
(String.t() ->
   {:ok, map() | boolean()}
   | {:ok, %{document: map() | boolean(), base_uri: String.t()}}
   | {:error, term()})
```

If omitted, selected external refs should fail with a structured error.

## Intentional Defaults

To keep the API small, the first version should hardcode these defaults:

1. A selected ref node is replaced by the resolved target value.
2. Sibling fields next to `$ref` are ignored because the selected node is treated as a Reference Object.
3. Cycles are errors.
4. Unselected `$ref` nodes are not resolved. Since JSONSchex `0.9.0`, their siblings and descendants are still traversed, and nested unselected refs may be visibly rebased to preserve their resource origin.

These defaults match the Oasis OpenAPI Reference Object use case and avoid adding options such as `:sibling_policy`, `:on_cycle`, or `:replace` until another concrete use case needs them.

## Semantics

`resolve_selected/2` should:

1. Walk maps and lists in a JSON-like document.
2. Track the path to every map node.
3. When a map contains a `$ref` string, call `select.(path, node)`.
4. If selected, resolve the ref against the current resource context.
5. Replace the entire node with the resolved target value.
6. Continue resolving selected refs inside the resolved target value.
7. Preserve unselected ref nodes semantically; when they originate in selected external targets, rebase them as needed rather than promising byte-for-byte unchanged text.
8. Resolve external resources through `:loader`.
9. Use loader-returned `:base_uri` as the context for nested refs inside external resources.
10. Return `{:ok, resolved_document}` or `{:error, error}`.

## Resource Context Requirement

Resource context is the most important part of this API.

Example:

```/dev/null/example.yaml#L1
# root.yaml
paths:
  /users:
    $ref: './paths/users.yaml#/UserPath'
```

```/dev/null/example.yaml#L1
# paths/users.yaml
UserPath:
  post:
    requestBody:
      $ref: '../common.yaml#/components/requestBodies/CreateUser'
```

Correct behavior:

1. `./paths/users.yaml#/UserPath` resolves relative to `root.yaml`.
2. `../common.yaml#/components/requestBodies/CreateUser` resolves relative to `paths/users.yaml`, not `root.yaml`.

So the resolved target must carry the loaded resource's base URI while nested selected refs are processed.

## Oasis Usage

Oasis could reduce `Oasis.Spec.OpenAPIRefResolver` to policy plus error shaping:

```/dev/null/example.ex#L1
JSONSchex.Ref.resolve_selected(spec,
  base_uri: source_path,
  loader: &Oasis.Spec.Document.load_external/1,
  select: &Oasis.Spec.OpenAPIRefResolver.openapi_reference_object?/2
)
```

Oasis selector example:

```/dev/null/example.ex#L1
def openapi_reference_object?(["paths", path], %{"$ref" => _}) when is_binary(path) do
  String.starts_with?(path, "/")
end

def openapi_reference_object?(["paths", path, "parameters", index], %{"$ref" => _})
    when is_binary(path) and is_integer(index) do
  true
end

def openapi_reference_object?(["paths", path, method, "parameters", index], %{"$ref" => _})
    when is_binary(path) and method in ["get", "post", "put", "delete", "patch", "head", "options"] and is_integer(index) do
  true
end

def openapi_reference_object?(["paths", path, method, "requestBody"], %{"$ref" => _})
    when is_binary(path) and method in ["get", "post", "put", "delete", "patch", "head", "options"] do
  true
end

def openapi_reference_object?(_path, _node), do: false
```

## What JSONSchex Should Not Do

JSONSchex should not include OpenAPI-specific selectors or OpenAPI object knowledge.

Do not hardcode:

- `paths`
- `parameters`
- `requestBody`
- `responses`
- OpenAPI HTTP method names
- OpenAPI sibling rules as OpenAPI-specific behavior

The API should stay a generic selected `$ref` resolver for JSON-like documents.

## Error Expectations

Errors should include enough information for Oasis to wrap them as `Oasis.InvalidSpecError`.

Useful fields in `JSONSchex.Ref.Error` or equivalent:

- ref string
- node path
- resolved URI, when available
- error kind
- loader error details, when applicable

Minimum error kinds:

- invalid ref value
- missing base URI for selected external ref
- missing loader for selected external ref
- missing external document
- missing target
- cycle detected
- invalid loader response

## Why This Should Be in JSONSchex

The implementation is not OpenAPI-specific. It is generic ref mechanics:

- URI resolution
- JSON Pointer resolution
- external resource loading
- base URI propagation
- cycle safety
- tree replacement

Other tools can use the same API for selected dereferencing in custom JSON/YAML documents.

## Non-goals

- Do not validate OpenAPI documents.
- Do not understand OpenAPI object types.
- Do not compile or bundle JSON Schema fragments. That is already covered by JSONSchex fragment APIs such as `compile_fragment/2` and `bundle_fragment/2`.
- Do not add many policy options in the first version.

## Suggested Test Cases

### Selected local ref is replaced

Input:

```/dev/null/example.ex#L1
%{"a" => %{"$ref" => "#/defs/A"}, "defs" => %{"A" => %{"value" => 1}}}
```

Selector returns true for path `["a"]`.

Result:

```/dev/null/example.ex#L1
%{"a" => %{"value" => 1}, "defs" => %{"A" => %{"value" => 1}}}
```

### Unselected local ref is preserved

Same input, selector returns false.

Result keeps:

```/dev/null/example.ex#L1
%{"a" => %{"$ref" => "#/defs/A"}}
```

### External ref uses loader

A selected ref points to `./common.yaml#/components/parameters/UserId`; loader receives the resolved external resource URI.

### External nested ref uses loaded base URI

A selected external target contains another selected relative ref. The nested ref resolves relative to the loaded document's `base_uri`.

### Selected non-string ref errors

A selected node like `%{"$ref" => 123}` returns an invalid-ref error.

### Unselected non-string ref is preserved or errors?

Recommendation: only selected `$ref` nodes are interpreted. Unselected nodes should be preserved even if `$ref` is not a string. This keeps the API strictly selector-driven.

### Cycle errors

Two selected refs pointing to each other should return a cycle error.

## Implemented Minimum API

The implemented API shape is:

```/dev/null/example.ex#L1
JSONSchex.Ref.resolve_selected(document,
  select: select_fun,
  base_uri: base_uri,
  loader: loader
)
```

Only `:select` is required. `:base_uri` and `:loader` are optional until a selected external ref needs them.

## Oasis Integration

`Oasis.Spec.OpenAPIRefResolver` now delegates generic `$ref` mechanics to `JSONSchex.Ref.resolve_selected/2` and keeps only:

- OpenAPI Reference Object selection policy
- Oasis-specific error message wrapping
- `Oasis.Spec.Document.load_external/1` as the loader

The first version remains intentionally small:

- required `:select`
- optional `:base_uri`
- optional `:loader`
- selected refs replace their node
- selected ref siblings are ignored
- selected cycles are errors
- unselected refs remain unresolved but may be visibly rebased to preserve external resource context

This would let Oasis keep OpenAPI policy in Oasis while moving reusable `$ref` mechanics to JSONSchex.
