defmodule Oasis.Spec.SpecTest do
  use ExUnit.Case

  @dir Path.expand("./file", __DIR__)

  test "parse basic info from yaml and json" do
    file_path = Path.join([@dir, "basic.yaml"])
    %Oasis.Spec.Document{schema: schema} = Oasis.Spec.read(file_path)

    assert schema["openapi"] == "3.1.0"

    info = schema["info"]

    assert info["title"] == "Test API" and info["version"] == "1.0.0"

    assert length(schema["servers"]) == 3

    file_path = Path.join([@dir, "basic.json"])
    %Oasis.Spec.Document{schema: schema_from_json} = Oasis.Spec.read(file_path)

    assert schema_from_json == schema
  end

  test "resolves external OpenAPI refs from a relative root spec path" do
    %Oasis.Spec.Document{schema: schema, source_path: source_path} =
      Oasis.Spec.read("test/spec/file/external_openapi/root.yaml")

    assert Path.type(source_path) == :absolute

    assert get_in(schema, ["paths", "/users/:id", "get", "parameters", "path", Access.at(0), "schema"]) == %{
             "type" => "integer"
           }
  end

  test "returns structural OpenAPI resolver failures as error tuples" do
    path =
      Path.join(
        System.tmp_dir!(),
        "oasis_invalid_openapi_ref_#{System.unique_integer([:positive])}.yaml"
      )

    File.write!(path, """
    paths:
      /users:
        $ref: '#/components/pathItems/Missing'
    """)

    on_exit(fn -> File.rm(path) end)

    assert {:error, %Oasis.InvalidSpecError{message: message}} = Oasis.Spec.read(path)
    assert message =~ "Could not resolve OpenAPI ref"
  end

  test "rejects pre-normalized parameter maps in raw OpenAPI files" do
    path =
      Path.join(
        System.tmp_dir!(),
        "oasis_normalized_parameters_#{System.unique_integer([:positive])}.yaml"
      )

    File.write!(path, """
    paths:
      /users:
        get:
          parameters:
            query: []
    """)

    on_exit(fn -> File.rm(path) end)

    assert {:error, %Oasis.InvalidSpecError{message: message}} = Oasis.Spec.read(path)
    assert message =~ "parameters in path `/users` must be an array"
  end

  test "returns malformed Operation Objects as invalid-spec tuples" do
    path =
      Path.join(
        System.tmp_dir!(),
        "oasis_invalid_operation_#{System.unique_integer([:positive])}.yaml"
      )

    File.write!(path, """
    paths:
      /users:
        get: 42
    """)

    on_exit(fn -> File.rm(path) end)

    assert {:error, %Oasis.InvalidSpecError{message: message}} = Oasis.Spec.read(path)
    assert message =~ "Operation Object for `get` in path `/users` must be an object"
  end

  test "input invalid path" do
    {:error, %Oasis.FileNotFoundError{message: message}} = Oasis.Spec.read("unknown.yaml")
    assert message =~ ~s/Failed to open file "unknown.yaml"/

    {:error, %Oasis.FileNotFoundError{message: message}} = Oasis.Spec.read("unknown.json")
    assert message =~ ~s/Failed to open file "unknown.json" with error enoent/
  end

  test "non-object root document returns an invalid spec error" do
    file_path = Path.join([@dir, "non_object.json"])

    assert {:error, %Oasis.InvalidSpecError{message: message}} = Oasis.Spec.read(file_path)
    assert message =~ "OpenAPI document root must be an object"
  end

  test "invalid yaml file content" do
    file_path = Path.join([@dir, "malformed.yml"])
    {:error, %Oasis.InvalidSpecError{message: message}} = Oasis.Spec.read(file_path)
    assert message =~ ~s/Failed to parse yaml file: malformed yaml/

    file_path = Path.join([@dir, "invalid.yml"])
    {:error, %Oasis.InvalidSpecError{message: message}} = Oasis.Spec.read(file_path)
    assert message =~ ~s/Failed to parse yaml file: No anchor corresponds to alias "invalid"/

    file_path = Path.join([@dir, "invalid.json"])
    {:error, %Oasis.InvalidSpecError{message: message}} = Oasis.Spec.read(file_path)
    assert message =~ ~s/Failed to parse json file: `invalid\n`/
  end

  test "invalid format file type" do
    {:error, %Oasis.InvalidSpecError{message: message}} = Oasis.Spec.read("hello.txt")
    assert message =~ ~s(Expect a yml/yaml or json format file, but got: `.txt`)
  end

  test "parse post requestBodies" do
    file_path = Path.join([@dir, "basic.yaml"])
    %Oasis.Spec.Document{schema: schema} = Oasis.Spec.read(file_path)

    request_body_of_refresh_token = schema["paths"]["/refresh_token"]["post"]["requestBody"]
    assert request_body_of_refresh_token["required"] == true

    json_schema = request_body_of_refresh_token["content"]["application/json"]["schema"]
    assert json_schema == %{"$ref" => "#/components/schemas/RefreshTokenForm"}

    {:ok, bundled} =
      JSONSchex.bundle_fragment(schema,
        entry: "#/paths/~1refresh_token/post/requestBody/content/application~1json/schema",
        base_uri: file_path
      )

    assert {:ok, compiled} =
             JSONSchex.compile(bundled,
               format_assertion: true,
               content_assertion: false
             )

    assert JSONSchex.validate(compiled, %{"refresh_token" => "123"}) == :ok
    assert {:error, _} = JSONSchex.validate(compiled, %{})
  end
end
