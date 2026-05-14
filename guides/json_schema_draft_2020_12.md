# JSON Schema Draft 2020-12 Notes

Oasis now validates request data with `jsonschex` and targets JSON Schema Draft `2020-12` semantics.

This guide documents the current validation defaults and the few compatibility details that still matter when you are writing or migrating OpenAPI schemas.

## Validation defaults

Oasis currently compiles first-party schemas with these options:

- `format_assertion: true`
- `content_assertion: false`

### What this means

#### `format` is validated

Schemas that use `format` are treated as assertions, not only annotations.

Examples:

- `format: email` is validated
- invalid email input fails request validation

This matches the current Oasis behavior expected by the test suite.

#### Content vocabulary is not asserted

Schemas that use content-related keywords are compiled, but content assertions are currently disabled.

Examples:

- `contentMediaType`
- `contentEncoding`

These keywords are therefore treated as non-asserting metadata in current Oasis request validation.

## Prefer Draft 2020-12 schema shapes

When you write OpenAPI schemas for use with Oasis, prefer current Draft `2020-12` keywords and shapes.

### Tuple array validation

Prefer:

- `prefixItems`

instead of older tuple-style array forms based on:

- `items` as a list
- `additionalItems`

### Property dependencies

Prefer:

- `dependentRequired`

instead of older dependency forms based on:

- `dependencies`

## Compatibility notes

### `$ref` preprocessing in Oasis

Before request-validation schemas are compiled, Oasis preprocesses the OpenAPI document and eagerly expands `$ref` values.

Current preprocessing behavior:

- local JSON Pointer refs are expanded
- relative external refs to local YAML and JSON files are expanded
- nested `$id` values affect the base URI used for nested schema refs
- anchors in resolved content are preserved
- sibling fields next to `$ref` are currently ignored during expansion

This is a preprocessing behavior of Oasis, separate from the runtime validation behavior provided by `jsonschex`.

Oasis still has a parsing/coercion layer that runs before JSON Schema validation.

That parsing layer keeps a small amount of compatibility behavior for some older schema shapes, but those forms should not be treated as the recommended authoring style.

### Legacy tuple coercion in `Oasis.Parser`

`Oasis.Parser` still recognizes tuple-style array coercion when `items` is given as a list.

This is useful for internal parsing behavior and older tests, but new schemas should use:

- `prefixItems`

for Draft `2020-12` compatibility.

### Legacy dependency-driven coercion in `Oasis.Parser`

`Oasis.Parser` still looks at `dependencies` when extracting extra property schemas for object coercion.

This is only a parsing compatibility behavior.

For request validation semantics, current schemas should prefer:

- `dependentRequired`

## Practical guidance

If you are authoring or updating an OpenAPI document for Oasis:

1. Write schemas in Draft `2020-12` style.
2. Expect `format` to be validated.
3. Do not rely on `contentMediaType` / `contentEncoding` to reject input in the current implementation.
4. Treat older parser-compatible forms such as `dependencies` and tuple-style `items` lists as migration leftovers, not preferred schema shapes.

## Summary

The safest mental model is:

- **validation semantics** → Draft `2020-12` via `jsonschex`
- **format** → asserted
- **content vocabulary** → currently annotation-only in practice
- **some older shapes** → may still be tolerated by the parsing layer, but are not the preferred schema style
