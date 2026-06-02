# RFC 0001: Oasis and JSONSchex Boundary for OpenAPI Schema References

- Status: Implemented in Oasis with JSONSchex `0.7.0`
- Created: 2026-05-20
- Updated: 2026-05-23
- Target projects: `oasis`, `jsonschex`

## Summary

Oasis should own OpenAPI document ingestion, OpenAPI-aware reference resolution, operation extraction, and generated Plug code. JSONSchex should own JSON Schema graph compilation and validation, including `$ref`, external resources, recursion, nested `$id`, anchors, and future `$dynamicRef` behavior.

The key capability is a JSONSchex API that compiles a schema fragment in its original document/resource context. With `JSONSchex.compile_fragment/2`, `JSONSchex.Schema.compile_fragment!/2`, and `JSONSchex.bundle_fragment/2`, Oasis can stop eagerly expanding JSON Schema references across the whole OpenAPI document and avoid Oasis-specific synthetic `$defs` bundling.

## Motivation

Oasis generates Plug routers and request validators from an OpenAPI document. OpenAPI 3.1 uses JSON Schema for schema definitions, but OpenAPI documents also contain their own Reference Objects. This creates two related but different forms of `$ref`:

1. OpenAPI Reference Objects used to reuse OpenAPI structures such as parameters, request bodies, responses, headers, and path items.
2. JSON Schema `$ref` keywords used inside Schema Objects.

Treating every `$ref` in the full OpenAPI document as the same kind of reference leads to a complex architecture. In particular, when Oasis eagerly expands references and later extracts isolated schema fragments for generated code, recursive references and external schema files require additional rebasing logic. That rebasing logic does not naturally belong in Oasis.

This RFC proposes a clearer boundary:

- Oasis resolves OpenAPI structure.
- JSONSchex resolves and compiles JSON Schema graphs.
- Generated Oasis code keeps using compile-time JSON Schema compilation through `JSONSchex.Schema.compile!/2` or a future fragment-aware equivalent.

## Goals

- Keep generated Plug code explicit and compile-time validated.
- Use JSONSchex as the single owner of JSON Schema compilation and validation semantics.
- Avoid Oasis-specific JSON Schema rebasing/bundling logic.
- Support local component schemas, relative external schema files, recursive schemas, nested `$id`, and anchors through JSONSchex.
- Prepare the architecture for future `$dynamicRef` support without adding Oasis-specific special cases.
- Keep `mix oas.gen.plug --file path/to/openapi.yaml` as the primary user-facing workflow.

## Non-goals

- This RFC does not propose arbitrary network loading as a default Oasis behavior.
- This RFC does not require adding a separate `--shared-file` CLI option.
- This RFC does not attempt to fully specify `$dynamicRef` implementation details.
- This RFC does not require changing Oasis runtime validation away from compiled `JSONSchex.Types.Schema` values.

## Current Problem

The difficult case is not simply resolving one `$ref`. The difficult case is compiling a schema fragment that originally lived inside a larger document/resource graph.

For example, Oasis may extract a request body schema from an operation. That schema might contain:

- `#/components/schemas/User`
- `./schemas/user.yaml`
- `./schemas/node.yaml#/$defs/Node`
- recursive references back to itself or another schema
- nested `$id` values that change the base URI for nested references

If Oasis extracts only the raw schema map and later compiles that map as a standalone root schema, local references can lose their original meaning. A local reference such as `#/components/schemas/User` points to the OpenAPI root document, not to the extracted fragment.

The previous direction solved this by adding Oasis-side expansion and bundling. That works for many cases, but it creates architectural friction:

- Oasis starts owning JSON Schema graph behavior.
- OpenAPI refs and JSON Schema refs are conflated.
- Recursive refs require special preservation behavior.
- Extracted fragments require synthetic `$defs` mount points.
- Future `$dynamicRef` support would likely add more Oasis-side complexity.

## Proposed Boundary

### Oasis Responsibilities

Oasis should own:

1. Root OpenAPI document loading.
2. YAML/JSON parsing.
3. Source path tracking.
4. OpenAPI-aware traversal.
5. OpenAPI Reference Object resolution where needed for operation extraction.
6. Operation, parameter, request body, response, and security extraction.
7. Plug/router code generation.
8. User-facing mix task behavior.

Oasis may provide a loader function for local YAML/JSON resources, but the schema meaning of those resources should be interpreted by JSONSchex.

### JSONSchex Responsibilities

JSONSchex should own:

1. JSON Schema compilation.
2. JSON Schema validation.
3. JSON Schema `$ref` resolution.
4. External schema resource loading through a caller-provided loader.
5. Recursive schema graphs.
6. Nested `$id` base URI rules.
7. `$anchor` and future `$dynamicAnchor`/`$dynamicRef` behavior.
8. Producing embeddable compile-time schema values.
9. Producing standalone bundled schema maps for code generation workflows.

### Design Principle

Oasis should not make JSON Schema refs standalone by rewriting them. Instead, Oasis should preserve enough context for JSONSchex to compile the schema correctly.

## OpenAPI Reference Handling

Oasis still needs an OpenAPI-aware resolver, but it should be more targeted than a generic full-document `$ref` expander.

The resolver is now represented by `Oasis.Spec.OpenAPIRefResolver`. It understands OpenAPI Reference Objects and resolves them where Oasis needs complete OpenAPI structures. Examples include:

- path item refs
- operation parameter refs
- request body refs
- response refs

The resolver does not eagerly inline arbitrary JSON Schema `$ref` keywords inside Schema Objects. Schema Objects are treated as JSON Schema graph entrypoints and handed to JSONSchex with their context.

## Schema Entrypoints

When Oasis extracts a schema for generated request validation, it should treat it as a schema entrypoint rather than a standalone schema map.

A schema entrypoint conceptually contains:

- the schema value or an entry pointer/ref
- the containing document or resource
- the base URI/path for relative reference resolution
- the optional loader used to resolve external resources when they are still reachable
- JSONSchex compile options such as format/content assertion settings

A concrete Oasis struct may be introduced later, but the important design point is that Oasis should carry context instead of rewriting refs.

Potential Oasis-side shape:

- `schema`: the raw schema fragment, or an entry reference into a document
- `document`: the containing OpenAPI or schema resource document
- `base_uri`: base URI/path for the containing document, usually derived from `Oasis.Spec.Document.source_path`
- `entry_pointer`: JSON Pointer to the schema inside the containing document, when known
- `loader`: optional Oasis external document loader, included only when unresolved external refs may still be reached

This does not need to be part of the public user API initially. It can remain an internal generation representation.

## Generated Code

Generated code should continue to compile schemas at module compile time.

Preferred generated-code form today:

- `JSONSchex.Schema.compile!/2`

Preferred generated-code form after upstream support:

- `JSONSchex.Schema.compile_fragment!/2`
- or `JSONSchex.Schema.compile!/2` over a JSONSchex-produced standalone bundled schema from `JSONSchex.bundle_fragment/2`

The generator should prefer explicit compile calls over sigils because generated code often needs visible options such as `:base_uri`. Loader options should be generated only when external resource loading is still required.

The `~X` sigil remains useful for concise handwritten schemas and tests, but it should not be the main generated-code representation.

## Implemented JSONSchex API

JSONSchex now provides fragment compilation and bundling in document context.

Implemented APIs:

- `JSONSchex.compile_fragment(document, opts)`
- `JSONSchex.Schema.compile_fragment!(document, opts)`
- `JSONSchex.bundle_fragment(document, opts)`

Implemented options:

- `:entry_pointer` - JSON Pointer to the schema fragment within the document
- `:entry_ref` - alternative entry reference, such as `#/paths/~1pets/post/requestBody/content/application~1json/schema` or `path-or-uri#/components/schemas/User`
- `:base_uri` - optional starting base URI/path for relative reference resolution; when `:entry_ref` includes a base and `:base_uri` is omitted, the entry ref base is used
- `:loader` - optional external document loader, included only when unresolved external resources may still be reached
- `:format_assertion` - existing JSONSchex option
- `:content_assertion` - existing JSONSchex option

There is no public `:document` option because the document is the first argument. There is no top-level `:source` option because `:base_uri` is the reference-resolution identity.

Callers must provide exactly one of `:entry_pointer` or `:entry_ref`.

Expected behavior:

1. Locate the schema entrypoint in the containing document.
2. Compile the schema as a JSON Schema resource in that original context.
3. Resolve local refs against the correct containing resource.
4. Resolve external refs through `:loader` when a loader is provided and an unresolved external resource is reached.
5. Honor nested `$id` and anchors.
6. Preserve recursive refs as graph references in the compiled schema.
7. Return an embeddable `JSONSchex.Types.Schema` value or raise a compile error from the macro form.

## Implemented JSONSchex Bundling API

`JSONSchex.bundle_fragment(document, opts)` produces a standalone raw schema map/boolean from a fragment and its context.

Implemented behavior:

1. Start from a schema entrypoint inside a containing document/resource.
2. Preserve local document context.
3. Load reachable external resources when `:loader` is provided.
4. Mount reachable external resources under `$defs`.
5. Rewrite external refs to the mounted `$defs` resources.
6. Return a raw schema map/boolean suitable for `JSONSchex.Schema.compile!/2`.

This is useful when generated code should remain a single standalone literal schema map.

## External and Shared Files

The default Oasis CLI does not need a separate shared-files option.

The root OpenAPI file plus an optional loader is enough for common shared-file workflows:

- the root document establishes the initial base URI/path
- references discover external files transitively
- the loader resolves relative YAML/JSON files
- JSONSchex interprets the loaded resources as schema resources where applicable

A future Oasis API may allow callers to customize the loader or search roots, but this is separate from schema semantics.

## Recursive References

Recursive schemas should remain schema graph references. Oasis should not attempt to fully inline them.

With the proposed boundary:

- Oasis extracts the schema entrypoint and context.
- JSONSchex compiles the graph.
- Recursive edges remain references in the compiled representation.
- Validation follows the compiled graph.

If standalone generated schema literals are required, JSONSchex should provide bundling/rebasing behavior itself.

## `$dynamicRef`

This RFC does not require immediate `$dynamicRef` support. However, the architecture should not force Oasis to special-case it later.

Because `$dynamicRef` is a JSON Schema concept, it should be implemented in JSONSchex. Oasis should pass the original document/resource context and base URI to JSONSchex so future dynamic scope behavior has enough information.

## Implementation Status

Completed:

- Documented the Oasis/JSONSchex ownership boundary.
- Released and integrated JSONSchex `0.7.0`.
- Added `JSONSchex.compile_fragment/2`, `JSONSchex.Schema.compile_fragment!/2`, `JSONSchex.bundle_fragment/2`, and `JSONSchex.Ref.resolve_selected/2` upstream in JSONSchex.
- Replaced Oasis whole-document generic `$ref` expansion with `Oasis.Spec.OpenAPIRefResolver` backed by `JSONSchex.Ref.resolve_selected/2`.
- Preserved Schema Object `$ref`s for JSONSchex fragment/bundle handling.
- Prepared generated schemas with `JSONSchex.bundle_fragment/2` and emitted `JSONSchex.Schema.compile!/2` in generated code.
- Removed `ex_json_schema` and `Oasis.Spec.Utils`.
- Added tests for external OpenAPI refs, external JSON Schema refs, recursive schemas, custom loaders, selected ref resolution, generation diagnostics, runtime source metadata, and compact bundled schemas.

## Testing Strategy

Oasis tests should cover behavior at the generator and validator boundary:

- generated code compiles
- generated validators accept valid requests
- generated validators reject invalid requests
- local OpenAPI component schemas work
- relative external schema files work
- recursive schemas work
- missing external files produce user-friendly errors
- invalid schemas fail during generation or generated-module compilation with useful messages

JSONSchex tests should cover schema graph semantics directly:

- fragment compilation from an OpenAPI-like containing document
- local JSON Pointer refs from a fragment into the containing document
- relative external refs
- nested `$id` base URI changes
- anchors
- recursive refs
- invalid/missing refs
- embeddability through `JSONSchex.Schema.compile_fragment!/2`

## Integration Decisions and Open Questions

Resolved for the first Oasis integration:

1. Oasis uses `JSONSchex.bundle_fragment/2` during generation and emits `JSONSchex.Schema.compile!/2` over standalone bundled schemas. This keeps generated code compact and avoids embedding the full OpenAPI document in every generated module.
2. Oasis resolves a single `:loader` up front for every `JSONSchex.bundle_fragment/2` call (default `&Oasis.Spec.Document.load_external/1`). JSONSchex only invokes the loader when an unresolved external `$ref` is actually reached, so self-contained schemas pay no behavioral cost. Callers can override with `:loader` or pass `loader: nil` to disable external loading explicitly. The earlier "try without a loader, then retry with one" fallback was removed because it could mask the original (often structural) error.
3. Oasis does not normalize OpenAPI 3.1/3.2 Schema Objects before handing them to JSONSchex. JSONSchex is the owner of JSON Schema Draft 2020-12 semantics and compatibility handling such as `dependencies`.

Resolved for the follow-up Oasis integration:

1. Schema generation diagnostics now include entry pointer/ref and base URI context when JSONSchex bundling or precheck compilation fails.
2. Library callers can pass a custom JSONSchex-compatible `:loader` through Oasis generation options. The mix task continues to use the default local YAML/JSON loader.
3. OpenAPI source metadata is exposed at **generation time only**, as the public `:source_meta` field on `%Mix.Oasis.Router{}`. It identifies each extracted schema structurally (`path`, `http_verb`, `parameter_location`/`parameter_name` for parameters; `content_type` for bodies) using the user's original OpenAPI URL shape. Runtime JSON Schema validation errors deliberately do **not** carry this metadata: route/parameter context is already available via `Plug.Conn` plus `Oasis.BadRequestError`'s `:use_in` / `:param_name`, and deep-links into the OpenAPI document are a tooling concern, not a runtime one.
4. Oasis compacts bundled standalone schemas by keeping known JSON Schema document keywords plus the OpenAPI `components` context. `components` is retained unconditionally for simplicity: conditional retention would require a full bundled-graph scan for `$ref`s into `#/components/...`, which adds non-trivial complexity for no observable behavioral benefit (JSONSchex tolerates unreferenced sibling keys, and OpenAPI documents typically already have `components`).

Still open:

1. Whether to expose custom loader/search-root configuration through a future public mix task option.
2. Whether to expose YAML/JSON line/column data from `Oasis.Spec.Document.load*` on `Mix.Oasis.Router.source_meta` for richer downstream tooling (currently only structural OpenAPI fields are exposed, not source-text positions).

## Recommendation

Proceed with the JSONSchex fragment-compilation API as the primary upstream design. Keep Oasis focused on OpenAPI-aware extraction and generated Plug code. Avoid deepening Oasis-owned schema bundling or synthetic `$defs` rebasing.

The final target architecture is:

- Oasis extracts schema entrypoints from OpenAPI.
- Oasis passes schema entrypoint context to JSONSchex.
- JSONSchex compiles and validates the schema graph.
- Generated Oasis code embeds compile-time compiled schemas.
