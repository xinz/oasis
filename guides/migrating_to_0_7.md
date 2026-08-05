# Migrating to Oasis 0.7

Oasis 0.7 replaces `ex_json_schema` with `jsonschex`, changes several public status and struct names, and preserves OpenAPI source context in `Oasis.Spec.Document`. These changes require regenerating modules produced by older Oasis releases.

## Update the dependency

Update `mix.exs`:

```elixir
def deps do
  [
    {:oasis, "~> 0.7.0"}
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

## Update project-local generator template overrides

Oasis 0.7 names generator templates by their actual EEx role. If the project
copies or overrides files under `priv/templates/oas.gen.plug`, rename overrides
from `.ex` / `.exs` to `.ex.eex` / `.exs.eex`, for example:

```text
router.ex              -> router.ex.eex
pre_plug.ex            -> pre_plug.ex.eex
plug/request_validator.exs -> plug/request_validator.exs.eex
```

Apply the same suffix change to custom bearer, HMAC, and operation Plug
templates. Otherwise the generator will no longer discover the override.

## Update handwritten schema-validation integrations

Generated schemas and Oasis request validation now use compiled
`%JSONSchex.Types.Schema{}` values, not `%ExJsonSchema.Schema.Root{}` values.
Handwritten `Oasis.Plug.RequestValidator` options or project code that builds
schemas directly must compile them with JSONSchex, for example:

```elixir
require JSONSchex.Schema

schema =
  JSONSchex.Schema.compile!(
    %{"type" => "integer"},
    format_assertion: true,
    content_assertion: false
  )

query_schema = %{
  "id" => %{"required" => true, "schema" => schema}
}
```

Because `JSONSchex.Schema.compile!/2` is a macro, add
`require JSONSchex.Schema` in the module that invokes it. Runtime callers may
instead use `JSONSchex.compile/2` and handle its `{:ok, schema}` / `{:error,
error}` result.

`Oasis.Spec.Utils.expand_ref/1` has been removed. Do not replace it with another
eager expander: retain Schema Object refs and let JSONSchex compile, validate,
and bundle their graph with Draft 2020-12 resource semantics.

Programmatic callers that previously passed Oasis's already-grouped parameter
maps directly to `Mix.Oasis.new/2` must opt in explicitly:

```elixir
Mix.Oasis.new(spec, normalized_parameters: true)
```

Decoded OpenAPI maps use Parameter Object arrays and are validated strictly by
default.

## Configure JSON body provenance in handwritten pipelines

Generated routers automatically cache raw request bodies. A handwritten Plug
pipeline that accepts JSON bodies must use the same body reader so Oasis can
both distinguish Plug's `_json` envelope from a literal object property and
distinguish an absent body from the empty JSON object `{}`:

```elixir
plug Plug.Parsers,
  parsers: [:json],
  pass: ["*/*"],
  json_decoder: Jason,
  body_reader: {Oasis.CacheRawBodyReader, :read_body, []}

plug Oasis.Plug.RequestValidator, body_schema: body_schema
```

Without raw provenance, Oasis deliberately keeps a single-key `_json` map as an
object and fails closed rather than guessing from the schema. An ambiguous empty
parsed map returns an actionable 415 unless framing headers prove that bytes
were present. Validated primitive roots remain in Plug's map-shaped
representation and are available at `conn.body_params["_json"]`.

## Mark multipart uploads explicitly as binary

Oasis 0.7 no longer suppresses JSON Schema type errors for arbitrary
`%Plug.Upload{}` values. Every uploaded part must be authorized by an applicable
string schema with `format: "binary"` or `format: "byte"`.

For multiple files, declare the item schema explicitly:

```yaml
type: array
items:
  type: string
  format: binary
```

Schemas that previously used `{}`, `type: string` without a binary/byte format,
or unconstrained array items now reject uploads. Applicator conflicts and
content-sensitive assertions fail closed because Oasis cannot validate file
contents as an ordinary JSON string.

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

In Oasis 0.6, a successful read returned an `%ExJsonSchema.Schema.Root{}` whose
`schema` had been eagerly expanded by Oasis. Oasis 0.7 instead returns an
`Oasis.Spec.Document`:

```elixir
document = Oasis.Spec.read("path/to/openapi.yaml")
schema = document.schema
```

`document.schema` is the normalized generation view, not a drop-in semantic
replacement for the old `root.schema`: structural OpenAPI Reference Objects are
resolved, while Schema Object `$ref` values deliberately remain for JSONSchex.
The document also retains an immutable `reference_schema`, source path, URL
aliases, and pointer sidecars needed by generation.

Pass the complete document through the Oasis generator (`mix oas.gen.plug`).
Code that only inspects the normalized OpenAPI value may use `document.schema`,
but should not expect eager JSON Schema dereferencing.

File loading/decoding failures and invalid OpenAPI structures recognized during
preparation are returned as `{:error, exception}` tuples.
