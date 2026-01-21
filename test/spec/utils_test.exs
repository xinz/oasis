defmodule Oasis.Spec.UtilsTest do
  use ExUnit.Case

  test "expand $ref" do
    yaml_str = """
      components:
        parameters:
          ContentQueryParam:
            name: content
            in: query
            schema:
              $ref: "#/components/schemas/Contents"
        schemas:
          Content:
            type: object
            required:
              - name
              - tags
            properties:
              name:
                type: string
              tags:
                type: array
                items:
                  $ref: "#/components/schemas/Tag"
          Contents:
            type: array
            items:
              $ref: "#/components/schemas/Content"
          Tag:
            type: string
      paths:
        /page:
          get:
            parameters:
              - $ref: "#/components/parameters/ContentQueryParam"
            responses:
              '200':
                description: callback successfully processed
        /contents:
          get:
            parameters:
              - $ref: "#/components/parameters/ContentQueryParam"
            responses:
              '200':
                description: callback successfully processed
          post:
            requestBody:
              description: Callback payload
              content:
                'application/json':
                  schema:
                    $ref: '#/components/schemas/Contents'
            responses:
              '200':
                description: callback successfully processed
    """

    {:ok, data} = YamlElixir.read_from_string(yaml_str)

    root = ExJsonSchema.Schema.resolve(data) |> Oasis.Spec.Utils.expand_ref()

    assert root.__struct__ == ExJsonSchema.Schema.Root

    schema = root.schema

    comp_schemas = get_in(schema, ["components", "schemas"])

    ref_tag = get_in(comp_schemas, ["Content", "properties", "tags", "items"])

    assert ref_tag == %{"type" => "string"}

    ref_contents = get_in(comp_schemas, ["Contents", "items"])

    content = %{
      "type" => "object",
      "required" => ["name", "tags"],
      "properties" => %{
        "name" => %{"type" => "string"},
        "tags" => %{
          "type" => "array",
          "items" => %{"type" => "string"}
        }
      }
    }

    assert ref_contents == content

    comp_params = get_in(schema, ["components", "parameters"])

    content_query_param = get_in(comp_params, ["ContentQueryParam"])

    assert content_query_param["schema"] == %{
             "type" => "array",
             "items" => content
           }

    page_path_get = get_in(schema, ["paths", "/page", "get"])
    common_content_params = page_path_get["parameters"]

    assert length(common_content_params) == 1

    content_param = Enum.at(common_content_params, 0)

    assert content_param["name"] == "content" and
             content_param["in"] == "query"

    contents_path_post_request_body_schema =
      get_in(schema, [
        "paths",
        "/contents",
        "post",
        "requestBody",
        "content",
        "application/json",
        "schema"
      ])

    assert contents_path_post_request_body_schema == %{
             "type" => "array",
             "items" => content
           }

    contents_path_get = get_in(schema, ["paths", "/contents", "get"])
    common_content_params = contents_path_get["parameters"]

    assert length(common_content_params) == 1

    content_param = Enum.at(common_content_params, 0)

    assert content_param["name"] == "content" and
             content_param["in"] == "query"
  end

  test "$ref's sibling properties are ignored" do
    yaml_str = """
      components:
        pathItems:
          Common:
            get:
              parameters:
                - name: lang
                  in: query
                  schema:
                    style: "integer"
      paths:
        /test1:
          $ref: "#/components/pathItems/Common"
          get:
            parameters:
              - name: l
                in: query
                schema:
                  style: "integer"
    """

    {:ok, data} = YamlElixir.read_from_string(yaml_str)

    root = ExJsonSchema.Schema.resolve(data) |> Oasis.Spec.Utils.expand_ref()

    # After upgrade `ex_json_schema` to 0.11.*
    # If the `$ref` is present, all other sibling properties are ignored after resolved.
    params = get_in(root.schema, ["paths", "/test1", "get", "parameters"])
    assert Enum.at(params, 0)["name"] == "lang"

    yaml_str = """
      components:
        pathItems:
          Common:
            get:
              parameters:
                - name: lang
                  in: query
                  schema:
                    style: "integer"
          Common2:
            get:
              parameters:
                - name: lang2
                  in: query
                  schema:
                    style: "string"
      paths:
        /test1:
          get:
            parameters:
              - name: l
                in: query
                schema:
                  style: "integer"
          $ref: "#/components/pathItems/Common"
          $ref: "#/components/pathItems/Common2"
    """

    {:ok, data} = YamlElixir.read_from_string(yaml_str)

    root = ExJsonSchema.Schema.resolve(data) |> Oasis.Spec.Utils.expand_ref()

    params = get_in(root.schema, ["paths", "/test1", "get", "parameters"])
    assert length(params) == 1 and Enum.at(params, 0)["name"] == "lang"
  end
end
