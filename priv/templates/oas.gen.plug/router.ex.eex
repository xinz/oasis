defmodule <%= inspect context.module_name %> do
  # NOTICE: This module is generated when run `mix oas.gen.plug` task command with the OpenAPI Specification file.
  use Oasis.Router
  <%= if Enum.any?(context.routers, & &1.schema_compile_required? and &1.path_schema != nil) do %>require JSONSchex.Schema<% end %>

  plug(:match)
  plug(:dispatch)
  <%= for router <- context.routers do %>
  <%= router.http_verb %>(
    <%= inspect router.url %>,
    <%= if router.path_schema != nil do %>private: %{
      path_schema: <%= Mix.Oasis.render_embedded_schemas(router.path_schema) %>
    },
    <% end %>to: <%= inspect router.pre_plug_module %>
  )
  <% end %>

  match _ do
    conn
  end
end
