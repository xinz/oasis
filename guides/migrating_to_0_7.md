# Migrating to Oasis 0.7

Oasis 0.7 replaces `ex_json_schema` with `jsonschex`, changes several public status and struct names, and preserves OpenAPI source context in `Oasis.Spec.Document`. These changes require regenerating modules produced by older Oasis releases.

## Update the dependency

Update `mix.exs`:

```elixir
def deps do
  [
    {:oasis, "~> 0.7"}
  ]
end
```

Then fetch the new dependency without compiling stale checked-in generated
modules first:

```shell
mix deps.get
```

## Regenerate checked-in modules before compiling

Generated `pre_*.ex` modules from Oasis 0.6 may contain
`%ExJsonSchema.Schema.Root{}` values. Those modules cannot compile after
`ex_json_schema` is removed.

Run the generator before `mix compile`:

```shell
mix oas.gen.plug --file path/to/openapi.yaml --force
mix compile
```

The generator overwrites managed router and `pre_*.ex` files. It does not
replace existing user-owned operation handler modules generated with the
`:new_eex` policy.

If a project bootstrap script currently runs `mix compile` before generation,
change the order to:

1. `mix deps.get`
2. `mix oas.gen.plug --file ... --force`
3. `mix compile`
4. `mix test`

After regeneration, remove an explicit `ex_json_schema` dependency if the
application added it only for Oasis-generated modules.

## Validation error struct rename

Replace matches using the old `JsonSchemaValidationFailed` struct suffix with:

```elixir
%Oasis.BadRequestError.JSONSchemaValidationFailed{}
```

The nested error now contains a `JSONSchex.Types.Error`, and its `:path` is a
root-first URI-fragment JSON Pointer such as `"#/users/0/name"`. Runtime route and
parameter context remains on the surrounding `Oasis.BadRequestError` through
`:use_in` and `:param_name`.

## Token and authentication statuses

Public token helpers and callbacks now use string status codes:

```elixir
{:error, "expired"}
{:error, "invalid"}
{:error, "missing"}
{:error, "invalid_token"}
```

Update direct callers and custom callbacks that pattern-match atoms. The Bearer
and HMAC Plug adapters temporarily accept legacy callback atoms such as
`:expired` and `:invalid_token`, but helper callers receive strings directly.

## `Oasis.Spec.read/1`

Successful reads now return an `Oasis.Spec.Document` instead of the decoded map:

```elixir
document = Oasis.Spec.read("path/to/openapi.yaml")
schema = document.schema
```

Pass the complete document into Oasis generation so its `source_path` and URL
aliases remain available. Code that only inspects the decoded OpenAPI value can
use `document.schema`.

File and specification failures continue to return `{:error, exception}`.
