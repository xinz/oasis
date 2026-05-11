# Specification Extensions

Oasis provides the following [specification extensions](https://github.com/OAI/OpenAPI-Specification/blob/master/versions/3.1.0.md#specificationExtensions) to support additional use cases in an OpenAPI `3.1.0` YAML or JSON specification file.

## Module Name Space

`"x-oasis-name-space"`, optional, use this field to define the generated Elixir module's name space in the following objects, defaults to `Oasis.Gen`:
  * [Paths Object](https://github.com/OAI/OpenAPI-Specification/blob/master/versions/3.1.0.md#pathsObject)
  * [Operation Object](https://github.com/OAI/OpenAPI-Specification/blob/master/versions/3.1.0.md#operationObject)
  * [Security Scheme Object](https://github.com/OAI/OpenAPI-Specification/blob/master/versions/3.1.0.md#securitySchemeObject)

### Example

#### In Paths Object

Here, defining this field in the [Paths Object](https://github.com/OAI/OpenAPI-Specification/blob/master/versions/3.1.0.md#pathsObject)
sets a global namespace for all generated modules when there are no more specific overrides. In the example below,
all generated modules use `Hello.Petstore` as the module prefix.

```YAML
paths:
  /pets:
    get:
      ...
  /pets/{id}:
    get:
      ...
    delete:
      ...
  x-oasis-name-space: Hello.Petstore
```

#### In Operation Object

Here, defining this field in the [Operation Object](https://github.com/OAI/OpenAPI-Specification/blob/master/versions/3.1.0.md#operationObject)
affects only the generated modules related to that operation when there are no more specific overrides. In the example below,
the modules generated for handling `GET /pets` use `Petstore.Api`, while other generated modules still use the default `Oasis.Gen` namespace.

```YAML
paths:
  /pets:
    get:
      x-oasis-name-space: Petstore.Api
      operationId: list pets
      ...
  /pets/{id}:
    get:
      ...
    delete:
      ...
```

#### In Security Scheme Object

Here, defining this field in the [Security Scheme Object](https://github.com/OAI/OpenAPI-Specification/blob/master/versions/3.1.0.md#securitySchemeObject)
affects only the generated bearer token module when there are no more specific overrides. In the example below,
`helloBearerAuth` becomes `Petstore.MyToken.HelloBearerAuth`.

```YAML
paths:
  /pets:
    get:
      security:
        - helloBearerAuth: []

components:
  securitySchemes:
    helloBearerAuth: # arbitrary name for the security scheme
      scheme: bearer
      type: http
      x-oasis-name-space: Petstore.MyToken
```

### Summary

`"x-oasis-name-space"` can be used in all of the scenarios above. A value defined in the Security Scheme Object overrides the value defined in the Operation Object for the generated bearer token module, and a value defined in the Operation Object overrides the value defined in the Paths Object for the corresponding operation-related modules.

You can also set a global namespace when running `mix oas.gen.plug` with the `--name-space` argument. It applies to all generated modules and always overrides values defined in the specification file.

Follow normal Elixir module naming conventions. Each dot (`.`) in a module name becomes a lowercase directory component in the generated path. Oasis does not strictly validate this field, so it is best to stick to conventional module naming.

## Router Module Alias

`"x-oasis-router"`, optional, use this field to define the generated Elixir router module's alias in [Paths Object](https://github.com/OAI/OpenAPI-Specification/blob/master/versions/3.1.0.md#pathsObject), defaults to `Router`.

### Example

When you run `mix oas.gen.plug` with an OpenAPI specification, Oasis generates a router file and matching operation handler module pairs.
The router file wires the defined HTTP routes to each handler. You can customize the router module name with `"x-oasis-router"` and `"x-oasis-name-space"` in the specification file.
Without another namespace override, the following example produces the router module `Oasis.Gen.HelloRouter`.

```YAML
paths:
  /pets:
    ..
  /pets/{id}:
    ..
  x-oasis-router: HelloRouter
```

### Summary

You can also set the router name when running `mix oas.gen.plug` with the `--router` argument. It applies only to the router module and always overrides the value defined in the specification file.

Follow normal Elixir module naming conventions. Each dot (`.`) in a module name becomes a lowercase directory component in the generated path. Oasis does not strictly validate this field, so it is best to stick to conventional module naming.

## Save Data from Bearer Token

`"x-oasis-key-to-assigns"`, optional. After token verification, the original token data is stored in the provided field (as an atom) on `conn.assigns` for later access. If this field is not defined, Oasis does not store the verified original data. See `Oasis.Plug.BearerAuth` for details.

### Example

Once the input token is verified, you can access the original token data (decrypted from the token) through `conn.assigns.user_id` later in the Plug pipeline.

```YAML
openapi: 3.1.0

components:
  securitySchemes:
    bearerAuth: # arbitrary name for the security scheme
      type: http
      scheme: bearer
      bearerFormat: JWT
      x-oasis-key-to-assigns: user_id

paths:
  /something:
    get:
      security:
        - bearerAuth: []
```

## Signed Headers for HMAC Authentication

`"x-oasis-signed-headers"`, required when using HMAC authentication in a `security` scheme object. This field lists which HTTP headers are included in the signature. See the [HMAC-based authentication](hmac_based_authentication.html) guide for details.
