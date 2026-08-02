# Handle Errors

When we run the `mix oas.gen.plug` mix task to generate the corresponding modules, we will see output similar to the following (this is only an example):

```
...
* creating lib/oasis/gen/pre_list_pets.ex
* creating lib/oasis/gen/list_pets.ex
...
```

The `pre_list_pets.ex` and `list_pets.ex` files come in pairs. The `pre_`-prefixed module is in charge of parsing and validating the request. The other module runs after the `pre_` pipeline and is in charge of the detailed business logic. The plain (non-`pre_`) module also provides a `handle_errors/2` callback to process errors:

```elixir
def handle_errors(conn, %{kind: _kind, reason: reason, stack: _stack}) do
  message = Map.get(reason, :message) || "Something went wrong"
  send_resp(conn, conn.status, message)
end
```

The `reason` is an `Oasis.BadRequestError` exception whose `:error` field is one of:

* `Oasis.BadRequestError.Invalid`
* `Oasis.BadRequestError.Required`
* `Oasis.BadRequestError.JSONSchemaValidationFailed`
* `Oasis.BadRequestError.InvalidToken`

We can pattern-match to process specific error cases:

```elixir
def handle_errors(conn, %{
      kind: _kind,
      reason: %Oasis.BadRequestError{
        error: %Oasis.BadRequestError.JSONSchemaValidationFailed{} = error,
        use_in: use_in,
        param_name: param_name
      } = reason,
      stack: _stack
    }) do
  # `error.error` is the underlying %JSONSchex.Types.Error{} with `rule`, `path`,
  # `context`, etc. You can inspect it to render rich validation feedback.
  #
  # `error.path` is a URI-fragment JSON Pointer into the request payload (e.g.
  # "#/name"). It applies RFC 6901 escaping and URI percent-encoding.
  #
  # `use_in` ("query", "header", "cookie", "path", or "body") and `param_name`
  # together identify which request input failed validation. Combined with
  # `conn.method`, `conn.request_path`, etc. they give you full runtime context.
  send_resp(conn, conn.status, reason.message)
end

def handle_errors(conn, %{
      kind: _kind,
      reason: %Oasis.BadRequestError{error: %Oasis.BadRequestError.InvalidToken{}} = reason,
      stack: _stack
    }) do
  send_resp(conn, conn.status, reason.message)
end

def handle_errors(conn, %{kind: _kind, reason: reason, stack: _stack}) do
  send_resp(conn, conn.status, Map.get(reason, :message) || "Something went wrong")
end
```

## OpenAPI source locations

Generated runtime modules do **not** embed deep links back into the OpenAPI
document, so `JSONSchemaValidationFailed` stays small and focused on the
runtime payload error.

If you need to map a failure back to the OpenAPI document at generation time
(for tooling, documentation, or diagnostics), use the public `:source_meta`
field on `%Mix.Oasis.Router{}`. It carries the OpenAPI source location for
every parameter and request-body schema Oasis extracted, using the user's
original OpenAPI shape (URLs like `/users/{id}`, not Oasis's post-processed
`/users/:id`). Each entry is identified structurally:

* parameters by `(path, http_verb, parameter_location, parameter_name)`
* request bodies by `(path, http_verb, content_type)`

See `Mix.Oasis.Router` for the full shape.
