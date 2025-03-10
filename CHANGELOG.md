# Changelog

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
