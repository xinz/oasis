# Oasis

[![hex.pm version](https://img.shields.io/hexpm/v/oasis.svg?v=1)](https://hex.pm/packages/oasis)
[![Coverage Status](https://coveralls.io/repos/github/elixir-oasis/oasis/badge.svg?branch=main)](https://coveralls.io/github/elixir-oasis/oasis?branch=main)

## Introduction

Background

> The [OpenAPI Specification](https://www.openapis.org/) (OAS) defines a standard, programming language-agnostic interface description for REST APIs, which allows both humans and computers to discover and understand the capabilities of a service without requiring access to source code, additional documentation, or inspection of network traffic. When properly defined via OpenAPI, a consumer can understand and interact with the remote service with a minimal amount of implementation logic. Similar to what interface descriptions have done for lower-level programming, the OpenAPI Specification removes guesswork in calling a service.

Oasis is built on `Plug` and uses an OpenAPI specification to generate a server router and the corresponding HTTP request handlers. Because OAS relies on [JSON Schema](https://json-schema.org/) for data definitions, Oasis focuses on request parameter type conversion and validation.

- Keep the OpenAPI specification document (YAML or JSON) as the primary source of truth
- Generate maintainable router and HTTP request handler code from that document
- Avoid manually rewriting OpenAPI definitions in Elixir in common workflows
- Simplify REST API development by converting and validating request parameters
- Improve API communication and documentation through a shared specification

## Installation

Add `oasis` as a dependency to your mix.exs

```elixir
def deps do
  [
    {:oasis, "~> 0.6"}
  ]
end
```

## Implemented OAS Features

Oasis does not cover the full OpenAPI specification. The current implementation includes:

* [Components Object](https://github.com/OAI/OpenAPI-Specification/blob/master/versions/3.1.0.md#componentsObject)
* [Paths Object](https://github.com/OAI/OpenAPI-Specification/blob/master/versions/3.1.0.md#pathsObject)
* [Path Item Object](https://github.com/OAI/OpenAPI-Specification/blob/master/versions/3.1.0.md#pathItemObject)
* [Operation Object](https://github.com/OAI/OpenAPI-Specification/blob/master/versions/3.1.0.md#operationObject)
* [Parameter Object](https://github.com/OAI/OpenAPI-Specification/blob/master/versions/3.1.0.md#parameterObject)
* [Request Body Object](https://github.com/OAI/OpenAPI-Specification/blob/master/versions/3.1.0.md#requestBodyObject)
* [Media Type Object](https://github.com/OAI/OpenAPI-Specification/blob/master/versions/3.1.0.md#mediaTypeObject)
* [Header Object](https://github.com/OAI/OpenAPI-Specification/blob/master/versions/3.1.0.md#headerObject)
* [Reference Object](https://github.com/OAI/OpenAPI-Specification/blob/master/versions/3.1.0.md#referenceObject)
* [Schema Object](https://github.com/OAI/OpenAPI-Specification/blob/master/versions/3.1.0.md#schemaObject)
* [Security Scheme Object](https://github.com/OAI/OpenAPI-Specification/blob/master/versions/3.1.0.md#securitySchemeObject)
  * Bearer Authentication, please see `Oasis.Plug.BearerAuth` for details.
  * HMAC Authentication, please see `Oasis.Plug.HMACAuth` for details.

We also have some OpenAPI Specification Extensions defined for use, please see [our Specification Extensions Guide](https://hexdocs.pm/oasis/specification_ext.html).

For current JSON Schema validation behavior and Draft `2020-12` notes, please also see [the JSON Schema Draft 2020-12 Notes guide](https://hexdocs.pm/oasis/json_schema_draft_2020_12.html).

## How to use

### Prepare a YAML or JSON specification

First, write your API document according to the OpenAPI Specification (see [Reference](#reference) below). Oasis is built around OAS [3.1.0](http://spec.openapis.org/oas/v3.1.0), and many common `3.0.*` use cases are also covered.

Here is a minimal YAML example saved as `petstore-mini.yaml`.

```yaml
openapi: "3.1.0"
info:
  title: Petstore Mini
paths:
  /pets:
    get:
      parameters:
        - name: tags
          in: query
          required: false
          schema:
            type: array
            items:
              type: string
        - name: limit
          in: query
          required: false
          schema:
            type: integer
            format: int32
      responses:
        '200':
          content:
            application/json:
              schema:
                type: array
                items:
                  $ref: '#/components/schemas/Pet'
    post:
      operationId: addPet
      requestBody:
        required: true
        content:
          application/json:
            schema:
              $ref: '#/components/schemas/NewPet'
      responses:
        '200':
          content:
            application/json:
              schema:
                $ref: '#/components/schemas/Pet'

  /pets/{id}:
    get:
      operationId: find pet by id
      parameters:
        - name: id
          in: path
          required: true
          schema:
            type: integer
            format: int64
      responses:
        '200':
          content:
            application/json:
              schema:
                $ref: '#/components/schemas/Pet'
components:
  schemas:
    Pet:
      allOf:
        - $ref: '#/components/schemas/NewPet'
        - type: object
          required:
          - id
          properties:
            id:
              type: integer
              format: int64

    NewPet:
      type: object
      required:
        - name
      properties:
        name:
          type: string
        tag:
          type: string
```

### Run the mix task

Run the following mix task to generate the corresponding files:

```
mix oas.gen.plug --file path/to/petstore-mini.yaml
```

You will see output like this:

```
Generates Router and Plug modules from OAS
* creating lib/oasis/gen/router.ex
* creating lib/oasis/gen/pre_find_pet_by_id.ex
* creating lib/oasis/gen/find_pet_by_id.ex
* creating lib/oasis/gen/pre_add_pet.ex
* creating lib/oasis/gen/add_pet.ex
* creating lib/oasis/gen/pre_get_pets.ex
* creating lib/oasis/gen/get_pets.ex
```

The generated `pre_*` modules compile nested JSON Schemas at module compile time with `JSONSchex.Schema.compile!/2`, so request validation works with compiled `JSONSchex.Types.Schema` values at runtime. In concise handwritten examples and tests, Oasis may also use `~X` when it is the clearest static schema form.

Generated routers and helpers use `Oasis.JSON` as the JSON encoder/decoder module. `Oasis.JSON` is the stable Oasis-owned wrapper for JSON operations and delegates to JSON in Elixir v1.18+ or Jason for earlier versions

The `oas.gen.plug` mix task accepts these arguments:

* `--file` — required. The full path to the specification file in YAML or JSON format.
* `--router` — optional. The generated router module alias. The default is `Router`, which produces `Oasis.Gen.Router` by default. For example, if you pass `--router Hello.MyRouter` and do not define another namespace, the final router module becomes `Oasis.Gen.Hello.MyRouter` in `lib/oasis/gen/hello/my_router.ex`.
* `--name-space` — optional. The namespace for all generated modules. The default is `Oasis.Gen`. This argument always overrides any `"x-oasis-name-space"` fields defined in the specification file.

### Special instructions

#### Name the Plug handlers

In OAS, the `operationId` field of the [Operation Object](https://github.com/OAI/OpenAPI-Specification/blob/master/versions/3.1.0.md#operationObject) is optional, but if it exists it should be unique across all operations in the API.

- When you use this field, Oasis uses it to construct the generated module alias and `.ex` file name. For example, the earlier `find_pet_by_id.ex` file produces the `Oasis.Gen.FindPetById` module.
- When you do not use this field, Oasis combines the HTTP verb with the URL to generate the module alias and file name. For example, `get_pets.ex` produces the `Oasis.Gen.GetPets` module.

#### Generated code location

Generated code is always written under the `lib` directory of your application root, because it is intended to be compiled and used as part of your application at runtime.

#### Custom namespace for generated modules

By default, generated modules use the `Oasis.Gen` namespace and are written under `lib/oasis/gen`. You can customize that in these ways:

1. As a top-level override when running `mix oas.gen.plug`, pass the `--name-space` argument. This always overrides any namespace defined in the specification file via `"x-oasis-name-space"`. For example:

  ```
  mix oas.gen.plug --file path/to/petstore-mini.yaml --name-space My.Petstore
  Generates Router and Plug modules from OAS
  * creating lib/my/petstore/router.ex
  * creating lib/my/petstore/pre_find_pet_by_id.ex
  * creating lib/my/petstore/find_pet_by_id.ex
  * creating lib/my/petstore/pre_add_pet.ex
  * creating lib/my/petstore/add_pet.ex
  * creating lib/my/petstore/pre_get_pets.ex
  * creating lib/my/petstore/get_pets.ex
  ```

  The generated folder path is now `lib/my/petstore`, and the module name changes from `Oasis.Gen.GetPets` to `My.Petstore.GetPets`.

2. Use `"x-oasis-name-space"` in the OAS [Operation Object](https://github.com/OAI/OpenAPI-Specification/blob/master/versions/3.1.0.md#operationObject). For example, add `x-oasis-name-space: Common.Api` like this:

  ```yaml
    paths:
      /pets:
        get:
          x-oasis-name-space: Common.Api
          parameters:
            - name: tags
              ...
        post:
          ...
      /pets/{id}:
        ...
  ```

  Run again without a `--name-space` argument.

  ```
  mix oas.gen.plug --file path/to/petstore-mini.yaml
  Generates Router and Plug modules from OAS
  * creating lib/oasis/gen/router.ex
  * creating lib/oasis/gen/pre_find_pet_by_id.ex
  * creating lib/oasis/gen/find_pet_by_id.ex
  * creating lib/oasis/gen/pre_add_pet.ex
  * creating lib/oasis/gen/add_pet.ex
  * creating lib/common/api/pre_get_pets.ex
  * creating lib/common/api/get_pets.ex
  ```

  `pre_get_pets.ex` and `get_pets.ex` are moved into the expected path, and their module names become `Common.Api.GetPets` and `Common.Api.PreGetPets`. Other operations do not define `"x-oasis-name-space"`, so they still use the default `Oasis.Gen` namespace.

3. Use `"x-oasis-name-space"` in the OAS [Paths Object](https://github.com/OAI/OpenAPI-Specification/blob/master/versions/3.1.0.md#pathsObject). This works as a global setting and keeps the configuration inside the versioned document itself. For example, add `x-oasis-name-space: Common.Api` like this:

  ```yaml
    paths:
      x-oasis-name-space: Common.Api
      /pets:
        get:
          parameters:
            - name: tags
              ...
        post:
          ...
      /pets/{id}:
        ...
  ```

  Run again without a `--name-space` argument.

  ```
  mix oas.gen.plug --file path/to/petstore-mini.yaml
  Generates Router and Plug modules from OAS
  * creating lib/common/api/router.ex
  * creating lib/common/api/pre_find_pet_by_id.ex
  * creating lib/common/api/find_pet_by_id.ex
  * creating lib/common/api/pre_add_pet.ex
  * creating lib/common/api/add_pet.ex
  * creating lib/common/api/pre_get_pets.ex
  * creating lib/common/api/get_pets.ex
  ```

  All generated files are moved into the expected path, and all module names start with `Common.Api`.

Summary of generated module namespace precedence:

1. The optional `--name-space` argument to `mix oas.gen.plug` has the highest priority.
2. You can also define the `"x-oasis-name-space"` extension in the specification document to keep this configuration in the document itself. See [the guide](https://hexdocs.pm/oasis/specification_ext.html#module-name-space) for details.

#### Paired HTTP request handler files

Generated HTTP request handler files come in pairs: `pre_operation.ex` and `operation.ex`.

- The **`pre_`** file converts and validates request parameters. Its contents may change when the OpenAPI document changes or when Oasis changes in future releases, so you should **not** put business logic there.
- The matching `operation.ex` file is created only the first time, as long as it does not already exist. It is the normal `Plug` module that runs after the generated preprocessing pipeline, and it is the place where you should add your business logic.

```
mix oas.gen.plug --file path/to/petstore-mini.yaml
Generates Router and Plug modules from OAS
* creating lib/oasis/gen/router.ex
* creating lib/oasis/gen/pre_find_pet_by_id.ex
* creating lib/oasis/gen/find_pet_by_id.ex
* creating lib/oasis/gen/pre_add_pet.ex
* creating lib/oasis/gen/add_pet.ex
* creating lib/oasis/gen/pre_get_pets.ex
* creating lib/oasis/gen/get_pets.ex
```

#### Integration

After generating the files, assume the router module is `Oasis.Gen.Router`. You can use it in a `Plug` adapter like this:

```elixir
Plug.Adapters.Cowboy.child_spec(
  scheme: :http,
  plug: Oasis.Gen.Router,
  options: [
    port: port
  ]
)
```

Or you can plug this router into an existing router module like this:

```elixir
defmodule MyExistingRouter do
  use Plug.Router

  plug(Oasis.Gen.Router)

  plug(:match)
  plug(:dispatch)

  # other
end
```

Make sure `plug(Oasis.Gen.Router)` appears before `plug(:match)`.

## TODO

1. XML Object support is not implemented yet.
2. Continue improving the documentation.
3. There may still be unimplemented details or bugs relative to the OAS. Please open an issue or PR to help track them.

## Reference

1. The official OpenAPI Specification v3: [Github](https://github.com/OAI/OpenAPI-Specification/blob/master/versions/3.1.0.md) | [Official Web Site](http://spec.openapis.org/oas/v3.1.0)
2. [JSON Schema Reference](https://json-schema.org/understanding-json-schema/reference/)
