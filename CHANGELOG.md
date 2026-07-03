# Changelog

## Unreleased

* Replace `ex_json_schema` with `jsonschex ~> 0.8.1` for JSON Schema Draft 2020-12 compilation and validation.
* Resolve OpenAPI Reference Objects with `JSONSchex.Ref.resolve_selected/2` while preserving Schema Object `$ref`s for JSONSchex.
* Add support coverage for external OpenAPI refs, external JSON Schema refs, recursive schemas, custom loaders, and schema diagnostics in generation.
* `Mix.Oasis.prepare_json_schema!/2` now always invokes `JSONSchex.bundle_fragment/2` with a resolved loader (defaults to `&Oasis.Spec.Document.load_external/1`). Callers can supply a custom loader via `:loader`, or pass `loader: nil` to explicitly disable external loading.
* **Breaking (unreleased only):** rename `Oasis.BadRequestError.JsonSchemaValidationFailed` to `Oasis.BadRequestError.JSONSchemaValidationFailed`, and drop its `:source` field. Runtime route/parameter context is available from `Plug.Conn` plus the surrounding `Oasis.BadRequestError`'s `:use_in` / `:param_name` fields. For deep-links into the OpenAPI document, see `Mix.Oasis.Router`'s `:source_meta`.
* **Breaking (unreleased only):** normalize token/auth verification error statuses to strings in public callbacks and token helpers. `Oasis.Token.verify/2`, `Oasis.Token.decrypt/2`, and `Oasis.HMACToken.verify/3` now return statuses such as `"expired"`, `"invalid"`, and `"invalid_token"` instead of atoms. Plug adapters remain backward-compatible with existing custom callbacks that still return the old atom statuses.
* Remove `ex_json_schema` as a (transitive) dependency.

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
