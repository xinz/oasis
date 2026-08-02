# Changelog

## v0.7.0 (Unreleased)

* Replace `ex_json_schema` with `jsonschex ~> 0.9.0` for JSON Schema Draft 2020-12 compilation and validation, reachable fragment bundling, and deep rebasing of unselected refs.
* Resolve OpenAPI Reference Objects with `JSONSchex.Ref.resolve_selected/2` while preserving Schema Object `$ref`s for JSONSchex.
* Add support coverage for external OpenAPI refs, external JSON Schema refs, recursive schemas, custom loaders, and schema diagnostics in generation. Complete generated handler, pre-plug, and router modules are compiled and executed for external and recursive schema fixtures.
* Resolve local and external Security Scheme Reference Objects before generation and reject non-object structural Reference Object targets with source-aware `Oasis.InvalidSpecError` messages.
* Preserve request coercion when effective parameter, primitive-body, form, or multipart schema types are behind JSON Schema `$ref`s.
* Preserve JSONSchex's native leaf-first error paths while deriving root-first URI-fragment JSON Pointers for Oasis error reporting, sorting, nested arrays, and uploaded files.
* Use JSONSchex as the single authority for asserted JSON Schema formats.
* Support single-entry Parameter Objects that use `content`, correct `prefixItems` coercion for short arrays and typed tails, and accept multipart uploads only for explicit `binary`/`byte` string schemas, including nullable string unions.
* Generation-time schema preparation now always invokes `JSONSchex.bundle_fragment/2` with a resolved loader (defaults to `&Oasis.Spec.Document.load_external/1`). Callers can supply a custom loader via `:loader`, or pass `loader: nil` to explicitly disable external loading.
* **Breaking (unreleased only):** rename the old `JsonSchemaValidationFailed` error suffix to `Oasis.BadRequestError.JSONSchemaValidationFailed`. Runtime route/parameter context is available from `Plug.Conn` plus the surrounding `Oasis.BadRequestError`'s `:use_in` / `:param_name` fields. For deep-links into the OpenAPI document, see `Mix.Oasis.Router`'s `:source_meta`.
* **Breaking (unreleased only):** normalize token/auth verification error statuses to strings in public callbacks and token helpers. `Oasis.Token.verify/2`, `Oasis.Token.decrypt/2`, and `Oasis.HMACToken.verify/3` now return statuses such as `"expired"`, `"invalid"`, `"missing"`, and `"invalid_token"` instead of atoms. Plug adapters remain backward-compatible with existing custom callbacks that still return old atom statuses; generated and test callback implementations use the current string contract.
* Document `Oasis.Spec.read/1` as the public ingestion API returning `%Oasis.Spec.Document{}` and clarify that `Mix.Oasis.Router.source_meta` identifies logical operation inputs rather than exact external ref targets.
* Rewrite HMAC date examples with standard-library ISO 8601 parsing and update generated callback examples to use string statuses.
* Reconcile overwriteable generated support pre-plugs with production templates, including JSONSchex macros, raw-body readers, notices, and `super(opts)` behavior.
* Remove `ex_json_schema` as a (transitive) dependency.
* See the [0.7 migration guide](guides/migrating_to_0_7.md) for generated-module regeneration and public API changes.

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
