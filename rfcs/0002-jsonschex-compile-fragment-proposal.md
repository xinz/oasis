# Proposal to JSONSchex: Compile JSON Schema Fragments in Document Context

- Status: Implemented in JSONSchex `0.7.0`; integrated in Oasis
- Created: 2026-05-20
- Updated: 2026-05-23
- Originating use case: Oasis OpenAPI-to-Plug code generation
- Target project: `jsonschex`

## Summary

Oasis needs to compile JSON Schema fragments that are embedded inside a larger OpenAPI document. Calling `JSONSchex.compile/2` on the extracted fragment alone is not always sufficient, because references inside the fragment may depend on the original containing document, base URI, nested `$id` scopes, anchors, or external resources.

JSONSchex now provides fragment-aware APIs for this use case:

- `JSONSchex.compile_fragment(document, opts)`
- `JSONSchex.Schema.compile_fragment!(document, opts)`
- `JSONSchex.bundle_fragment(document, opts)`

The containing document is always passed as the first argument. There is intentionally no public `compile_fragment(opts)` or `compile_fragment!(opts)` variant with `document: ...`, because the document is required and is clearer as an explicit argument.

## Oasis Use Case

Oasis reads an OpenAPI 3.1 document and generates Plug routers and request validators. OpenAPI 3.1 uses JSON Schema for Schema Objects, so Oasis eventually needs compiled `JSONSchex.Types.Schema` values for:

- path parameters
- query parameters
- header parameters
- cookie parameters
- request bodies

Generated Oasis code should compile these schemas at module compile time with a JSONSchex macro, similar to the existing `JSONSchex.Schema.compile!/2` flow.

The difficult part is that Oasis often extracts a schema fragment from the OpenAPI document before generating code. That fragment may contain references such as:

- `#/components/schemas/User`
- `#/components/parameters/UserId/schema`
- `./schemas/user.yaml`
- `./schemas/tree.yaml#/$defs/Node`
- `#UserAnchor`

Those references are meaningful in the original document/resource context. If the fragment is compiled as a standalone root schema, the reference base can be wrong.

## Example Problem

Given this OpenAPI document:

```yaml
openapi: 3.1.0
info:
  title: Example API
  version: 1.0.0
paths:
  /users:
    post:
      requestBody:
        required: true
        content:
          application/json:
            schema:
              $ref: '#/components/schemas/UserInput'
components:
  schemas:
    UserInput:
      type: object
      required: [name]
      properties:
        name:
          type: string
        manager:
          $ref: '#/components/schemas/UserSummary'
    UserSummary:
      type: object
      required: [id]
      properties:
        id:
          type: integer
```

Oasis can locate the request body schema at this JSON Pointer:

- `#/paths/~1users/post/requestBody/content/application~1json/schema`

The schema fragment itself is only:

```elixir
%{"$ref" => "#/components/schemas/UserInput"}
```

Compiling only that map as a standalone schema is ambiguous or incorrect, because `#/components/schemas/UserInput` points to the OpenAPI root document, not to a property in the isolated map.

Oasis needs to say:

> Compile this schema entrypoint inside this containing document, with this base URI and optional loader.

## Why Existing Standalone APIs Are Not Enough

`JSONSchex.compile/2` works well when the input is a standalone JSON Schema resource. However, Oasis often has a schema fragment that is not standalone.

`JSONSchex.Ref` traversal APIs are useful low-level tools, but if Oasis uses them to rewrite, inline, or bundle schemas itself, Oasis starts owning JSON Schema graph semantics. That creates several problems:

- Oasis has to distinguish OpenAPI Reference Objects from JSON Schema `$ref` keywords.
- Recursive JSON Schema graphs become an Oasis preprocessing concern.
- External schemas require Oasis-specific rebasing or synthetic `$defs` mount points.
- Nested `$id` and anchors become difficult to preserve correctly after rewriting.
- Future `$dynamicRef` support would likely require more Oasis-specific logic.

The fragment compilation API keeps this responsibility in JSONSchex, where JSON Schema semantics already belong.

## Implemented Runtime APIs

JSONSchex implements:

```elixir
JSONSchex.compile_fragment(document, opts)
JSONSchex.bundle_fragment(document, opts)
```

The containing `document` is required and must be a map or boolean. The options identify which schema fragment inside that document should be compiled or bundled.

Example for a fragment whose reachable references are already contained in the provided document/context:

```elixir
JSONSchex.compile_fragment(openapi_document,
  entry_pointer: "#/paths/~1users/post/requestBody/content/application~1json/schema",
  base_uri: "/absolute/path/openapi.yaml",
  format_assertion: true,
  content_assertion: false
)
```

If the entrypoint can still reach unresolved external resources, the caller may add `:loader`:

```elixir
JSONSchex.compile_fragment(openapi_document,
  entry_pointer: "#/paths/~1users/post/requestBody/content/application~1json/schema",
  base_uri: "/absolute/path/openapi.yaml",
  loader: &MyApp.SchemaLoader.load/1,
  format_assertion: true,
  content_assertion: false
)
```

Expected compile return:

```elixir
{:ok, %JSONSchex.Types.Schema{}} | {:error, JSONSchex.Types.Error.t() | term()}
```

Expected bundle return:

```elixir
{:ok, map() | boolean()} | {:error, JSONSchex.Types.Error.t() | term()}
```

## Implemented Compile-Time API

JSONSchex implements:

```elixir
JSONSchex.Schema.compile_fragment!(document, opts)
```

This mirrors the purpose of `JSONSchex.Schema.compile!/2`: embed a compiled schema into the caller module at compile time.

Example generated code:

```elixir
require JSONSchex.Schema

@body_schema JSONSchex.Schema.compile_fragment!(
  %{
    "openapi" => "3.1.0",
    "paths" => %{
      "/users" => %{
        "post" => %{
          "requestBody" => %{
            "content" => %{
              "application/json" => %{
                "schema" => %{"$ref" => "#/components/schemas/UserInput"}
              }
            }
          }
        }
      }
    },
    "components" => %{
      "schemas" => %{
        "UserInput" => %{
          "type" => "object",
          "required" => ["name"],
          "properties" => %{"name" => %{"type" => "string"}}
        }
      }
    }
  },
  entry_pointer: "#/paths/~1users/post/requestBody/content/application~1json/schema",
  base_uri: "/absolute/path/openapi.yaml",
  format_assertion: true,
  content_assertion: false
)
```

Oasis should not add `:loader` by default. It should include `loader: &Oasis.Spec.Document.load_external/1` only when generation-time analysis determines the schema entrypoint can still reach unresolved external resources. If Oasis has already resolved or bundled the schema so compilation is self-contained, generated code should omit `:loader`.

## Implemented Option Model

### `document` first argument

The containing document/resource is the first argument to `compile_fragment/2`, `bundle_fragment/2`, and `compile_fragment!/2`.

This may be a full OpenAPI document or a JSON Schema resource. The document root does not need to be a JSON Schema. The entrypoint option identifies which value inside the document should be compiled or bundled as a JSON Schema.

There is no `:document` option in the public API.

### `:entry_pointer`

A JSON Pointer identifying the schema entrypoint inside `document`.

The pointer may use either form:

- `#/paths/~1users/post/requestBody/content/application~1json/schema`
- `/paths/~1users/post/requestBody/content/application~1json/schema`

### `:entry_ref`

A URI-reference-style alternative to `:entry_pointer`.

Examples:

- `#/components/schemas/UserInput`
- `/absolute/path/openapi.yaml#/components/schemas/UserInput`

When `:entry_ref` includes a base URI/path and `:base_uri` is omitted, JSONSchex uses the base from `:entry_ref` for relative reference resolution.

### Exactly one entrypoint option

Callers must provide exactly one of:

- `:entry_pointer`
- `:entry_ref`

Providing neither is invalid. Providing both is invalid.

### `:base_uri`

Optional starting base URI/path for resolving relative references.

Use `:base_uri` when an `:entry_pointer` fragment can reach relative external refs, or when the containing document has a meaningful file path/URI that should act as the reference base.

When `:entry_ref` includes a base URI/path and `:base_uri` is omitted, JSONSchex uses the base from `:entry_ref`.

There is no top-level `:source` option in the implemented fragment API.

### `:loader`

An optional caller-provided loader for external resources.

Callers should include this option only when external resource loading is actually needed. From the Oasis side, generated code should add `loader: &Oasis.Spec.Document.load_external/1` only after detecting that the schema entrypoint can still reach unresolved external file refs. If the schema has already been resolved, bundled, or otherwise made self-contained, Oasis should omit `:loader`.

The loader supports decoded JSON Schema resources and optional wrapper metadata:

```elixir
(String.t() ->
   {:ok, map() | boolean()}
   | {:ok, %{document: map() | boolean(), base_uri: String.t()}}
   | {:error, term()})
```

Wrapper metadata uses atom keys only. String keys such as `"document"` and `"base_uri"` are treated as normal decoded JSON content, not loader metadata.

For Oasis, the loader reads local YAML/YML/JSON files and returns decoded maps. It is a conditional compile option, not part of every generated schema compile call.

### Existing compile options

The fragment API passes through existing compile options such as:

- `:format_assertion`
- `:content_assertion`

It should also preserve any future JSONSchex compile options.

## Expected Semantics

`compile_fragment/2` should:

1. Validate that the containing document is a map or boolean.
2. Validate that exactly one of `:entry_pointer` or `:entry_ref` is provided.
3. Resolve the entrypoint from `:entry_pointer` or `:entry_ref`.
4. Treat the entrypoint as the root schema to compile.
5. Preserve the containing document as the root reference context for local refs that point outside the fragment.
6. Resolve relative external refs using the correct base URI and nested `$id` rules.
7. Load external resources through `:loader` only when a loader is provided and an unresolved external resource is reached.
8. Honor `$id`, `$anchor`, and existing JSON Schema reference behavior.
9. Preserve recursive schemas as graph references rather than requiring inlining.
10. Return a normal `%JSONSchex.Types.Schema{}` suitable for `JSONSchex.validate/2`.

## Reference Resolution Model

A schema fragment has two related identities:

1. The entrypoint schema being compiled.
2. The containing resource used for resolving local references.

For example, if the root document base URI is `/api/openapi.yaml` and the entrypoint is:

- `#/paths/~1users/post/requestBody/content/application~1json/schema`

then a `$ref` inside that entrypoint such as:

- `#/components/schemas/UserInput`

should resolve to:

- `/api/openapi.yaml#/components/schemas/UserInput`

not:

- `/api/openapi.yaml#/paths/~1users/post/requestBody/content/application~1json/schema/components/schemas/UserInput`

and not:

- `#/components/schemas/UserInput` inside an isolated schema map.

Nested `$id` should still change the base URI according to JSON Schema rules once compilation enters a subschema resource.

## Diagnostics

Errors should ideally include enough context for tools such as Oasis to produce actionable messages.

Useful diagnostic fields would include:

- base URI/path
- entry pointer or entry ref
- ref string that failed
- resolved absolute URI, when available
- loader error, when applicable
- target pointer, when applicable

The implemented test coverage includes ambiguous, missing, and invalid entrypoint formatting, missing local refs, and missing external resource diagnostics.

## Implemented Companion API: Bundle a Fragment

JSONSchex implements:

```elixir
JSONSchex.bundle_fragment(document, opts)
```

Example:

```elixir
{:ok, standalone_schema} =
  JSONSchex.bundle_fragment(openapi_document,
    entry_pointer: "#/paths/~1users/post/requestBody/content/application~1json/schema",
    base_uri: "/absolute/path/openapi.yaml"
  )

{:ok, compiled} = JSONSchex.compile(standalone_schema)
```

As with `compile_fragment/2`, callers should add `:loader` to `bundle_fragment/2` only if the fragment may need unresolved external resources during bundling.

Implemented bundling behavior:

1. Starts from the same document/context model as `compile_fragment/2`.
2. Preserves local document context.
3. Loads reachable external resources when `:loader` is provided.
4. Mounts reachable external resources under `$defs`.
5. Rewrites external refs to the mounted `$defs` resources.
6. Returns a raw JSON Schema map/boolean that can be compiled later with `JSONSchex.compile/2`.

This API lets Oasis generate simple `JSONSchex.Schema.compile!/2` calls against standalone schema literals when that is preferable, while keeping schema graph rewriting inside JSONSchex.

## Relationship Between `compile_fragment/2` and `bundle_fragment/2`

`compile_fragment/2` directly solves the schema semantics problem.

`bundle_fragment/2` solves the generated-code convenience problem by producing a standalone raw schema. It is implemented as part of the same fragment feature set rather than deferred.

Oasis can choose either path:

- use `JSONSchex.Schema.compile_fragment!/2` when preserving document context in generated code is acceptable
- use `JSONSchex.bundle_fragment/2` at generation time, then emit `JSONSchex.Schema.compile!/2` over the bundled raw schema

## Why Not Require Oasis to Expand Refs First?

Oasis can technically expand some refs before compilation, but that approach is not ideal.

Reasons:

1. JSON Schema references are part of the schema graph, not just a textual include mechanism.
2. Recursive schemas cannot be fully expanded.
3. Nested `$id` changes reference bases and is easy to break when moving fragments.
4. Anchors and future `$dynamicRef` behavior belong to the JSON Schema implementation.
5. Oasis is an OpenAPI generator, not a general-purpose JSON Schema bundler.

Keeping schema graph behavior in JSONSchex reduces duplicated logic and creates a reusable API for other tools that embed JSON Schema fragments in larger documents.

## Compatibility With Existing JSONSchex APIs

This feature does not replace existing APIs.

Existing APIs remain useful:

- `JSONSchex.compile/2` for standalone schemas
- `JSONSchex.Schema.compile!/2` for standalone compile-time schemas
- `JSONSchex.Ref.scan/2`, `resolve/3`, `walk/2`, and `transform/3` for lower-level tooling
- `~X` for concise static schema literals

The new APIs fill different gaps:

- `compile_fragment/2` compiles a schema entrypoint in a containing document context
- `compile_fragment!/2` embeds that behavior at module compile time
- `bundle_fragment/2` returns a standalone raw schema from a contextual entrypoint

## Implemented Test Coverage

Current JSONSchex coverage includes:

- compile fragment runtime API
- compile fragment macro API
- bundle fragment API
- `:entry_pointer` and `:entry_ref` variants
- exactly-one entrypoint validation
- ambiguous, missing, and invalid entrypoint diagnostics
- local refs from fragments resolving against the containing document
- nested local refs
- relative external file refs using `:base_uri`
- external refs with fragments
- recursive local refs
- recursive external refs
- nested `$id`
- anchor refs
- loader wrapper `:base_uri`
- invalid string metadata ignored
- bundle errors without loader
- missing local ref diagnostics
- missing external resource diagnostics

## Implementation Structure

Fragment code has been split out of `JSONSchex.Compiler`:

- `JSONSchex.Compiler.Fragment`
  - entrypoint parsing
  - `:entry_pointer` / `:entry_ref` validation
  - fragment entry resolution
  - fragment error construction

- `JSONSchex.Compiler.Fragment.Bundle`
  - bundling
  - external ref discovery
  - external resource loading
  - `$defs` mounting
  - external ref rewriting

`JSONSchex.Compiler` delegates fragment-specific work to these modules and remains focused on core schema compilation.

## Oasis Integration Status

Resolved in Oasis:

1. Generated code uses `JSONSchex.Schema.compile!/2` over schemas prepared through `JSONSchex.bundle_fragment/2`.
2. Oasis first attempts bundling without a loader, then retries with `loader: &Oasis.Spec.Document.load_external/1` when external resources are needed.
3. Oasis derives `:base_uri` from `Oasis.Spec.Document.source_path` during generation.
4. Schema Object `$ref`s are preserved until JSONSchex fragment/bundle APIs process the schema entrypoint.

Resolved in the follow-up Oasis integration:

1. Generation-time schema errors include entry pointer/ref and base URI context.
2. Library callers can pass a custom JSONSchex-compatible `:loader` through Oasis generation options.
3. Runtime JSON Schema validation errors carry Oasis source metadata when generated schemas include it.
4. Oasis compacts bundled standalone schemas by keeping known JSON Schema document keywords plus the OpenAPI `components` context needed by preserved component refs.

Still open:

1. Whether to expose custom loader/search-root configuration through a future mix task option.
2. Whether to expand runtime source metadata beyond entry pointer and operation context, for example to include line/column data from YAML parsers.

## Minimum API Oasis Can Target

Oasis can target these APIs:

```elixir
JSONSchex.compile_fragment(document,
  entry_pointer: pointer,
  base_uri: base_uri,
  format_assertion: true,
  content_assertion: false
)
```

```elixir
JSONSchex.Schema.compile_fragment!(document,
  entry_pointer: pointer,
  base_uri: base_uri,
  format_assertion: true,
  content_assertion: false
)
```

```elixir
JSONSchex.bundle_fragment(document,
  entry_pointer: pointer,
  base_uri: base_uri
)
```

When Oasis detects unresolved external refs are still reachable from the entrypoint, it should add `loader: &Oasis.Spec.Document.load_external/1` to those options. When the schema is already resolved or bundled into a self-contained representation, Oasis should not include `:loader`.

## Oasis Integration Decision

For the first Oasis-side integration, Oasis uses `JSONSchex.bundle_fragment/2` during generation and then emits `JSONSchex.Schema.compile!/2` over the standalone bundled schema. This keeps generated modules compact and avoids embedding the full OpenAPI document per validator.

Oasis does not normalize OpenAPI 3.1/3.2 Schema Objects before handing them to JSONSchex. JSONSchex owns JSON Schema Draft 2020-12 semantics and compatibility handling such as the pre-2019 `dependencies` keyword.

## Recommendation for Oasis

Use the implemented JSONSchex fragment APIs as the boundary between Oasis OpenAPI processing and JSON Schema graph handling.

From the Oasis perspective, these APIs are the cleanest way to:

- preserve correct JSON Schema reference semantics
- support shared external schema files
- support recursive schemas
- keep OpenAPI-specific logic out of JSONSchex
- keep JSON Schema graph logic out of Oasis
- continue generating explicit compile-time schema code

The selected Oasis generation path is to bundle fragments at generation time with `JSONSchex.bundle_fragment/2` and continue emitting `JSONSchex.Schema.compile!/2` against standalone schemas. Direct generated-code use of `JSONSchex.Schema.compile_fragment!/2` remains available if Oasis later decides that embedding document context is acceptable for a specific workflow.
