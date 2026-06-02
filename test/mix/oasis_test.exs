defmodule Mix.OasisTest do
  use ExUnit.Case, async: true

  @jsonschex_compile_options [format_assertion: true, content_assertion: false]

  defp valid_schema?(%JSONSchex.Types.Schema{} = schema, data) do
    JSONSchex.validate(schema, data) == :ok
  end

  defp valid_schema?(schema, data) when is_map(schema) or is_boolean(schema) do
    {:ok, compiled} = JSONSchex.compile(schema, @jsonschex_compile_options)
    JSONSchex.validate(compiled, data) == :ok
  end

  defp pre_plug_router(files, operation_id) do
    Enum.find_value(files, fn
      {_format, _file_path, "pre_plug.ex", _module, router} ->
        if router.operation_id == operation_id, do: router

      _other ->
        nil
    end)
  end

  test "name space" do
    assert Mix.Oasis.name_space(nil) == {"Oasis.Gen", "lib/oasis/gen"}
    assert Mix.Oasis.name_space("My.App") == {"My.App", "lib/my/app"}
    assert Mix.Oasis.name_space("My...App") == {"My.App", "lib/my/app"}
    assert Mix.Oasis.name_space("my123") == {"My123", "lib/my123"}
    assert Mix.Oasis.name_space("My.APP") == {"My.App", "lib/my/app"}
  end

  test "module alias" do
    name = ".."

    assert_raise RuntimeError, ~r/input invalid module alias: `#{name}`/, fn ->
      Mix.Oasis.module_alias(name)
    end

    name = "My.App.ModuleName"
    assert Mix.Oasis.module_alias(name) == {"My.App.ModuleName", "my/app/module_name.ex"}
    name = "MyAppModuleName"
    assert Mix.Oasis.module_alias(name) == {"MyAppModuleName", "my_app_module_name.ex"}
    name = "MyAppModulename"
    assert Mix.Oasis.module_alias(name) == {"MyAppModulename", "my_app_modulename.ex"}
    name = "my123"
    assert Mix.Oasis.module_alias(name) == {"My123", "my123.ex"}
    name = "My.APP"
    assert Mix.Oasis.module_alias(name) == {"My.App", "my/app.ex"}
    name = "My...App.ModuleName"
    assert Mix.Oasis.module_alias(name) == {"My.App.ModuleName", "my/app/module_name.ex"}
    name = "my/app"
    assert Mix.Oasis.module_alias(name) == {"My/app", "my/app.ex"}
    router = %{operation_id: "GetUserInfo"}
    assert Mix.Oasis.module_alias(router) == {"GetUserInfo", "get_user_info.ex"}
    router = %{operation_id: "My.GetUserInfo"}
    assert Mix.Oasis.module_alias(router) == {"My.GetUserInfo", "my/get_user_info.ex"}
    router = %{http_verb: "get", url: "/user/:id"}
    assert Mix.Oasis.module_alias(router) == {"GetUserId", "get_user_id.ex"}
    router = %{operation_id: "SayHi", http_verb: :post, url: "/hi"}
    assert Mix.Oasis.module_alias(router) == {"SayHi", "say_hi.ex"}
  end

  test "Mix.Oasis.new/2 bundles external JSON Schema refs with JSONSchex" do
    file_path = Path.expand("tasks/file/jsonschex_boundary/external_schema.yaml", __DIR__)
    %Oasis.Spec.Document{} = document = Oasis.Spec.read(file_path)

    files = Mix.Oasis.new(document, [])
    router = pre_plug_router(files, "createUser")
    schema = get_in(router.body_schema, ["content", "application/json", "schema"])
    source = get_in(router.source_meta, [:body_schema, "application/json"])

    assert Map.has_key?(schema, "$defs")
    refute Map.has_key?(schema, "paths")
    refute Map.has_key?(schema, "openapi")
    assert source.path == "/users"
    assert source.http_verb == "post"
    assert source.content_type == "application/json"

    assert valid_schema?(schema, %{"name" => "Ada", "age" => 42})
    assert valid_schema?(schema, %{"age" => 42}) == false
  end

  test "Mix.Oasis.new/2 bundles recursive component schemas with JSONSchex" do
    file_path = Path.expand("tasks/file/jsonschex_boundary/recursive_schema.yaml", __DIR__)
    %Oasis.Spec.Document{} = document = Oasis.Spec.read(file_path)

    files = Mix.Oasis.new(document, [])
    router = pre_plug_router(files, "createNode")
    schema = get_in(router.body_schema, ["content", "application/json", "schema"])

    assert Map.has_key?(schema, "components")
    refute Map.has_key?(schema, "paths")
    refute Map.has_key?(schema, "openapi")

    # Depth-1 (sanity, original coverage).
    assert valid_schema?(schema, %{"name" => "root", "next" => %{"name" => "child"}})
    assert valid_schema?(schema, %{"next" => %{"name" => "child"}}) == false

    # Depth-3+ traversal. If the recursive `$ref` were silently inlined (rather
    # than compiled as a true cyclic graph), validation would either succeed
    # spuriously past the inlined depth or crash. This asserts the recursion
    # holds across multiple levels.
    deep_valid = %{
      "name" => "l0",
      "next" => %{
        "name" => "l1",
        "next" => %{
          "name" => "l2",
          "next" => %{"name" => "l3"}
        }
      }
    }

    assert valid_schema?(schema, deep_valid)

    # Negative: at depth-3 the innermost `Node` is missing its required `name`.
    # A correctly compiled cyclic schema must still apply the `required: [name]`
    # constraint to that level.
    deep_invalid = %{
      "name" => "l0",
      "next" => %{
        "name" => "l1",
        "next" => %{
          "name" => "l2",
          "next" => %{"next" => %{"name" => "l4"}}
        }
      }
    }

    refute valid_schema?(schema, deep_invalid)
  end

  test "Mix.Oasis.new/2 resolves external OpenAPI refs and keeps schema validation working" do
    file_path = Path.expand("tasks/file/jsonschex_boundary/external_openapi_ref.yaml", __DIR__)
    %Oasis.Spec.Document{} = document = Oasis.Spec.read(file_path)

    files = Mix.Oasis.new(document, [])
    router = pre_plug_router(files, "getUser")

    %{"id" => %{"schema" => schema, "required" => true} = _parameter} = router.path_schema

    source = get_in(router.source_meta, [:path_schema, "id"])

    assert source.path == "/users/{id}"
    assert source.http_verb == "get"
    assert source.parameter_location == "path"
    assert source.parameter_name == "id"

    assert valid_schema?(schema, 123)
    assert valid_schema?(schema, "123") == false
  end

  test "Mix.Oasis.new/2 source_meta locates parameters against the raw OpenAPI document" do
    file_path = Path.expand("tasks/file/jsonschex_boundary/external_openapi_ref.yaml", __DIR__)
    %Oasis.Spec.Document{} = document = Oasis.Spec.read(file_path)

    {:ok, raw_document} = YamlElixir.read_from_file(file_path)

    router =
      document
      |> Mix.Oasis.new([])
      |> pre_plug_router("getUser")

    source = get_in(router.source_meta, [:path_schema, "id"])

    operation = get_in(raw_document, ["paths", source.path, source.http_verb])
    assert is_map(operation)

    assert [%{"$ref" => "./common.yaml#/components/parameters/UserId"}] =
             Map.fetch!(operation, "parameters")
  end

  test "generated pre_plug schema literals contain no x-oasis-source key" do
    file_path = Path.expand("tasks/file/jsonschex_boundary/external_schema.yaml", __DIR__)
    document = Oasis.Spec.read(file_path)

    router =
      document
      |> Mix.Oasis.new([])
      |> pre_plug_router("createUser")

    rendered = Mix.Oasis.render_embedded_schemas(router.body_schema)

    refute rendered =~ "x-oasis-source"
  end

  test "prepare_json_schema!/2 accepts a custom loader for library callers" do
    schema = %{"$ref" => "./schemas/user.yaml"}

    root_spec = %{
      "paths" => %{
        "/users" => %{
          "post" => %{
            "requestBody" => %{
              "content" => %{"application/json" => %{"schema" => schema}}
            }
          }
        }
      }
    }

    loader = fn "/tmp/api/schemas/user.yaml" = base_uri ->
      {:ok,
       %{
         document: %{
           "type" => "object",
           "required" => ["name"],
           "properties" => %{"name" => %{"type" => "string"}}
         },
         base_uri: base_uri
       }}
    end

    prepared =
      Mix.Oasis.prepare_json_schema!(schema,
        root_spec: root_spec,
        entry_pointer: "#/paths/~1users/post/requestBody/content/application~1json/schema",
        base_uri: "/tmp/api/openapi.yaml",
        loader: loader
      )

    assert valid_schema?(prepared, %{"name" => "Ada"})
    assert valid_schema?(prepared, %{}) == false
  end

  test "prepare_json_schema!/2 includes entry context in JSONSchex diagnostics" do
    schema = %{"type" => 123}

    assert_raise ArgumentError,
                 ~r(entry=#/paths/~1users/post/requestBody/content/application~1json/schema),
                 fn ->
                   Mix.Oasis.prepare_json_schema!(schema,
                     entry_pointer: "#/paths/~1users/post/requestBody/content/application~1json/schema",
                     base_uri: "/tmp/api/openapi.yaml"
                   )
                 end
  end

  test "prepare_json_schema!/2 accepts `loader: nil` for self-contained schemas" do
    # `loader: nil` explicitly disables the default external loader. For
    # self-contained schemas (no external $refs) this must remain a no-op.
    schema = %{
      "type" => "object",
      "required" => ["name"],
      "properties" => %{"name" => %{"type" => "string"}}
    }

    root_spec = %{
      "paths" => %{
        "/users" => %{
          "post" => %{
            "requestBody" => %{
              "content" => %{"application/json" => %{"schema" => schema}}
            }
          }
        }
      }
    }

    prepared =
      Mix.Oasis.prepare_json_schema!(schema,
        root_spec: root_spec,
        entry_pointer: "#/paths/~1users/post/requestBody/content/application~1json/schema",
        loader: nil
      )

    assert valid_schema?(prepared, %{"name" => "Ada"})
    assert valid_schema?(prepared, %{}) == false
  end

  test "prepare_json_schema!/2 with `loader: nil` surfaces external ref errors" do
    # `loader: nil` is the documented opt-out from external loading. When the
    # schema actually contains an external $ref, bundling must fail rather than
    # silently fall back to a default loader.
    schema = %{"$ref" => "./schemas/user.yaml"}

    root_spec = %{
      "paths" => %{
        "/users" => %{
          "post" => %{
            "requestBody" => %{
              "content" => %{"application/json" => %{"schema" => schema}}
            }
          }
        }
      }
    }

    assert_raise ArgumentError,
                 ~r/Failed to bundle JSON Schema fragment.*entry=#\/paths\/~1users\/post\/requestBody\/content\/application~1json\/schema/s,
                 fn ->
                   Mix.Oasis.prepare_json_schema!(schema,
                     root_spec: root_spec,
                     entry_pointer: "#/paths/~1users/post/requestBody/content/application~1json/schema",
                     base_uri: "/tmp/api/openapi.yaml",
                     loader: nil
                   )
                 end
  end

  test "Mix.Oasis.new/2 honors a custom :loader for external schema refs" do
    file_path = Path.expand("tasks/file/jsonschex_boundary/external_schema.yaml", __DIR__)
    %Oasis.Spec.Document{} = document = Oasis.Spec.read(file_path)

    parent = self()
    ref = make_ref()

    loader = fn path ->
      send(parent, {:custom_loader_invoked, ref, path})
      Oasis.Spec.Document.load_external(path)
    end

    files = Mix.Oasis.new(document, loader: loader)
    router = pre_plug_router(files, "createUser")
    schema = get_in(router.body_schema, ["content", "application/json", "schema"])

    assert_received {:custom_loader_invoked, ^ref, _path}

    assert valid_schema?(schema, %{"name" => "Ada", "age" => 42})
    refute valid_schema?(schema, %{"age" => 42})
  end

  test "prepare_json_schema!/2 accepts :entry_ref to bundle a fragment" do
    root_spec = %{
      "components" => %{
        "schemas" => %{
          "User" => %{
            "type" => "object",
            "required" => ["name"],
            "properties" => %{
              "name" => %{"type" => "string"},
              "age" => %{"type" => "integer"}
            }
          }
        }
      }
    }

    schema = get_in(root_spec, ["components", "schemas", "User"])

    prepared =
      Mix.Oasis.prepare_json_schema!(schema,
        root_spec: root_spec,
        entry_ref: "#/components/schemas/User"
      )

    assert is_map(prepared)
    assert valid_schema?(prepared, %{"name" => "Ada", "age" => 42})
    refute valid_schema?(prepared, %{"age" => 42})
  end

  test "prepare_json_schema!/2 compaction retains components and drops top-level OpenAPI keys" do
    {:ok, root_spec} =
      YamlElixir.read_from_string("""
      openapi: 3.1.0
      info:
        title: Compaction Policy
        version: 1.0.0
      servers:
        - url: https://example.com
      tags:
        - name: users
      externalDocs:
        url: https://example.com/docs
      webhooks: {}
      components:
        schemas:
          Unused:
            type: string
      paths:
        /users:
          post:
            operationId: createUser
            requestBody:
              required: true
              content:
                application/json:
                  schema:
                    type: object
                    required:
                      - name
                    properties:
                      name:
                        type: string
      """)

    schema = get_in(root_spec, ["paths", "/users", "post", "requestBody", "content", "application/json", "schema"])

    prepared =
      Mix.Oasis.prepare_json_schema!(schema,
        root_spec: root_spec,
        entry_pointer: "#/paths/~1users/post/requestBody/content/application~1json/schema"
      )

    # (a) `components` is always retained, even when no surviving Schema Object
    # references `#/components/schemas/...`.
    assert Map.has_key?(prepared, "components")

    # (b) Top-level OpenAPI document keys are dropped from the bundled schema.
    for dropped <- ["info", "servers", "tags", "webhooks", "externalDocs", "paths", "openapi"] do
      refute Map.has_key?(prepared, dropped),
             "expected bundled schema to drop top-level OpenAPI key #{inspect(dropped)}, got keys: #{inspect(Map.keys(prepared))}"
    end
  end

  test "Mix.Oasis.new/2 invalid spec" do
    spec = %{
      "components" => %{
        "schemas" => %{
          "User" => %{
            "properties" => %{
              "id" => %{"format" => "int64", "type" => "integer"},
              "name" => %{"type" => "string"}
            },
            "required" => ["id", "name"],
            "type" => "object"
          }
        }
      },
      "info" => %{"title" => "Test API", "version" => "1.0.0"},
      "openapi" => "3.1.0"
    }

    assert_raise RuntimeError, ~r/could not find any paths defined/, fn ->
      Mix.Oasis.new(spec, [])
    end
  end

  test "Mix.Oasis.new/2 with x-oasis-name-space and x-oasis-router from Paths Object" do
    operation = %{
      "parameters" => %{
        "query" => [%{"name" => "id", "required" => true, "schema" => %{"type" => "integer"}}]
      }
    }

    paths_spec = %{
      "paths" => %{
        "/id" => %{"get" => operation},
        "x-oasis-name-space" => "GlobalNameSpaceFromPathsObject",
        "x-oasis-router" => "Hello.MyRouter"
      }
    }

    [router_file | plug_files] = Mix.Oasis.new(paths_spec, [])
    {_, file_path, _, router_module_name, _} = router_file
    assert file_path == "lib/global_name_space_from_paths_object/hello/my_router.ex"
    assert router_module_name == GlobalNameSpaceFromPathsObject.Hello.MyRouter
    [pre_plug_file, plug_file] = plug_files
    {_, file_path, _, router_module_name, _} = pre_plug_file
    assert file_path == "lib/global_name_space_from_paths_object/pre_get_id.ex"
    assert router_module_name == GlobalNameSpaceFromPathsObject.PreGetId
    {_, file_path, _, router_module_name, _} = plug_file
    assert file_path == "lib/global_name_space_from_paths_object/get_id.ex"
    assert router_module_name == GlobalNameSpaceFromPathsObject.GetId

    [router_file | _plug_files] =
      Mix.Oasis.new(paths_spec, name_space: "My", router: "V1.AppRouter")

    {_, file_path, _, router_module_name, _} = router_file
    assert file_path == "lib/my/v1/app_router.ex"
    assert router_module_name == My.V1.AppRouter
  end

  test "Mix.Oasis.new/2 with x-oasis-name-space from Operation Object" do
    operation = %{
      "parameters" => %{
        "query" => [%{"name" => "id", "required" => true, "schema" => %{"type" => "integer"}}]
      }
    }

    paths_spec = %{
      "paths" => %{
        "/id" => %{
          "get" => Map.put(operation, "x-oasis-name-space", "GetNameSpaceFromOperationObject"),
          "delete" =>
            Map.put(operation, "x-oasis-name-space", "DeleteNameSpaceFromOperationObject")
        }
      }
    }

    [router_file | plug_files] = Mix.Oasis.new(paths_spec, [])
    {_, file_path, _, router_module_name, _} = router_file
    assert file_path == "lib/oasis/gen/router.ex"
    assert router_module_name == Oasis.Gen.Router

    Enum.map(plug_files, fn
      {_, file_path, "pre_plug.ex", GetNameSpaceFromOperationObject.PreGetId, router} ->
        assert file_path == "lib/get_name_space_from_operation_object/pre_get_id.ex"
        assert router.plug_module == GetNameSpaceFromOperationObject.GetId

      {_, file_path, "plug.ex", GetNameSpaceFromOperationObject.GetId, router} ->
        assert file_path == "lib/get_name_space_from_operation_object/get_id.ex"
        assert router.plug_module == GetNameSpaceFromOperationObject.GetId

      {_, file_path, "pre_plug.ex", DeleteNameSpaceFromOperationObject.PreDeleteId, router} ->
        assert file_path == "lib/delete_name_space_from_operation_object/pre_delete_id.ex"
        assert router.plug_module == DeleteNameSpaceFromOperationObject.DeleteId

      {_, file_path, "plug.ex", DeleteNameSpaceFromOperationObject.DeleteId, router} ->
        assert file_path == "lib/delete_name_space_from_operation_object/delete_id.ex"
        assert router.plug_module == DeleteNameSpaceFromOperationObject.DeleteId
    end)

    paths_spec2 = put_in(paths_spec, ["paths", "x-oasis-name-space"], "Global")
    [router_file | plug_files] = Mix.Oasis.new(paths_spec2, [])
    {_, file_path, _, router_module_name, _} = router_file
    assert file_path == "lib/global/router.ex"
    assert router_module_name == Global.Router

    Enum.map(plug_files, fn
      {_, file_path, "pre_plug.ex", GetNameSpaceFromOperationObject.PreGetId, router} ->
        assert file_path == "lib/get_name_space_from_operation_object/pre_get_id.ex"
        assert router.plug_module == GetNameSpaceFromOperationObject.GetId

      {_, file_path, "plug.ex", GetNameSpaceFromOperationObject.GetId, router} ->
        assert file_path == "lib/get_name_space_from_operation_object/get_id.ex"
        assert router.plug_module == GetNameSpaceFromOperationObject.GetId

      {_, file_path, "pre_plug.ex", DeleteNameSpaceFromOperationObject.PreDeleteId, router} ->
        assert file_path == "lib/delete_name_space_from_operation_object/pre_delete_id.ex"
        assert router.plug_module == DeleteNameSpaceFromOperationObject.DeleteId

      {_, file_path, "plug.ex", DeleteNameSpaceFromOperationObject.DeleteId, router} ->
        assert file_path == "lib/delete_name_space_from_operation_object/delete_id.ex"
        assert router.plug_module == DeleteNameSpaceFromOperationObject.DeleteId
    end)

    [router_file | plug_files] = Mix.Oasis.new(paths_spec2, name_space: "From.Command")
    {_, file_path, _, router_module_name, _} = router_file
    assert file_path == "lib/from/command/router.ex"
    assert router_module_name == From.Command.Router

    Enum.map(plug_files, fn
      {_, file_path, "pre_plug.ex", From.Command.PreGetId, router} ->
        assert file_path == "lib/from/command/pre_get_id.ex"
        assert router.plug_module == From.Command.GetId

      {_, file_path, "plug.ex", From.Command.GetId, router} ->
        assert file_path == "lib/from/command/get_id.ex"
        assert router.plug_module == From.Command.GetId

      {_, file_path, "pre_plug.ex", From.Command.PreDeleteId, router} ->
        assert file_path == "lib/from/command/pre_delete_id.ex"
        assert router.plug_module == From.Command.DeleteId

      {_, file_path, "plug.ex", From.Command.DeleteId, router} ->
        assert file_path == "lib/from/command/delete_id.ex"
        assert router.plug_module == From.Command.DeleteId
    end)
  end

  test "Mix.Oasis.new/2 skip missing-schema request body" do
    delete = %{
      "requestBody" => %{
        "content" => %{
          "text/plain" => %{
            "examples" => %{"cat" => %{"summary" => "test summary", "value" => "white"}}
          }
        },
        "required" => true
      }
    }

    paths_spec = %{"paths" => %{"/del" => %{"delete" => delete}}}
    [_router | plug_files] = Mix.Oasis.new(paths_spec, [])

    Enum.map(plug_files, fn plug_file ->
      {_, _, _, _, binding} = plug_file
      assert binding.body_schema == nil
    end)
  end

  test "Mix.Oasis.new/2 skip missing-schema/-name in parameter" do
    operation = %{
      "parameters" => %{
        "query" => [
          %{"schema" => %{"type" => "integer"}, "required" => false},
          %{"name" => "username", "required" => true}
        ]
      }
    }

    paths_spec = %{"paths" => %{"/test" => %{"get" => operation}}}
    [router_file | _plug_files] = Mix.Oasis.new(paths_spec, [])
    {_, _, _, _, binding} = router_file
    Enum.map(binding.routers, fn router -> assert router.query_schema == nil end)
  end

  test "Mix.Oasis.new/2 with text/plain request body" do
    put = %{
      "requestBody" => %{
        "content" => %{
          "text/plain" => %{"schema" => %{"items" => %{"type" => "integer"}, "type" => "array"}}
        },
        "required" => true
      }
    }

    paths_spec = %{"paths" => %{"/new" => %{"put" => put}}}

    [router_file | plug_files] =
      Mix.Oasis.new(paths_spec, router: "my_router", name_space: "Hello")

    {_, file_path, "router.ex", router_module_name, _} = router_file
    assert file_path == "lib/hello/my_router.ex"
    assert router_module_name == Hello.MyRouter
    [pre_plug, _] = plug_files
    {_, pre_plug_file_path, "pre_plug.ex", pre_plug_module_name, binding} = pre_plug
    assert pre_plug_file_path == "lib/hello/pre_put_new.ex"
    assert pre_plug_module_name == Hello.PrePutNew
    body_schema = binding.body_schema
    assert Map.get(body_schema, "required") == true
    assert is_map(get_in(body_schema, ["content", "text/plain"]))
  end

  test "Mix.Oasis.new/2 with multipart request body" do
    post = %{
      "requestBody" => %{
        "content" => %{
          "multipart/form-data" => %{
            "schema" => %{"items" => %{"type" => "integer"}, "type" => "array"}
          },
          "multipart/mixed" => %{
            "schema" => %{
              "properties" => %{
                "id" => %{"type" => "string"},
                "addresses" => %{
                  "type" => "array",
                  "items" => %{
                    "type" => "array",
                    "items" => %{
                      "type" => "object",
                      "properties" => %{
                        "number" => %{"type" => "integer"},
                        "name" => %{"type" => "string"}
                      },
                      "required" => ["number", "name"]
                    }
                  }
                }
              },
              "required" => ["id", "addresses"],
              "type" => "object"
            }
          }
        }
      }
    }

    paths_spec = %{"paths" => %{"/submit" => %{"post" => post}}}
    [router_file | plug_files] = Mix.Oasis.new(paths_spec, [])
    {_, file_path, "router.ex", router_module_name, _} = router_file
    assert file_path == "lib/oasis/gen/router.ex"
    assert router_module_name == Oasis.Gen.Router
    [pre_plug, _] = plug_files
    {_, pre_plug_file_path, "pre_plug.ex", pre_plug_module_name, binding} = pre_plug
    assert pre_plug_file_path == "lib/oasis/gen/pre_post_submit.ex"
    assert pre_plug_module_name == Oasis.Gen.PrePostSubmit
    body_schema = binding.body_schema
    assert Map.get(body_schema, "required") == nil
    assert is_map(get_in(body_schema, ["content", "multipart/form-data"]))
    assert is_map(get_in(body_schema, ["content", "multipart/mixed"]))
    assert binding.plug_parsers =~ ~s/parsers: [:multipart]/
  end

  test "Mix.Oasis.new/2 with urlencoded and json request body" do
    post = %{
      "description" => "Creates a new pet in the store. Duplicates are allowed",
      "operationId" => "addPet",
      "parameters" => %{},
      "requestBody" => %{
        "content" => %{
          "application/json" => %{
            "schema" => %{
              "properties" => %{"name" => %{"type" => "string"}, "tag" => %{"type" => "string"}},
              "required" => ["name"],
              "type" => "object"
            }
          },
          "application/x-www-form-urlencoded" => %{
            "schema" => %{
              "properties" => %{
                "name" => %{"type" => "string"},
                "fav_number" => %{"type" => "integer", "minimum" => 1, "maximum" => 3}
              },
              "required" => ["name", "fav_number"],
              "type" => "object"
            }
          }
        },
        "description" => "Pet to add to the store",
        "required" => true
      }
    }

    get = %{
      "parameters" => %{
        "query" => [
          %{
            "in" => "query",
            "name" => "id",
            "required" => true,
            "schema" => %{"items" => %{"type" => "string"}, "type" => "array"}
          }
        ]
      }
    }

    paths_spec = %{"paths" => %{"/my_post" => %{"post" => post, "get" => get}}}
    files = Mix.Oasis.new(paths_spec, [])
    assert length(files) == 5
    [router_file | plug_files] = files

    {:eex, file_path, _router_template_file_name, router_module_name,
     %{routers: binding_pre_routers}} = router_file

    assert file_path == "lib/oasis/gen/router.ex" and router_module_name == Oasis.Gen.Router and
             assert(length(binding_pre_routers) == 2)

    Enum.map(plug_files, fn
      {_, file_path1, "pre_plug.ex", Oasis.Gen.PreAddPet, router} ->
        assert file_path1 == "lib/oasis/gen/pre_add_pet.ex" and router.http_verb == "post" and
                 router.operation_id == "addPet"

        body_schema = router.body_schema
        assert router.query_schema == nil and body_schema != nil
        schema = body_schema["content"]["application/json"]["schema"]
        assert is_map(schema) or is_boolean(schema)
        assert valid_schema?(schema, %{"name" => "test-name"})
        assert valid_schema?(schema, %{"tag" => "test-tag"}) == false
        schema = body_schema["content"]["application/x-www-form-urlencoded"]["schema"]
        assert is_map(schema) or is_boolean(schema)

        assert valid_schema?(schema, %{"name" => "test-name", "fav_number" => 1}) == true

        assert valid_schema?(schema, %{"fav_number" => 1}) == false

        assert valid_schema?(schema, %{"name" => "test-name", "fav_number" => 10}) == false

      {_, file_path2, "plug.ex", Oasis.Gen.AddPet, router} ->
        assert file_path2 == "lib/oasis/gen/add_pet.ex" and router.http_verb == "post" and
                 router.operation_id == "addPet"

      {_, file_path3, "pre_plug.ex", Oasis.Gen.PreGetMyPost, router} ->
        assert file_path3 == "lib/oasis/gen/pre_get_my_post.ex" and router.http_verb == "get" and
                 router.operation_id == nil

        assert router.query_schema != nil and router.body_schema == nil
        %{"id" => %{"schema" => schema}} = router.query_schema
        assert valid_schema?(schema, 1) == false
        assert valid_schema?(schema, ["a", "b", "c"]) == true

      {_, file_path4, "plug.ex", Oasis.Gen.GetMyPost, router} ->
        assert file_path4 == "lib/oasis/gen/get_my_post.ex" and router.http_verb == "get" and
                 router.operation_id == nil
    end)
  end

  test "Mix.Oasis.new/2 multi paths" do
    operation1 = %{
      "parameters" => %{
        "path" => [
          %{
            "description" => "ID of pet to delete",
            "in" => "path",
            "name" => "id",
            "required" => true,
            "schema" => %{"format" => "int64", "type" => "integer"}
          }
        ],
        "query" => [
          %{
            "description" => "tags to filter by",
            "in" => "query",
            "name" => "tags",
            "required" => false,
            "schema" => %{"items" => %{"type" => "string"}, "type" => "array"},
            "style" => "form"
          }
        ]
      },
      "operationId" => "delete_pet"
    }

    operation2 = %{
      "parameters" => %{
        "header" => [
          %{"name" => "token", "required" => true, "schema" => %{"type" => "string"}},
          %{"name" => "appid", "required" => true, "schema" => %{"type" => "string"}}
        ]
      }
    }

    operation3 = %{
      "parameters" => %{
        "cookie" => [
          %{"name" => "session_id", "required" => true, "schema" => %{"type" => "integer"}}
        ]
      }
    }

    paths_spec = %{
      "paths" => %{
        "/queryPet" => %{"get" => operation2, "put" => operation3},
        "/delete_pet" => %{"delete" => operation1}
      }
    }

    files = Mix.Oasis.new(paths_spec, router: "my_test_router")
    assert length(files) == 7
    [router_file | plug_files] = files

    {:eex, file_path, _router_template_file_name, router_module_name,
     %{routers: binding_pre_routers}} = router_file

    assert file_path == "lib/oasis/gen/my_test_router.ex" and
             router_module_name == Oasis.Gen.MyTestRouter

    assert length(binding_pre_routers) == 3
    urls = Enum.map(binding_pre_routers, fn router -> router.url end)
    assert urls == ["/delete_pet", "/queryPet", "/queryPet"]

    Enum.map(plug_files, fn
      {_, file_path, "pre_plug.ex", Oasis.Gen.PrePutQueryPet, router} ->
        assert file_path == "lib/oasis/gen/pre_put_query_pet.ex" and router.http_verb == "put"
        assert router.header_schema == nil and router.cookie_schema != nil
        %{"session_id" => %{"schema" => schema}} = router.cookie_schema
        assert valid_schema?(schema, 1) == true
        assert valid_schema?(schema, "abc") == false

      {_, file_path, "plug.ex", Oasis.Gen.PutQueryPet, router} ->
        assert file_path == "lib/oasis/gen/put_query_pet.ex" and router.http_verb == "put"
        assert router.header_schema == nil and router.cookie_schema != nil
        assert router.plug_module == Oasis.Gen.PutQueryPet
        assert router.pre_plug_module == Oasis.Gen.PrePutQueryPet

      {_, file_path, "pre_plug.ex", Oasis.Gen.PreGetQueryPet, router} ->
        %{"token" => %{"schema" => token_schema}, "appid" => %{"schema" => appid_schema}} =
          router.header_schema

        assert valid_schema?(token_schema, "1") == true
        assert valid_schema?(token_schema, 1) == false
        assert valid_schema?(appid_schema, "abc") == true
        assert valid_schema?(appid_schema, 100) == false
        assert file_path == "lib/oasis/gen/pre_get_query_pet.ex" and router.http_verb == "get"
        assert router.header_schema != nil and router.cookie_schema == nil

      {_, file_path, "plug.ex", Oasis.Gen.GetQueryPet, router} ->
        assert file_path == "lib/oasis/gen/get_query_pet.ex" and router.http_verb == "get"
        assert router.header_schema != nil and router.cookie_schema == nil

      {_, file_path, "pre_plug.ex", Oasis.Gen.PreDeletePet, router} ->
        assert file_path == "lib/oasis/gen/pre_delete_pet.ex" and router.http_verb == "delete"
        assert router.path_schema != nil and router.query_schema != nil
        %{"id" => %{"schema" => schema}} = router.path_schema
        assert valid_schema?(schema, 1) == true
        assert valid_schema?(schema, "1") == false
        %{"tags" => %{"schema" => schema}} = router.query_schema
        assert valid_schema?(schema, ["1", "2", "3"]) == true
        assert valid_schema?(schema, "abc") == false

      {_, file_path, "plug.ex", Oasis.Gen.DeletePet, router} ->
        assert file_path == "lib/oasis/gen/delete_pet.ex" and router.http_verb == "delete"
        assert router.path_schema != nil and router.query_schema != nil
        assert router.pre_plug_module == Oasis.Gen.PreDeletePet
        assert router.plug_module == Oasis.Gen.DeletePet
    end)
  end

  test "Mix.Oasis.new/2 optional options" do
    paths_spec = %{
      "paths" => %{
        "/say_hello" => %{
          "get" => %{
            "parameters" => %{
              "query" => [
                %{"name" => "username", "required" => true, "schema" => %{"type" => "string"}}
              ]
            },
            "operationId" => "hello",
            "x-oasis-name-space" => "Wont.Use"
          }
        }
      }
    }

    [router | plugs] = Mix.Oasis.new(paths_spec, name_space: "Try.MyOpenAPI")
    {_, router_file_path, _, router_module_name, binding} = router
    assert router_file_path == "lib/try/my_open_api/router.ex"
    assert router_module_name == Try.MyOpenApi.Router
    assert length(binding.routers) == 1
    [pre_plug_file, plug_file] = plugs
    {_, path, template, module, binding} = pre_plug_file
    assert path == "lib/try/my_open_api/pre_hello.ex"
    assert template == "pre_plug.ex"
    assert module == Try.MyOpenApi.PreHello
    assert binding.pre_plug_module == Try.MyOpenApi.PreHello
    assert binding.plug_module == Try.MyOpenApi.Hello
    {_, path, template, module, binding} = plug_file
    assert path == "lib/try/my_open_api/hello.ex"
    assert template == "plug.ex"
    assert module == Try.MyOpenApi.Hello
    assert binding.pre_plug_module == Try.MyOpenApi.PreHello
    assert binding.plug_module == Try.MyOpenApi.Hello

    [router | plugs] =
      Mix.Oasis.new(paths_spec, name_space: "Try.Test.OpenAPI2", router: "SuperRouter")

    {_, router_file_path, _, router_module_name, binding} = router
    assert router_file_path == "lib/try/test/open_api2/super_router.ex"
    assert router_module_name == Try.Test.OpenApi2.SuperRouter
    assert length(binding.routers) == 1
    [pre_plug_file, plug_file] = plugs
    {_, path, template, module, binding} = pre_plug_file
    assert path == "lib/try/test/open_api2/pre_hello.ex"
    assert template == "pre_plug.ex"
    assert module == Try.Test.OpenApi2.PreHello
    assert binding.pre_plug_module == Try.Test.OpenApi2.PreHello
    assert binding.plug_module == Try.Test.OpenApi2.Hello
    {_, path, template, module, binding} = plug_file
    assert path == "lib/try/test/open_api2/hello.ex"
    assert template == "plug.ex"
    assert module == Try.Test.OpenApi2.Hello
    assert binding.pre_plug_module == Try.Test.OpenApi2.PreHello
    assert binding.plug_module == Try.Test.OpenApi2.Hello
  end

  test "new/2 with bearer token" do
    paths_spec = %{
      "paths" => %{
        "/say_hello" => %{
          "get" => %{
            "parameters" => %{
              "query" => [
                %{"name" => "username", "required" => true, "schema" => %{"type" => "string"}}
              ]
            },
            "operationId" => "hello",
            "x-oasis-name-space" => "Wont.Use",
            "security" => [%{"myBearerAuth" => []}]
          }
        }
      },
      "components" => %{
        "securitySchemes" => %{"myBearerAuth" => %{"scheme" => "bearer", "type" => "http"}}
      }
    }

    [_router, _pre_say_hello, _say_hello, bearer_auth_file] =
      Mix.Oasis.new(paths_spec, name_space: "Security.MyOpenAPI")

    {_, path, template, module, binding} = bearer_auth_file
    assert path == "lib/security/my_open_api/my_bearer_auth.ex"
    assert template == "bearer_token.ex"
    assert module == Security.MyOpenApi.MyBearerAuth
    assert is_list(binding.security)
    [content] = binding.security
    assert content =~ ~s/Oasis.Plug.BearerAuth/
    assert content =~ ~s/security: #{inspect(module)}/
    assert content =~ ~s/key_to_assigns:/ == false
  end

  test "new/2 with bearer token and key to assigns" do
    paths_spec = %{
      "paths" => %{
        "/say_hello" => %{
          "get" => %{
            "parameters" => %{
              "query" => [
                %{"name" => "username", "required" => true, "schema" => %{"type" => "string"}}
              ]
            },
            "operationId" => "hello",
            "security" => [%{"HelloBearerAuth" => []}]
          }
        }
      },
      "components" => %{
        "securitySchemes" => %{
          "HelloBearerAuth" => %{
            "scheme" => "bearer",
            "type" => "http",
            "x-oasis-key-to-assigns" => "id"
          }
        }
      }
    }

    [_router, _pre_say_hello, _say_hello, bearer_auth_file] = Mix.Oasis.new(paths_spec, [])
    {_, path, template, module, binding} = bearer_auth_file
    assert path == "lib/oasis/gen/hello_bearer_auth.ex"
    assert template == "bearer_token.ex"
    assert module == Oasis.Gen.HelloBearerAuth
    assert is_list(binding.security)
    [content] = binding.security
    assert content =~ ~s/Oasis.Plug.BearerAuth/
    assert content =~ ~s/security: Oasis.Gen.HelloBearerAuth/
    assert content =~ ~s/key_to_assigns: :id/
  end

  test "new/2 with which security mechanisms can be used for operation object" do
    paths_spec = %{
      "paths" => %{
        "/say_hello" => %{
          "get" => %{
            "parameters" => %{
              "query" => [
                %{"name" => "username", "required" => true, "schema" => %{"type" => "string"}}
              ]
            },
            "operationId" => "hello",
            "security" => [%{"HelloBearerAuth" => []}]
          }
        },
        "/save" => %{"post" => %{"content" => %{"application/json" => %{}}}}
      },
      "components" => %{
        "securitySchemes" => %{
          "HelloBearerAuth" => %{
            "scheme" => "bearer",
            "type" => "http",
            "x-oasis-key-to-assigns" => "id"
          },
          "GlobalBearerAuth" => %{
            "scheme" => "bearer",
            "type" => "http",
            "x-oasis-key-to-assigns" => "user"
          }
        }
      },
      "security" => [%{"GlobalBearerAuth" => []}]
    }

    [_router | plugs_pairs] = Mix.Oasis.new(paths_spec, [])

    plugs_pairs
    |> Enum.chunk_every(3)
    |> Enum.map(fn files ->
      [_pre_plug, plug, auth_file] = files
      {_, plug_path, _, _, _} = plug
      {_, path, "bearer_token.ex", module, binding} = auth_file
      [content] = binding.security

      case path do
        "lib/oasis/gen/global_bearer_auth.ex" ->
          assert plug_path == "lib/oasis/gen/post_save.ex"
          assert module == Oasis.Gen.GlobalBearerAuth
          assert content =~ ~s/Oasis.Plug.BearerAuth/
          assert content =~ ~s/key_to_assigns: :user/
          assert content =~ ~s/security: Oasis.Gen.GlobalBearerAuth/

        "lib/oasis/gen/hello_bearer_auth.ex" ->
          assert plug_path == "lib/oasis/gen/hello.ex"
          assert module == Oasis.Gen.HelloBearerAuth
          assert content =~ ~s/Oasis.Plug.BearerAuth/
          assert content =~ ~s/key_to_assigns: :id/
          assert content =~ ~s/security: Oasis.Gen.HelloBearerAuth/
      end
    end)
  end

  test "security of operation overrides top-level security" do
    paths_spec = %{
      "security" => [%{"myHMACAuth" => []}],
      "paths" => %{
        "/say_hello" => %{
          "get" => %{
            "parameters" => %{
              "query" => [
                %{"name" => "username", "required" => true, "schema" => %{"type" => "string"}}
              ]
            },
            "operationId" => "hello",
            "x-oasis-name-space" => "Wont.Use",
            "security" => [%{"myBearerAuth" => []}]
          }
        }
      },
      "components" => %{
        "securitySchemes" => %{
          "myBearerAuth" => %{"scheme" => "bearer", "type" => "http"},
          "myHMACAuth" => %{
            "scheme" => "hmac-sha256",
            "type" => "http",
            "x-oasis-signed-headers" => "date;x-cbe-content-sha256"
          }
        }
      }
    }

    [_router, _pre_say_hello, _say_hello, bearer_auth_file] =
      Mix.Oasis.new(paths_spec, name_space: "Security.MyOpenAPI")

    {_, path, template, module, binding} = bearer_auth_file
    assert path == "lib/security/my_open_api/my_bearer_auth.ex"
    assert template == "bearer_token.ex"
    assert module == Security.MyOpenApi.MyBearerAuth
    assert is_list(binding.security)
    [content] = binding.security
    assert content =~ ~s/Oasis.Plug.BearerAuth/
    assert content =~ ~s/security: #{inspect(module)}/
    assert content =~ ~s/key_to_assigns:/ == false
  end

  test "new/2 with not supported security scheme" do
    paths_spec = %{
      "paths" => %{
        "/say_hello" => %{
          "get" => %{
            "parameters" => %{
              "query" => [
                %{"name" => "username", "required" => true, "schema" => %{"type" => "string"}}
              ]
            },
            "operationId" => "hello",
            "x-oasis-name-space" => "Wont.Use",
            "security" => [%{"my_bearer_auth" => []}]
          }
        },
        "/say_bye" => %{"delete" => %{"security" => [%{"my_key_auth" => []}]}}
      },
      "components" => %{
        "securitySchemes" => %{
          "my_bearer_auth" => %{"scheme" => "bearer", "type" => "http"},
          "my_key_auth" => %{"type" => "apiKey", "name" => "api_key", "in" => "header"}
        }
      }
    }

    [_router | files] = Mix.Oasis.new(paths_spec, name_space: "Security.OpenApi")
    {say_hello_files, say_bye_files} = Enum.split(files, 3)
    [_, _, bearer_auth_file] = say_hello_files
    {_, path, "bearer_token.ex", module, binding} = bearer_auth_file
    assert path == "lib/security/open_api/my_bearer_auth.ex"
    assert module == Security.OpenApi.MyBearerAuth
    [content] = binding.security
    assert content =~ ~s/Oasis.Plug.BearerAuth/
    assert content =~ ~s/security: Security.OpenApi.MyBearerAuth/
    [pre_plug, _plug] = say_bye_files
    {_, path, "pre_plug.ex", module, binding} = pre_plug
    assert path == "lib/security/open_api/pre_delete_say_bye.ex"
    assert module == Security.OpenApi.PreDeleteSayBye
    assert binding.security == nil
  end

  test "new/2 with x-oasis-name-space field of security scheme object" do
    paths_spec = %{
      "paths" => %{
        "/url1" => %{
          "get" => %{"x-oasis-name-space" => "URL1", "security" => [%{"bearer_auth" => []}]}
        },
        "/url2" => %{
          "post" => %{"x-oasis-name-space" => "URL2", "security" => [%{"bearer_auth" => []}]}
        }
      },
      "components" => %{
        "securitySchemes" => %{
          "bearer_auth" => %{
            "scheme" => "bearer",
            "type" => "http",
            "x-oasis-name-space" => "MyToken"
          }
        }
      }
    }

    [_router | files] = Mix.Oasis.new(paths_spec, [])
    {plugs_url2, plugs_url1} = Enum.split(files, 3)
    [pre_plug, _, bearer_file] = plugs_url2
    {_, path, "pre_plug.ex", module, binding} = pre_plug
    assert path == "lib/url2/pre_post_url2.ex"
    assert module == Url2.PrePostUrl2
    [content] = binding.security
    assert content =~ ~s/Oasis.Plug.BearerAuth/
    assert content =~ ~s/security: MyToken.BearerAuth/
    {_, path, "bearer_token.ex", module, binding_from_bearer} = bearer_file
    assert path == "lib/my_token/bearer_auth.ex"
    assert module == MyToken.BearerAuth
    assert binding_from_bearer == binding
    [pre_plug, _, bearer_file] = plugs_url1
    {_, path, "pre_plug.ex", module, binding} = pre_plug
    assert path == "lib/url1/pre_get_url1.ex"
    assert module == Url1.PreGetUrl1
    [content] = binding.security
    assert content =~ ~s/Oasis.Plug.BearerAuth/
    assert content =~ ~s/security: MyToken.BearerAuth/
    {_, path, "bearer_token.ex", module, binding_from_bearer} = bearer_file
    assert path == "lib/my_token/bearer_auth.ex"
    assert module == MyToken.BearerAuth
    assert binding_from_bearer == binding
  end

  test "new/2 with x-oasis-name-space field of security scheme object and :name_space opt" do
    paths_spec = %{
      "paths" => %{
        "/url1" => %{
          "get" => %{"x-oasis-name-space" => "URL1", "security" => [%{"bearer_auth" => []}]}
        },
        "/url2" => %{
          "post" => %{"x-oasis-name-space" => "URL2", "security" => [%{"bearer_auth" => []}]}
        }
      },
      "components" => %{
        "securitySchemes" => %{
          "bearer_auth" => %{
            "scheme" => "bearer",
            "type" => "http",
            "x-oasis-name-space" => "MyToken"
          }
        }
      }
    }

    [_router | files] = Mix.Oasis.new(paths_spec, name_space: "Security.OpenApi")
    {plugs_url2, plugs_url1} = Enum.split(files, 3)
    [pre_plug, _, bearer_file] = plugs_url2
    {_, path, "pre_plug.ex", module, binding} = pre_plug
    assert path == "lib/security/open_api/pre_post_url2.ex"
    assert module == Security.OpenApi.PrePostUrl2
    [content] = binding.security
    assert content =~ ~s/Oasis.Plug.BearerAuth/
    assert content =~ ~s/security: Security.OpenApi.BearerAuth/
    {_, path, "bearer_token.ex", module, binding_from_bearer} = bearer_file
    assert path == "lib/security/open_api/bearer_auth.ex"
    assert module == Security.OpenApi.BearerAuth
    assert binding_from_bearer == binding
    [pre_plug, _, bearer_file] = plugs_url1
    {_, path, "pre_plug.ex", module, binding} = pre_plug
    assert path == "lib/security/open_api/pre_get_url1.ex"
    assert module == Security.OpenApi.PreGetUrl1
    [content] = binding.security
    assert content =~ ~s/Oasis.Plug.BearerAuth/
    assert content =~ ~s/security: Security.OpenApi.BearerAuth/
    {_, path, "bearer_token.ex", module, binding_from_bearer} = bearer_file
    assert path == "lib/security/open_api/bearer_auth.ex"
    assert module == Security.OpenApi.BearerAuth
    assert binding_from_bearer == binding
  end
end
