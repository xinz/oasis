Code.require_file("../../support/mix/mix_helper.exs", __DIR__)

defmodule Mix.Tasks.Oas.Gen.PlugTest do
  use ExUnit.Case
  import Oasis.MixHelper
  alias Mix.Tasks.Oas.Gen

  @jsonschex_boundary_dir Path.expand("file/jsonschex_boundary", __DIR__)

  setup do
    Mix.Task.clear()
    :ok
  end

  defp with_compiled_files(paths, fun) do
    do_with_compiled_files(paths, [], fun)
  end

  defp do_with_compiled_files([], modules, fun) do
    try do
      fun.(modules)
    after
      unload_modules(modules)
    end
  end

  defp do_with_compiled_files([path | paths], modules, fun) do
    compiled_modules =
      try do
        path
        |> Code.compile_file()
        |> Enum.map(&elem(&1, 0))
      rescue
        exception ->
          unload_modules(modules)
          reraise exception, __STACKTRACE__
      end

    do_with_compiled_files(paths, compiled_modules ++ modules, fun)
  end

  defp unload_modules(modules) do
    Enum.each(Enum.uniq(modules), fn module ->
      :code.purge(module)
      :code.delete(module)
    end)
  end

  defp call_generated_router(router_module, request_path, body) do
    conn =
      Plug.Test.conn(:post, request_path, Jason.encode!(body))
      |> Plug.Conn.put_req_header("content-type", "application/json")

    opts = apply(router_module, :init, [[]])
    apply(router_module, :call, [conn, opts])
  end

  test("run in root of an umbrella project", config) do
    in_tmp_project(config.test, fn ->
      File.write!("mix.exs", umbrella_mixfile_contents())
      File.mkdir!("apps")

      Mix.Project.in_project(:my_umbrella_app, File.cwd!(), fn _module ->
        assert_raise Mix.Error,
                     ~s/mix oas.gen.plug can only be run inside an application directory/,
                     fn ->
                       Gen.Plug.run([
                         "--file",
                         Path.join([__DIR__, "file/petstore-expanded.yaml"])
                       ])
                     end
      end)
    end)
  end

  test("run in one of apps in an umbrella project", config) do
    in_tmp_project(config.test, fn ->
      File.write!("mix.exs", umbrella_mixfile_contents())
      File.mkdir_p!("apps/other_app")
      File.cd!("apps/other_app")

      Mix.Project.in_project(:my_umbrella_app2, File.cwd!(), fn _module ->
        Gen.Plug.run([
          "--file",
          Path.join([__DIR__, "file/petstore-expanded.yaml"]),
          "--name-space",
          "Hello"
        ])

        assert_file("lib/hello/find_pet_by_id.ex")
        assert_file("lib/hello/find_pet_by_id.ex")
        assert_file("lib/hello/pre_delete_pet.ex")
        assert_file("lib/hello/delete_pet.ex")
        assert_file("lib/hello/pre_find_pets.ex")
        assert_file("lib/hello/find_pets.ex")
      end)
    end)
  end

  test("invalid mix argument", config) do
    in_tmp_project(config.test, fn ->
      assert_raise Mix.Error,
                   ~r(Expected input `--file` option to be a valid path to a yaml/json file),
                   fn -> Gen.Plug.run([]) end

      assert_raise Mix.Error, ~r(Could not find the file in `non_existance.yaml` path), fn ->
        Gen.Plug.run(["--file", "non_existance.yaml"])
      end
    end)
  end

  test("generates plugs", config) do
    in_tmp_project(config.test, fn ->
      file_path = Path.join([__DIR__, "file/petstore-expanded.yaml"])
      Gen.Plug.run(["--file", file_path])

      assert_file("lib/oasis/gen/router.ex", fn file ->
        assert file =~ ~s|defmodule Oasis.Gen.Router do|
        assert file =~ ~s|use Oasis.Router|
        assert file =~ ~s|plug(:match)|
        assert file =~ ~s|plug(:dispatch)|
        assert file =~ ~s|get(\n    "/pets",\n    to: Oasis.Gen.PreFindPets|
        assert file =~ ~s|post(\n    "/pets",\n    to: Oasis.Gen.PreAddPet|
        assert file =~ ~s|delete(\n    "/pets/:id",\n    private: %{\n      path_schema: %{|
        assert file =~ ~s|to: Oasis.Gen.PreDeletePet|
        assert file =~ ~s|get(\n    "/pets/:id",\n    private: %{\n      path_schema: %{\n|
        assert file =~ ~s|to: Oasis.Gen.PreFindPetById|
        assert file =~ ~s|match _ do|
      end)

      assert_file("lib/oasis/gen/pre_add_pet.ex", fn file ->
        assert file =~ ~s|defmodule Oasis.Gen.PreAddPet do|
        assert file =~ ~s|use Oasis.Controller|
        assert file =~ ~s|plug(\n    Plug.Parsers,|

        assert file =~ ~s|"application/json" => %{
          "schema" =>
            JSONSchex.Schema.compile!(|

        assert file =~ ~s/conn |> super(opts) |> Oasis.Gen.AddPet.call(opts) |> halt()/
      end)

      assert_file("lib/oasis/gen/add_pet.ex", [
        ~s|defmodule Oasis.Gen.AddPet do|,
        ~s|use Oasis.Controller|,
        ~s|def call(conn, _opts) do|,
        ~s|def handle_errors(|
      ])

      assert_file(
        "lib/oasis/gen/pre_find_pet_by_id.ex",
        ~s|defmodule Oasis.Gen.PreFindPetById do|
      )

      assert_file("lib/oasis/gen/find_pet_by_id.ex")
      assert_file("lib/oasis/gen/pre_delete_pet.ex")
      assert_file("lib/oasis/gen/delete_pet.ex")
      assert_file("lib/oasis/gen/pre_find_pets.ex")
      assert_file("lib/oasis/gen/find_pets.ex")
    end)
  end

  test "generated external and recursive schemas compile and execute", %{test: test_name} do
    boundaries = [
      %{
        fixture: "external_schema.yaml",
        namespace: "Oasis.GeneratedBoundary.External",
        operation: "create_user",
        request_path: "/users",
        valid: %{"name" => "Ada", "age" => 42},
        invalid: %{"age" => 42}
      },
      %{
        fixture: "recursive_schema.yaml",
        namespace: "Oasis.GeneratedBoundary.Recursive",
        operation: "create_node",
        request_path: "/nodes",
        valid: %{
          "name" => "l0",
          "next" => %{
            "name" => "l1",
            "next" => %{
              "name" => "l2",
              "next" => %{"name" => "l3"}
            }
          }
        },
        invalid: %{
          "name" => "l0",
          "next" => %{
            "name" => "l1",
            "next" => %{
              "name" => "l2",
              "next" => %{"next" => %{"name" => "l4"}}
            }
          }
        }
      }
    ]

    Enum.each(boundaries, fn boundary ->
      in_tmp_project("#{test_name}_#{boundary.operation}", fn ->
        fixture_path = Path.join(@jsonschex_boundary_dir, boundary.fixture)

        Gen.Plug.run([
          "--file",
          fixture_path,
          "--name-space",
          boundary.namespace,
          "--force",
          "--quiet"
        ])

        generated_dir =
          boundary.namespace
          |> String.split(".")
          |> Enum.map(&Macro.underscore/1)
          |> then(&Path.join(["lib" | &1]))

        handler_path = Path.join(generated_dir, "#{boundary.operation}.ex")
        pre_path = Path.join(generated_dir, "pre_#{boundary.operation}.ex")
        router_path = Path.join(generated_dir, "router.ex")
        source_paths = [handler_path, pre_path, router_path]

        assert Enum.sort(Path.wildcard(Path.join(generated_dir, "*.ex"))) == Enum.sort(source_paths)

        sources = Map.new(source_paths, &{&1, File.read!(&1)})

        assert Enum.filter(source_paths, &(sources[&1] =~ "require JSONSchex.Schema")) == [pre_path]
        assert Enum.filter(source_paths, &(sources[&1] =~ "JSONSchex.Schema.compile!")) == [pre_path]

        namespace_module = boundary.namespace |> String.split(".") |> Module.concat()
        handler_module = Module.concat(namespace_module, Macro.camelize(boundary.operation))
        pre_module = Module.concat(namespace_module, "Pre" <> Macro.camelize(boundary.operation))
        router_module = Module.concat(namespace_module, "Router")
        expected_modules = [handler_module, pre_module, router_module]

        with_compiled_files(source_paths, fn compiled_modules ->
          assert MapSet.new(compiled_modules) == MapSet.new(expected_modules)

          assert %Plug.Conn{halted: true, body_params: valid_body} =
                   call_generated_router(router_module, boundary.request_path, boundary.valid)

          assert valid_body == boundary.valid

          wrapper =
            assert_raise Plug.Conn.WrapperError, ~r/Failed to validate JSON schema/, fn ->
              call_generated_router(router_module, boundary.request_path, boundary.invalid)
            end

          assert %Oasis.BadRequestError{} = wrapper.reason
          assert_receive {:plug_conn, :sent}
        end)

        Enum.each(expected_modules, fn module ->
          assert :code.is_loaded(module) == false
        end)
      end)
    end)
  end

  test("generates with bearer token", config) do
    in_tmp_project(config.test, fn ->
      file_path = Path.join([__DIR__, "file/petstore-expanded-with-bearer-auth.yaml"])
      Gen.Plug.run(["--file", file_path])

      assert_file("lib/oasis/gen/bearer_auth1.ex", fn file ->
        assert file =~ ~s|defmodule Oasis.Gen.BearerAuth1 do|
        assert file =~ ~s|@behaviour Oasis.Token|
        assert file =~ ~s|def crypto_config(_conn, _opts) do|
      end)

      assert_file("lib/oasis/gen/bearer_auth2.ex", fn file ->
        assert file =~ ~s|defmodule Oasis.Gen.BearerAuth2 do|
        assert file =~ ~s|@behaviour Oasis.Token|
        assert file =~ ~s|def crypto_config(_conn, _opts) do|
      end)

      assert_file("lib/oasis/gen/pre_find_pets.ex", fn file ->
        assert file =~ ~s|plug(\n    Oasis.Plug.BearerAuth,\n    security: Oasis.Gen.BearerAuth1|
      end)

      assert_file("lib/oasis/gen/pre_add_pet.ex", fn file ->
        assert file =~ ~s|plug(\n    Oasis.Plug.BearerAuth,\n    security: Oasis.Gen.BearerAuth1|
      end)

      assert_file("lib/oasis/gen/pre_delete_pet.ex", fn file ->
        assert file =~ ~s|plug(\n    Oasis.Plug.BearerAuth,\n    security: Oasis.Gen.BearerAuth2|
      end)

      assert_file("lib/oasis/gen/pre_find_pet_by_id.ex", fn file ->
        assert file =~ ~s|plug(\n    Oasis.Plug.BearerAuth,\n    security: Oasis.Gen.BearerAuth2|
      end)
    end)
  end

  test("generates with HMAC token", config) do
    in_tmp_project(config.test, fn ->
      file_path = Path.join([__DIR__, "file/petstore-expanded-with-hmac-auth.yaml"])
      Gen.Plug.run(["--file", file_path])

      assert_file("lib/oasis/gen/hmac_auth1.ex", fn file ->
        assert file =~ ~s|defmodule Oasis.Gen.HmacAuth1 do|
        assert file =~ ~s|@behaviour Oasis.HMACToken|
        assert file =~ ~s|def crypto_config(_conn, _opts, _credential) do|
      end)

      assert_file("lib/oasis/gen/hmac_auth2.ex", fn file ->
        assert file =~ ~s|defmodule Oasis.Gen.HmacAuth2 do|
        assert file =~ ~s|@behaviour Oasis.HMACToken|
        assert file =~ ~s|def crypto_config(_conn, _opts, _credential) do|
      end)

      assert_file("lib/oasis/gen/pre_find_pets.ex", fn file ->
        assert file =~ ~s|plug(\n    Oasis.Plug.HMACAuth,\n    security: Oasis.Gen.HmacAuth1|
      end)

      assert_file("lib/oasis/gen/pre_add_pet.ex", fn file ->
        assert file =~ ~s|plug(\n    Oasis.Plug.HMACAuth,\n    security: Oasis.Gen.HmacAuth1|
      end)

      assert_file("lib/oasis/gen/pre_delete_pet.ex", fn file ->
        assert file =~ ~s|plug(\n    Oasis.Plug.HMACAuth,\n    security: Oasis.Gen.HmacAuth2|
      end)

      assert_file("lib/oasis/gen/pre_find_pet_by_id.ex", fn file ->
        assert file =~ ~s|plug(\n    Oasis.Plug.HMACAuth,\n    security: Oasis.Gen.HmacAuth2|
      end)
    end)
  end
end
