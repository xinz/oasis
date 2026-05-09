plug(
  Oasis.Plug.RequestValidator,
  <%= [:query_schema, :cookie_schema, :header_schema, :body_schema] |> Enum.reduce([], fn(k, acc) ->
    value = Map.get(router, k)
    if value != nil do
      ["#{k}: #{Mix.Oasis.render_embedded_schemas(value)}" | acc]
    else
      acc
    end
  end) |> Enum.join(",\n") %>
)
