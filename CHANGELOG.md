# Changelog

## v0.7.0 (2026-08-06)

> **Breaking release.** Oasis 0.7 replaces its JSON Schema engine and changes
> several public APIs [PR #3](https://github.com/xinz/oasis/pull/3). Read the [0.7 migration guide](guides/migrating_to_0_7.md)
> before upgrading.

### Breaking changes

* **JSON Schema engine:** replace `ex_json_schema` with `jsonschex ~> 0.9.0` for JSON Schema Draft 2020-12 compilation and validation. `ex_json_schema` is removed, so checked-in generated modules containing `%ExJsonSchema.Schema.Root{}` must be regenerated before they compile.
* **`Oasis.Spec.read/1`:** successful reads now return `%Oasis.Spec.Document{}` instead of `%ExJsonSchema.Schema.Root{}`. Handwritten integrations must use compiled `%JSONSchex.Types.Schema{}` values; `Oasis.Spec.Utils.expand_ref/1` is removed.
* **Validation errors:** rename the `JsonSchemaValidationFailed` suffix to `Oasis.BadRequestError.JSONSchemaValidationFailed`.
* **Token and authentication statuses:** public token helpers and generated callbacks return string statuses such as `"expired"`, `"invalid"`, `"missing"`, and `"invalid_token"` instead of atoms. Plug adapters continue to accept known legacy atom results from custom callbacks.
* **Decoded-map generation:** raw OpenAPI maps are strict by default. Callers using Oasis's legacy pre-grouped parameter maps must explicitly pass `normalized_parameters: true` to `Mix.Oasis.new/2`.
* **Handwritten JSON pipelines:** configure `Oasis.CacheRawBodyReader` as the `Plug.Parsers` body reader. Oasis now fails closed when it cannot distinguish primitive or empty JSON bodies from Plug's map-shaped representations.

### Highlights

* Resolve structural OpenAPI Reference Objects with `JSONSchex.Ref.resolve_selected/2` while preserving Schema Object `$ref`s for JSONSchex. Local and external Security Scheme refs are resolved before generation; invalid structural targets return source-aware `Oasis.InvalidSpecError` values.
* Bundle reachable JSON Schema fragments with JSONSchex, including external resources, recursive schemas, custom loaders, and deep rebasing of unselected refs. Generation always uses one resolved loader call; callers may provide `:loader` or pass `loader: nil` to disable external loading.
* Preserve HTTP coercion for parameter, primitive-body, form, and multipart schemas behind `$ref`s, including refs scoped beneath nested `$id` resources. JSONSchex remains the authority for final validation and asserted formats.
* Distinguish explicit JSON `null` and `{}` from absent bodies through raw-body provenance; match parameterized `application/*+json` and wildcard media ranges; reject ambiguous, unmatched, and unparsed bodies instead of skipping validation. Primitive roots remain under Plug's `_json` map key.
* Preserve JSONSchex's native leaf-first errors while deriving deterministic root-first URI-fragment JSON Pointers for Oasis error reporting, nested arrays, and uploaded files.
* Support single-entry Parameter Objects using `content`, correct `prefixItems` coercion for short arrays and typed tails, and allow multipart uploads only through applicable explicit `binary`/`byte` string schemas. Overlapping schemas, applicators, and active conditionals are evaluated fail-closed.
* Keep JSONSchex's standalone bundles verbatim, preserving custom vocabularies and OpenAPI Schema Object annotations. Generated support pre-plugs are reconciled with production templates, including JSONSchex macros, raw-body readers, notices, and `super(opts)` behavior.
* Rewrite HMAC date examples with standard-library ISO 8601 parsing and update generated callback examples to use string statuses.
* `Mix.Oasis.Router.source_meta` now documents logical operation/input identities rather than exact external-reference targets.

## v0.6.0 (2026-01-29)

* Fix compile fail `inspect_as_struct` in Elixir 1.19
* Fix compile warning and test cases in Elixir 1.19

## v0.5.2 (2025-02-20)

* Fix compile warning in Elixir 1.18
* Fix the broken source url in `mix.exs`

## v0.5.1 (2023-02-14)

* Fix to ensure validation and parse working when request header content type with charset ([issue#15](https://github.com/elixir-oasis/oasis/issues/15))
* Fix to adapt request body (via `Plug.Parsers.JSON`) validation in a `"_json"` key wrapper ([issue#19](https://github.com/elixir-oasis/oasis/issues/19))
* Adapt to use `conn.host` for HMAC authorization when use Plug `"1.14.0"` ([PR#18](https://github.com/elixir-oasis/oasis/pull/18))
* Update compile compatibility with Elixir `~> 1.14` ([PR#21](https://github.com/elixir-oasis/oasis/pull/21))

## v0.5.0 (2022-07-21)

* Fix test failed in OTP24
* Add HMAC based authentication implement ([issue#8](https://github.com/elixir-oasis/oasis/issues/8))
* Some fixing and enhancement ([PR#12](https://github.com/elixir-oasis/oasis/pull/12))

## v0.4.3 (2021-05-13)

* Fix to make properly handle file uploads

## v0.4.2 (2021-05-11)

* Add `--force` and `--quiet` options for mix oas.gen.plug

## v0.4.1 (2021-04-29)

Fix unexpected "..." string in generated `pre_*` module when a large number of parameters defined

## v0.4.0 (2021-04-14)
* Improve errors handle and add a guide about it

## v0.3.1 (2021-04-08)
* Fix incorrectly handle errors in generated plug module
* Simplify `handle_errors/2` process in generated `pre_*` module

## v0.3.0 (2021-04-08)
* Add `conn.private.oasis_router`
* Add a specification extensions guide
* Support Security Scheme Object with Bearer Authentication
* Fix the order to override `x-oasis-name-space` field

## v0.2.1 (2021-03-24)
* Fix unexpected `:body_schema` in generated `pre_*` module

## v0.2.0 (2021-03-23)
* Use `Oasis.Controller`

## v0.1.0 (2021-03-17)
* Implement some parts of OpenAPI definition `*Object` in parse
* Implement a basic router and plugs pipeline process
* Add a mix task `mix task oas.gen.plug` to generate code
* 100% test coverage
