defmodule Oasis.ValidatorTest do
    use ExUnit.Case
  alias Oasis.Validator

  test "validation errors expose use_in/param_name and underlying JSONSchex error" do
    param = %{
      "required" => true,
      "schema" =>
        Oasis.Test.JSONSchema.compile!(%{
          "type" => "object",
          "required" => ["name"],
          "properties" => %{"name" => %{"type" => "string"}}
        })
    }

    try do
      Validator.parse_and_validate!(param, "body", "user", %{})
      flunk("expected Oasis.BadRequestError")
    rescue
      error in Oasis.BadRequestError ->
        assert error.use_in == "body"
        assert error.param_name == "user"

        assert %Oasis.BadRequestError.JSONSchemaValidationFailed{
                 error: %JSONSchex.Types.Error{rule: :required},
                 path: "#"
               } = error.error
    end
  end

  describe "JSONSchemaValidationFailed.path JSON Pointer format" do
    # These tests pin the JSON Pointer (RFC 6901) format used in
    # `JSONSchemaValidationFailed.path`:
    #
    #   * empty path → "#"
    #   * non-empty path → "#/" + "/"-joined segments
    #   * `~` in a segment → escaped as `~0`
    #   * `/` in a segment → escaped as `~1`
    #   * `required` rule errors carry the path of the *containing* object,
    #     not the missing property
    #
    # The encoder lives in `Oasis.Validator.path_pointer/1`; we exercise it
    # end-to-end through `parse_and_validate!/4` so the contract is observable
    # at the public boundary.

    test "empty path renders as '#' (root-level required failure)" do
      param = %{
        "required" => true,
        "schema" =>
          Oasis.Test.JSONSchema.compile!(%{
            "type" => "object",
            "required" => ["name"],
            "properties" => %{"name" => %{"type" => "string"}}
          })
      }

      assert %Oasis.BadRequestError.JSONSchemaValidationFailed{path: "#"} =
               capture_validation_error(param, "body", "user", %{})
    end

    test "nested required failure points to the containing object's path" do
      param = %{
        "required" => true,
        "schema" =>
          Oasis.Test.JSONSchema.compile!(%{
            "type" => "object",
            "properties" => %{
              "user" => %{
                "type" => "object",
                "required" => ["name"],
                "properties" => %{"name" => %{"type" => "string"}}
              }
            },
            "required" => ["user"]
          })
      }

      assert %Oasis.BadRequestError.JSONSchemaValidationFailed{
               error: %JSONSchex.Types.Error{rule: :required},
               path: "#/user"
             } = capture_validation_error(param, "body", "payload", %{"user" => %{}})
    end

    test "`/` in a property name is escaped as `~1`" do
      param = %{
        "required" => true,
        "schema" =>
          Oasis.Test.JSONSchema.compile!(%{
            "type" => "object",
            "properties" => %{
              "a/b" => %{"type" => "string", "minLength" => 5}
            }
          })
      }

      assert %Oasis.BadRequestError.JSONSchemaValidationFailed{path: "#/a~1b"} =
               capture_validation_error(param, "body", "payload", %{"a/b" => "x"})
    end

    test "`~` in a property name is escaped as `~0`" do
      param = %{
        "required" => true,
        "schema" =>
          Oasis.Test.JSONSchema.compile!(%{
            "type" => "object",
            "properties" => %{
              "c~d" => %{"type" => "string", "minLength" => 5}
            }
          })
      }

      assert %Oasis.BadRequestError.JSONSchemaValidationFailed{path: "#/c~0d"} =
               capture_validation_error(param, "body", "payload", %{"c~d" => "x"})
    end

    test "both `~` and `/` are escaped in the same segment (order: ~ first)" do
      # RFC 6901 mandates `~` be escaped before `/`, otherwise an existing `~1`
      # in the source name would be ambiguously decoded.
      param = %{
        "required" => true,
        "schema" =>
          Oasis.Test.JSONSchema.compile!(%{
            "type" => "object",
            "properties" => %{
              "~/odd" => %{"type" => "string", "minLength" => 5}
            }
          })
      }

      assert %Oasis.BadRequestError.JSONSchemaValidationFailed{path: "#/~0~1odd"} =
               capture_validation_error(param, "body", "payload", %{"~/odd" => "x"})
    end

    test "URI-fragment encodes spaces, percent signs, and hashes" do
      param = %{
        "schema" =>
          Oasis.Test.JSONSchema.compile!(%{
            "type" => "object",
            "properties" => %{
              "space %#" => %{"type" => "string", "minLength" => 5}
            }
          })
      }

      assert %Oasis.BadRequestError.JSONSchemaValidationFailed{path: "#/space%20%25%23"} =
               capture_validation_error(param, "body", "payload", %{"space %#" => "x"})
    end

    test "array indices appear as integer segments without escaping" do
      param = %{
        "required" => true,
        "schema" =>
          Oasis.Test.JSONSchema.compile!(%{
            "type" => "array",
            "items" => %{"type" => "string", "minLength" => 5}
          })
      }

      assert %Oasis.BadRequestError.JSONSchemaValidationFailed{path: "#/1"} =
               capture_validation_error(param, "body", "payload", ["hello", "x"])
    end

    test "nested object segments are rendered root-first" do
      param = %{
        "schema" =>
          Oasis.Test.JSONSchema.compile!(%{
            "type" => "object",
            "properties" => %{
              "outer" => %{
                "type" => "object",
                "properties" => %{
                  "inner" => %{"type" => "string", "minLength" => 5}
                }
              }
            }
          })
      }

      assert %Oasis.BadRequestError.JSONSchemaValidationFailed{
               error: %JSONSchex.Types.Error{path: ["inner", "outer"]},
               path: "#/outer/inner"
             } = capture_validation_error(param, "body", "payload", %{"outer" => %{"inner" => "x"}})
    end

    test "nested arrays and objects are rendered root-first" do
      param = %{
        "schema" =>
          Oasis.Test.JSONSchema.compile!(%{
            "type" => "object",
            "properties" => %{
              "groups" => %{
                "type" => "array",
                "items" => %{
                  "type" => "object",
                  "properties" => %{
                    "names" => %{
                      "type" => "array",
                      "items" => %{"type" => "string", "minLength" => 5}
                    }
                  }
                }
              }
            }
          })
      }

      value = %{"groups" => [%{"names" => ["valid", "x"]}]}

      assert %Oasis.BadRequestError.JSONSchemaValidationFailed{path: "#/groups/0/names/1"} =
               capture_validation_error(param, "body", "payload", value)
    end

    test "escaped nested property names remain in root-first order" do
      param = %{
        "schema" =>
          Oasis.Test.JSONSchema.compile!(%{
            "type" => "object",
            "properties" => %{
              "a/b" => %{
                "type" => "object",
                "properties" => %{"~name" => %{"type" => "string", "minLength" => 10}}
              }
            }
          })
      }

      assert %Oasis.BadRequestError.JSONSchemaValidationFailed{path: "#/a~1b/~0name"} =
               capture_validation_error(param, "body", "payload", %{"a/b" => %{"~name" => "invalid"}})
    end
  end

  defp capture_validation_error(param, use_in, name, value) do
    Validator.parse_and_validate!(param, use_in, name, value)
    flunk("expected Oasis.BadRequestError")
  rescue
    error in Oasis.BadRequestError -> error.error
  end

  test "simple type integer" do
    param = %{
      "required" => true,
      "schema" =>
        Oasis.Test.JSONSchema.compile!(%{"type" => "integer", "minimum" => 10, "maximum" => 20})
    }

    name = "test_name"

    assert_raise Oasis.BadRequestError,
                 ~r/Expected the value to be >= 10/,
                 fn -> Validator.parse_and_validate!(param, "query", name, "1") end

    assert Validator.parse_and_validate!(param, "query", name, "10") == 10
    assert Validator.parse_and_validate!(param, "query", name, "20") == 20

    assert_raise Oasis.BadRequestError,
                 ~r/Expected the value to be <= 20/,
                 fn -> Validator.parse_and_validate!(param, "query", name, "21") end

    assert_raise Oasis.BadRequestError,
                 ~r/Missing a required parameter/,
                 fn -> Validator.parse_and_validate!(param, "query", name, nil) end

    param = Map.put(param, "required", false)
    assert Validator.parse_and_validate!(param, "query", name, "15") == 15
    assert Validator.parse_and_validate!(param, "query", name, nil) == nil
  end

  test "coerces path, query, header, and cookie values through schema refs" do
    schema =
      Oasis.Test.JSONSchema.compile!(%{
        "$defs" => %{"Integer" => %{"type" => "integer"}},
        "$ref" => "#/$defs/Integer"
      })

    for location <- ["path", "query", "header", "cookie"] do
      param = %{"required" => true, "schema" => schema}

      assert Validator.parse_and_validate!(param, location, "id", "123") == 123
    end
  end

  test "does not infer primitive JSON root provenance from an _json-shaped map" do
    schema =
      Oasis.Test.JSONSchema.compile!(%{
        "type" => ["object", "integer"],
        "required" => ["guard"],
        "properties" => %{"guard" => %{"const" => "ok"}},
        "additionalProperties" => false
      })

    param = %{
      "content" => %{"application/json" => %{"schema" => schema}},
      "required" => true
    }

    assert_raise Oasis.BadRequestError, ~r/Required property guard was not present/, fn ->
      Validator.parse_and_validate!(param, "body", "requestBody", %{"_json" => 123})
    end
  end

  test "coerces form and multipart properties through schema refs" do
    schema =
      Oasis.Test.JSONSchema.compile!(%{
        "$defs" => %{"Integer" => %{"type" => "integer"}},
        "type" => "object",
        "properties" => %{"count" => %{"$ref" => "#/$defs/Integer"}}
      })

    for content_type <- ["application/x-www-form-urlencoded", "multipart/form-data"] do
      param = %{"content" => %{content_type => %{"schema" => schema}}}

      assert Validator.parse_and_validate!(param, "body", "requestBody", %{"count" => "123"}) == %{
               "count" => 123
             }
    end
  end

  test "coerces nested and dynamic object locations through compiled schema refs" do
    integer_ref = %{"$ref" => "#/$defs/Integer"}

    cases = [
      {
        %{
          "type" => "object",
          "properties" => %{
            "outer" => %{"type" => "object", "properties" => %{"count" => integer_ref}}
          }
        },
        %{"outer" => %{"count" => "123"}},
        %{"outer" => %{"count" => 123}}
      },
      {
        %{
          "type" => "array",
          "items" => %{"type" => "object", "properties" => %{"count" => integer_ref}}
        },
        [%{"count" => "123"}],
        [%{"count" => 123}]
      },
      {
        %{"type" => "object", "patternProperties" => %{"^n" => integer_ref}},
        %{"n1" => "123"},
        %{"n1" => 123}
      },
      {
        %{"type" => "object", "additionalProperties" => integer_ref},
        %{"count" => "123"},
        %{"count" => 123}
      },
      {
        %{
          "type" => "object",
          "properties" => %{"trigger" => %{"type" => "string"}},
          "dependentSchemas" => %{
            "trigger" => %{"properties" => %{"count" => integer_ref}}
          }
        },
        %{"trigger" => "yes", "count" => "123"},
        %{"trigger" => "yes", "count" => 123}
      }
    ]

    for {body, input, expected} <- cases do
      schema =
        body
        |> Map.put("$defs", %{"Integer" => %{"type" => "integer"}})
        |> Oasis.Test.JSONSchema.compile!()

      assert Validator.parse_and_validate!(%{"schema" => schema}, "query", "value", input) == expected
    end
  end

  test "coerces direct unevaluated properties and items through refs" do
    object_schema =
      Oasis.Test.JSONSchema.compile!(%{
        "$defs" => %{"Integer" => %{"type" => "integer"}},
        "type" => "object",
        "unevaluatedProperties" => %{"$ref" => "#/$defs/Integer"}
      })

    assert Validator.parse_and_validate!(
             %{"schema" => object_schema},
             "query",
             "value",
             %{"extra" => "12"}
           ) == %{"extra" => 12}

    array_schema =
      Oasis.Test.JSONSchema.compile!(%{
        "$defs" => %{"Integer" => %{"type" => "integer"}},
        "type" => "array",
        "unevaluatedItems" => %{"$ref" => "#/$defs/Integer"}
      })

    assert Validator.parse_and_validate!(%{"schema" => array_schema}, "query", "value", ["12"]) == [12]
  end

  test "does not apply inactive dependent schemas during coercion" do
    schema =
      Oasis.Test.JSONSchema.compile!(%{
        "$defs" => %{"Integer" => %{"type" => "integer"}},
        "type" => "object",
        "dependentSchemas" => %{
          "trigger" => %{
            "properties" => %{"count" => %{"$ref" => "#/$defs/Integer"}}
          }
        }
      })

    assert Validator.parse_and_validate!(
             %{"schema" => schema},
             "query",
             "value",
             %{"count" => "123"}
           ) == %{"count" => "123"}
  end

  test "does not let a failing coercion branch abort a valid string branch" do
    for keyword <- ["anyOf", "oneOf"] do
      schema =
        Oasis.Test.JSONSchema.compile!(%{
          keyword => [%{"type" => "integer"}, %{"type" => "string"}]
        })

      assert Validator.parse_and_validate!(%{"schema" => schema}, "query", "value", "abc") == "abc"
    end
  end

  test "coerces unambiguous anyOf, oneOf, and nullable scalar types" do
    for keyword <- ["anyOf", "oneOf"] do
      schema =
        Oasis.Test.JSONSchema.compile!(%{
          keyword => [%{"type" => "integer"}, %{"type" => "boolean"}]
        })

      assert Validator.parse_and_validate!(%{"schema" => schema}, "query", "value", "123") == 123
    end

    nullable = Oasis.Test.JSONSchema.compile!(%{"type" => ["integer", "null"]})
    assert Validator.parse_and_validate!(%{"schema" => nullable}, "query", "value", "123") == 123

    numeric = Oasis.Test.JSONSchema.compile!(%{"type" => ["integer", "number"]})
    assert Validator.parse_and_validate!(%{"schema" => numeric}, "query", "value", "123") == 123
  end

  test "simple type number" do
    param = %{
      "required" => true,
      "schema" =>
        Oasis.Test.JSONSchema.compile!(%{"type" => "number"})
    }

    name = "test_float"
    assert Validator.parse_and_validate!(param, "path", name, "10") == 10.0

    assert_raise Oasis.BadRequestError,
                 ~r/Failed to convert parameter/,
                 fn -> Validator.parse_and_validate!(param, "path", name, "10.0xyz") end

    assert Validator.parse_and_validate!(param, "path", name, "10.001") == 10.001
  end

  test "simple type string" do
    param = %{
      "required" => true,
      "schema" =>
        Oasis.Test.JSONSchema.compile!(%{"type" => "string", "minLength" => 3, "maxLength" => 6})
    }

    name = "test_str"

    assert_raise Oasis.BadRequestError,
                 ~r/Expected value to have a minimum length of 3 but was 1/,
                 fn -> Validator.parse_and_validate!(param, "header", name, "a") end

    assert Validator.parse_and_validate!(param, "header", name, "abcdef") == "abcdef"
  end

  test "simple type string format" do
    param = %{
      "required" => true,
      "schema" =>
        Oasis.Test.JSONSchema.compile!(
          %{
            "type" => "string",
            "pattern" => "^(\\([0-9]{3}\\))?[0-9]{3}-[0-9]{4}$",
            "maxLength" => 12
          })
    }

    name = "test_str"
    assert Validator.parse_and_validate!(param, "header", name, "555-1212") == "555-1212"

    assert_raise Oasis.BadRequestError,
                 ~r/Expected value to have a maximum length of 12 but was 13/,
                 fn -> Validator.parse_and_validate!(param, "header", name, "(888)555-1212") end

    assert_raise Oasis.BadRequestError, ~r/Does not match pattern/, fn ->
      Validator.parse_and_validate!(param, "header", name, "(800)FLOWERS")
    end

    param = %{
      "required" => true,
      "schema" =>
        Oasis.Test.JSONSchema.compile!(%{"type" => "string", "format" => "email"})
    }

    assert Validator.parse_and_validate!(param, "header", name, "test@test.com") ==
             "test@test.com"

    assert_raise Oasis.BadRequestError, ~r/Expected to be a valid email/, fn ->
      Validator.parse_and_validate!(param, "header", name, "test")
    end

    # JSONSchex follows the email format grammar and accepts a dotless domain.
    # Oasis must not apply a second, stricter application-specific regex.
    assert Validator.parse_and_validate!(param, "header", name, "test@test") == "test@test"
  end

  test "simple type string enum" do
    param = %{
      "required" => true,
      "schema" =>
        Oasis.Test.JSONSchema.compile!(%{"type" => "string", "enum" => ["A", "B", "C"]})
    }

    name = "test_enum"
    Validator.parse_and_validate!(param, "path", name, "A")

    assert_raise Oasis.BadRequestError, ~r/Value is not allowed in enum/, fn ->
      Validator.parse_and_validate!(param, "path", name, "D")
    end
  end

  test "simple type boolean" do
    param = %{
      "required" => true,
      "schema" =>
        Oasis.Test.JSONSchema.compile!(%{"type" => "boolean"})
    }

    name = "test_str"
    assert Validator.parse_and_validate!(param, "header", name, "true") == true
    assert Validator.parse_and_validate!(param, "header", name, "false") == false

    assert_raise Oasis.BadRequestError, ~r/Expected Boolean but got String/, fn ->
      Validator.parse_and_validate!(param, "header", name, "True")
    end

    assert_raise Oasis.BadRequestError, ~r/Expected Boolean but got Integer/, fn ->
      Validator.parse_and_validate!(param, "path", name, 0)
    end
  end

  test "simple type null" do
    param = %{
      "required" => false,
      "schema" =>
        Oasis.Test.JSONSchema.compile!(%{"type" => "null"})
    }

    name = "test_null"
    assert Validator.parse_and_validate!(param, "cookie", name, nil) == nil

    assert_raise Oasis.BadRequestError, ~r/Type mismatch. Expected Null but got String/, fn ->
      Validator.parse_and_validate!(param, "cookie", name, "1")
    end
  end

  test "type array items" do
    param = %{
      "required" => true,
      "schema" =>
        Oasis.Test.JSONSchema.compile!(%{"type" => "array", "items" => %{"type" => "integer"}})
    }

    name = "test_array"
    data = [1, 2, 3]
    input = Jason.encode!(data)
    assert Validator.parse_and_validate!(param, "header", name, input) == data
  end

  test "prefixItems coercion permits short arrays and applies items to the typed tail" do
    schema =
      Oasis.Test.JSONSchema.compile!(%{
        "type" => "array",
        "prefixItems" => [%{"type" => "integer"}, %{"type" => "string"}],
        "items" => %{"type" => "integer"}
      })

    param = %{"schema" => schema}

    assert Validator.parse_and_validate!(param, "query", "tuple", ["10"]) == [10]

    assert Validator.parse_and_validate!(param, "query", "tuple", ["10", "name", "20", "30"]) == [
             10,
             "name",
             20,
             30
           ]
  end

  test "type array tuple validation" do
    param = %{
      "required" => true,
      "schema" =>
        Oasis.Test.JSONSchema.compile!(
          %{
            "type" => "array",
            "prefixItems" => [
              %{"type" => "integer"},
              %{"type" => "string"},
              %{"type" => "string", "enum" => ["Street", "Avenue", "Boulevard"]},
              %{"type" => "string", "enum" => ["NW", "NE", "SW", "SE"]}
            ],
            "items" => true
          })
    }

    name = "test_array"
    data = [1600, "Pennsylvania", "Avenue", "NW"]
    input = Jason.encode!(data)
    assert Validator.parse_and_validate!(param, "header", name, input) == data
    data = [10, "Downing", "Street"]
    input = Jason.encode!(data)
    assert Validator.parse_and_validate!(param, "header", name, input) == data
    data = [1600, "Pennsylvania", "Avenue", "NW", "Washington"]
    input = Jason.encode!(data)
    assert Validator.parse_and_validate!(param, "path", name, input) == data
    data = ["a", "b", "c", "Sussex", "Drive"]
    input = Jason.encode!(data)

    assert_raise Oasis.BadRequestError, ~r/Failed to convert parameter/, fn ->
      Validator.parse_and_validate!(param, "query", name, input)
    end

    data = [1600, "Pennsylvania", "Avenue", "NW", "Washington"]
    input = Jason.encode!(data)
    assert Validator.parse_and_validate!(param, "query", name, input) == data

    param = %{
      "required" => true,
      "schema" =>
        Oasis.Test.JSONSchema.compile!(
          %{
            "type" => "array",
            "prefixItems" => [
              %{"type" => "integer"},
              %{"type" => "string"},
              %{"type" => "string", "enum" => ["Street", "Avenue", "Boulevard"]},
              %{"type" => "string", "enum" => ["NW", "NE", "SW", "SE"]}
            ],
            "items" => %{"type" => "string"}
          })
    }

    name = "test_array"
    data = [1600, "Pennsylvania", "Avenue", "NW", "Washington"]
    input = Jason.encode!(data)
    assert Validator.parse_and_validate!(param, "query", name, input) == data
    data = [1600, "Pennsylvania", "Avenue", "NW", 1000]
    input = Jason.encode!(data)

    assert_raise Oasis.BadRequestError, ~r/Type mismatch. Expected String but got Integer/, fn ->
      Validator.parse_and_validate!(param, "query", name, input)
    end

    param = %{
      "required" => false,
      "schema" =>
        Oasis.Test.JSONSchema.compile!(%{"type" => "array", "minItems" => 2, "maxItems" => 3})
    }

    name = "test_name"
    data = []
    input = Jason.encode!(data)

    assert_raise Oasis.BadRequestError, ~r/Expected a minimum of 2 items but got 0/, fn ->
      Validator.parse_and_validate!(param, "query", name, input)
    end

    data = [1, 2]
    input = Jason.encode!(data)
    assert Validator.parse_and_validate!(param, "query", name, input) == data
    data = [3, 2, 1]
    input = Jason.encode!(data)
    assert Validator.parse_and_validate!(param, "query", name, input) == data
    data = [1, 2, 3, 4, 5]
    input = Jason.encode!(data)

    assert_raise Oasis.BadRequestError, ~r/Expected a maximum of 3 items but got 5/, fn ->
      Validator.parse_and_validate!(param, "query", name, input)
    end

    param = %{
      "required" => false,
      "schema" =>
        Oasis.Test.JSONSchema.compile!(
          %{"type" => "array", "uniqueItems" => true, "items" => %{"type" => "integer"}})
    }

    name = "test_name"
    data = [1, 2, 3, 4]
    input = Jason.encode!(data)
    assert Validator.parse_and_validate!(param, "query", name, input) == data
    data = [1, 2, 3, 2, 4]
    input = Jason.encode!(data)

    assert_raise Oasis.BadRequestError, ~r/Expected items to be unique but they were not/, fn ->
      Validator.parse_and_validate!(param, "query", name, input)
    end
  end

  test "type object properties" do
    param = %{
      "required" => true,
      "schema" =>
        Oasis.Test.JSONSchema.compile!(
          %{
            "type" => "object",
            "properties" => %{
              "number" => %{"type" => "number"},
              "street_name" => %{"type" => "string"},
              "street_type" => %{"type" => "string", "enum" => ["Street", "Avenue", "Boulevard"]}
            }
          })
    }

    name = "test_array"
    data = %{"number" => 100}
    input = Jason.encode!(data)
    assert Validator.parse_and_validate!(param, "query", name, input) == data
    data = %{"number" => 100, "street_name" => "abc", "street_type" => "Avenue"}
    input = Jason.encode!(data)
    assert Validator.parse_and_validate!(param, "query", name, input) == data

    data = %{
      "number" => 100,
      "street_name" => "abc",
      "street_type" => "Avenue",
      "addition" => 2021
    }

    input = Jason.encode!(data)
    assert Validator.parse_and_validate!(param, "query", name, input) == data
    data = %{"number" => "100", "street_name" => "abc", "street_type" => 1}
    input = Jason.encode!(data)

    assert_raise Oasis.BadRequestError, ~r/Type mismatch. Expected String but got Integer/, fn ->
      Validator.parse_and_validate!(param, "query", name, input)
    end
  end

  test "type object required properties" do
    param = %{
      "required" => true,
      "schema" =>
        Oasis.Test.JSONSchema.compile!(
          %{
            "type" => "object",
            "properties" => %{
              "number" => %{"type" => "number"},
              "street_name" => %{"type" => "string"},
              "street_type" => %{"type" => "string", "enum" => ["Street", "Avenue", "Boulevard"]}
            },
            "required" => ["number", "street_name"]
          })
    }

    name = "test_array"
    data = %{"number" => 1, "street_type" => "Street"}
    input = Jason.encode!(data)

    assert_raise Oasis.BadRequestError, ~r/Required property street_name was not present/, fn ->
      Validator.parse_and_validate!(param, "query", name, input)
    end

    data = %{"number" => 1, "street_name" => "test street name"}
    input = Jason.encode!(data)
    assert Validator.parse_and_validate!(param, "query", name, input) == data
  end

  test "type object property dependencies" do
    schema = %{
      "type" => "object",
      "properties" => %{
        "name" => %{"type" => "string"},
        "credit_card" => %{"type" => "number"},
        "billing_address" => %{"type" => "string"}
      },
      "required" => ["name"],
      "dependencies" => %{
        "credit_card" => ["billing_address"],
        "billing_address" => ["credit_card"]
      }
    }

    param = %{
      "required" => true,
      "schema" =>
        Oasis.Test.JSONSchema.compile!(schema)
    }

    name = "test"

    data = %{
      "name" => "test_name",
      "credit_card" => 111_111_111_111,
      "billing_address" => "100 street"
    }

    input = Jason.encode!(data)
    assert Validator.parse_and_validate!(param, "query", name, input) == data
    data = %{"name" => "test_name"}
    input = Jason.encode!(data)
    assert Validator.parse_and_validate!(param, "query", name, input) == data
    data = %{"name" => "test_name", "credit_card" => 111_111_111_111}
    input = Jason.encode!(data)

    assert_raise Oasis.BadRequestError,
                 ~r/Property credit_card depends on property billing_address to be present but it was not/,
                 fn -> Validator.parse_and_validate!(param, "query", name, input) end

    data = %{"name" => "test_name", "billing_address" => "100 street"}
    input = Jason.encode!(data)

    assert_raise Oasis.BadRequestError,
                 ~r/Property billing_address depends on property credit_card to be present but it was not/,
                 fn -> Validator.parse_and_validate!(param, "query", name, input) end
  end

  test "type object pattern properties" do
    schema = %{
      "type" => "object",
      "patternProperties" => %{"^S_" => %{"type" => "string"}, "^I_" => %{"type" => "integer"}},
      "properties" => %{},
      "additionalProperties" => false
    }

    param = %{
      "required" => true,
      "schema" =>
        Oasis.Test.JSONSchema.compile!(schema)
    }

    name = "test"
    data = %{"S_25" => "test string"}
    input = Jason.encode!(data)
    assert Validator.parse_and_validate!(param, "query", name, input) == data
    data = %{"I_0" => 0}
    input = Jason.encode!(data)
    assert Validator.parse_and_validate!(param, "query", name, input) == data
    data = %{"S_0" => 0}
    input = Jason.encode!(data)

    assert_raise Oasis.BadRequestError, ~r/Type mismatch. Expected String but got Integer/, fn ->
      Validator.parse_and_validate!(param, "query", name, input)
    end

    data = %{"I_1" => "1"}
    input = Jason.encode!(data)

    assert Validator.parse_and_validate!(param, "query", name, input) == %{"I_1" => 1}

    schema = %{
      "type" => "object",
      "patternProperties" => %{"^S_" => %{"type" => "string"}, "^I_" => %{"type" => "integer"}},
      "properties" => %{"builtin" => %{"type" => "integer"}},
      "additionalProperties" => %{"type" => "string"}
    }

    param = %{
      "required" => true,
      "schema" =>
        Oasis.Test.JSONSchema.compile!(schema)
    }

    data = %{"builtin" => 1}
    name = "test"
    value = Jason.encode!(data)
    assert Validator.parse_and_validate!(param, "query", name, value) == data
    data = %{"I_25" => 0, "builtin" => 1}
    value = Jason.encode!(data)
    assert Validator.parse_and_validate!(param, "query", name, value) == data
    data = %{"I_25" => 0, "builtin" => 1, "otherfield" => "string"}
    value = Jason.encode!(data)
    assert Validator.parse_and_validate!(param, "query", name, value) == data
    data = %{"S_25" => 0, "builtin" => 1, "otherfield" => "string"}
    value = Jason.encode!(data)

    assert_raise Oasis.BadRequestError, ~r/Type mismatch. Expected String but got Integer/, fn ->
      Validator.parse_and_validate!(param, "query", name, value) == data
    end

    data = %{"I_25" => 0, "builtin" => 1, "otherfield" => 1}
    value = Jason.encode!(data)

    assert_raise Oasis.BadRequestError, ~r/Type mismatch. Expected String but got Integer/, fn ->
      Validator.parse_and_validate!(param, "query", name, value)
    end

    data = %{"otherfield" => 1}
    value = Jason.encode!(data)

    assert_raise Oasis.BadRequestError, ~r/Type mismatch. Expected String but got Integer/, fn ->
      Validator.parse_and_validate!(param, "query", name, value)
    end
  end

  test "content type application/vnd.github+json" do
    param = %{
      "required" => true,
      "content" => %{
        "application/vnd.github+json" => %{
          "schema" =>
            Oasis.Test.JSONSchema.compile!(
              %{
                "properties" => %{"name" => %{"type" => "number"}, "tag" => %{"type" => "number"}},
                "required" => ["lat", "long"],
                "type" => "object"
              })
        }
      }
    }

    name = "local"
    data = %{"lat" => 12.01, "long" => 93.1}
    formatted = Validator.parse_and_validate!(param, "header", name, Jason.encode!(data))
    assert formatted == data
    data = %{"lat" => 43.21}

    assert_raise Oasis.BadRequestError, ~r/Required property long was not present./, fn ->
      Validator.parse_and_validate!(param, "header", name, Jason.encode!(data))
    end
  end

  test "content type application/xml" do
    param = %{
      "required" => true,
      "content" => %{
        "application/xml" => %{
          "schema" =>
            Oasis.Test.JSONSchema.compile!(
              %{
                "properties" => %{
                  "id" => %{"type" => "integer"},
                  "title" => %{"type" => "string"},
                  "author" => %{"type" => "string"}
                },
                "required" => ["id", "title", "author"],
                "type" => "object"
              })
        }
      }
    }

    name = "book"
    data = "<book><id>0</id><title>str</title><author>str</author></book>"
    formatted = Validator.parse_and_validate!(param, "header", name, data)
    assert formatted == data
    data = "<book><id>str</id><title>str</title><author>str</author></book>"
    formatted = Validator.parse_and_validate!(param, "header", name, data)
    assert formatted == data
  end

  test "content text/plain" do
    param = %{
      "required" => true,
      "content" => %{
        "text/plain" => %{
          "schema" =>
            Oasis.Test.JSONSchema.compile!(%{"type" => "array", "items" => %{"type" => "string"}})
        }
      }
    }

    name = "test_name"
    data = ["1", "2", "3"]
    input = Jason.encode!(data)
    formatted_value = Validator.parse_and_validate!(param, "query", name, input)
    assert formatted_value == data
  end

  test "content text/plain; charset=utf-8" do
    param = %{
      "required" => true,
      "content" => %{
        "text/plain; charset=utf-8" => %{
          "schema" =>
            Oasis.Test.JSONSchema.compile!(%{"type" => "array", "items" => %{"type" => "integer"}})
        }
      }
    }

    name = "test_name"
    data = [1, 2, 3]
    input = Jason.encode!(data)
    formatted_value = Validator.parse_and_validate!(param, "query", name, input)
    assert formatted_value == data
  end

  test "content image/png" do
    param = %{
      "content" => %{
        "image/png" => %{
          "schema" =>
            Oasis.Test.JSONSchema.compile!(
              %{
                "type" => "string",
                "contentMediaType" => "image/png",
                "contentEncoding" => "base64"
              })
        }
      }
    }

    name = "image"
    input = "image_binary"
    formatted_value = Validator.parse_and_validate!(param, "query", name, input)
    assert input == formatted_value
  end

  test "content application/json" do
    param = %{
      "required" => true,
      "content" => %{
        "application/json; charset=utf-8" => %{
          "schema" =>
            Oasis.Test.JSONSchema.compile!(
              %{"type" => "object", "properties" => %{"name" => %{"type" => "string"}}})
        }
      }
    }

    assert_raise Oasis.BadRequestError,
                 ~r/Type mismatch. Expected String but got Integer/,
                 fn -> Validator.parse_and_validate!(param, "body", "name", %{"name" => 1}) end

    valid_value = %{"name" => "hello"}
    assert Validator.parse_and_validate!(param, "body", "name", valid_value) == valid_value
    content = param["content"]
    content = %{"application/json" => content["application/json; charset=utf-8"]}
    param_without_charset = Map.put(param, "content", content)

    assert_raise Oasis.BadRequestError,
                 ~r/Type mismatch. Expected String but got Integer/,
                 fn ->
                   Validator.parse_and_validate!(param_without_charset, "body", "name", %{
                     "name" => 1
                   })
                 end
  end

  test "invalid json" do
    param = %{
      "schema" =>
        Oasis.Test.JSONSchema.compile!(%{"type" => "array", "items" => %{"type" => "string"}})
    }

    name = "name"
    input = "invalid_json"

    assert_raise Oasis.BadRequestError,
                 ~r/Failed to convert parameter/,
                 fn -> Validator.parse_and_validate!(param, "query", name, input) end
  end

  test "unknown schema type raises schema compile error" do
    assert_raise ArgumentError,
                 ~r/Keyword 'type' must be one of/,
                 fn ->
                   Oasis.Test.JSONSchema.compile!(%{"type" => "UNKNOWN_JSON_SCHEMA"})
                 end
  end

  test "content form-urlencoded" do
    param = %{
      "content" => %{
        "application/x-www-form-urlencoded" => %{
          "schema" =>
            Oasis.Test.JSONSchema.compile!(
              %{
                "properties" => %{
                  "fav_number" => %{"type" => "integer"},
                  "name" => %{"type" => "string"}
                },
                "required" => ["name", "fav_number"],
                "type" => "object"
              })
        }
      },
      "required" => true
    }

    invalid_input = %{"key" => "value"}

    assert_raise Oasis.BadRequestError,
                 ~r/Required properties name, fav_number were not present./,
                 fn ->
                   Validator.parse_and_validate!(param, "body", "body_request", invalid_input)
                 end

    input = %{"fav_number" => 1, "name" => "test_name"}
    result = Validator.parse_and_validate!(param, "body", "body_request", input)
    assert result == %{"fav_number" => 1, "name" => "test_name"}
    content = param["content"]

    content = %{
      "application/x-www-form-urlencoded; charset=utf-8" =>
        content["application/x-www-form-urlencoded"]
    }

    param_with_charset = Map.put(param, "content", content)

    assert_raise Oasis.BadRequestError,
                 ~r/Required properties name, fav_number were not present./,
                 fn ->
                   Validator.parse_and_validate!(
                     param_with_charset,
                     "body",
                     "body_request",
                     invalid_input
                   )
                 end
  end

  test "invalid definition to be ignored" do
    param = %{"required" => true}
    input = "value"
    name = "username"
    assert Validator.parse_and_validate!(param, "query", name, input) == input
    input = Jason.encode(%{"a" => 1, "b" => 2})
    assert Validator.parse_and_validate!(param, "query", name, input) == input
  end

  test "parse empty map" do
    type = %{
      "content" => %{
        "application/json" => %{
          "schema" =>
            Oasis.Test.JSONSchema.compile!(
              %{
                "properties" => %{"refresh_token" => %{"type" => "string"}},
                "required" => ["refresh_token"],
                "type" => "object"
              })
        }
      },
      "required" => true
    }

    assert_raise Oasis.BadRequestError,
                 ~r/Required property refresh_token was not present/,
                 fn -> Validator.parse_and_validate!(type, "body", "requestBody", %{}) end
  end

  test "parse multipart/form-data with a file upload" do
    name = "requestBody"

    param = %{
      "content" => %{
        "multipart/form-data" => %{
          "schema" =>
            Oasis.Test.JSONSchema.compile!(
              %{
                "properties" => %{
                  "file" => %{"format" => "binary", "type" => "string"},
                  "id" => %{"type" => "integer", "maximum" => 10}
                },
                "required" => ["file"],
                "type" => "object"
              })
        }
      }
    }

    upload = %Plug.Upload{content_type: "image/png", filename: "test.png", path: "/var/tmp/path"}
    input = %{"file" => upload, "id" => "10"}
    parsed = Validator.parse_and_validate!(param, "body", name, input)
    assert parsed["id"] == 10
    assert parsed["file"] == upload
    input = %{"file" => upload, "id" => "100"}

    assert_raise Oasis.BadRequestError,
                 ~r/Failed to validate JSON schema with an error: Expected the value to be <= 10/,
                 fn -> Validator.parse_and_validate!(param, "body", name, input) end
  end

  test "multipart uploads require an explicit binary or byte string schema" do
    upload = %Plug.Upload{content_type: "image/png", filename: "test.png", path: "/var/tmp/path"}

    for schema <- [
          %{"type" => "string"},
          %{"type" => ["string", "null"], "format" => "email"},
          %{"type" => ["string", "null"], "minLength" => 1000}
        ] do
      param = %{
        "content" => %{
          "multipart/form-data" => %{
            "schema" =>
              Oasis.Test.JSONSchema.compile!(%{
                "type" => "object",
                "properties" => %{"file" => schema}
              })
          }
        }
      }

      assert_raise Oasis.BadRequestError, ~r/Type mismatch/, fn ->
        Validator.parse_and_validate!(param, "body", "requestBody", %{"file" => upload})
      end
    end

    binary_schema =
      Oasis.Test.JSONSchema.compile!(%{
        "type" => "object",
        "properties" => %{"file" => %{"type" => "string", "format" => "binary"}}
      })

    assert_raise Oasis.BadRequestError, ~r/Type mismatch/, fn ->
      Validator.parse_and_validate!(%{"schema" => binary_schema}, "query", "file", %{"file" => upload})
    end
  end

  test "multipart upload applicators are handled without suppressing conflicting branches" do
    upload = %Plug.Upload{content_type: "image/png", filename: "test.png", path: "/var/tmp/path"}

    any_of =
      Oasis.Test.JSONSchema.compile!(%{
        "type" => "object",
        "properties" => %{
          "file" => %{
            "anyOf" => [
              %{"type" => "string", "format" => "binary"},
              %{"const" => "fixed"}
            ]
          }
        }
      })

    param = %{"content" => %{"multipart/form-data" => %{"schema" => any_of}}}
    assert Validator.parse_and_validate!(param, "body", "requestBody", %{"file" => upload}) == %{"file" => upload}

    all_of =
      Oasis.Test.JSONSchema.compile!(%{
        "type" => "object",
        "properties" => %{
          "file" => %{
            "allOf" => [
              %{"type" => "string", "format" => "binary"},
              %{"type" => "integer"}
            ]
          }
        }
      })

    param = %{"content" => %{"multipart/form-data" => %{"schema" => all_of}}}

    assert_raise Oasis.BadRequestError, ~r/Type mismatch/, fn ->
      Validator.parse_and_validate!(param, "body", "requestBody", %{"file" => upload})
    end
  end

  test "parse multipart/form-data ignores binary string type errors for deeply nested uploads" do
    name = "requestBody"

    param = %{
      "content" => %{
        "multipart/form-data" => %{
          "schema" =>
            Oasis.Test.JSONSchema.compile!(%{
              "type" => "object",
              "properties" => %{
                "outer" => %{
                  "type" => "object",
                  "properties" => %{
                    "inner" => %{
                      "type" => "object",
                      "properties" => %{
                        "file" => %{"format" => "binary", "type" => ["string", "null"]}
                      }
                    }
                  }
                }
              }
            })
        }
      }
    }

    upload = %Plug.Upload{content_type: "image/png", filename: "test.png", path: "/var/tmp/path"}
    input = %{"outer" => %{"inner" => %{"file" => upload}}}

    assert Validator.parse_and_validate!(param, "body", name, input) == input
  end

  test "parse multipart/form-data with multiple files upload" do
    name = "requestBody"

    param = %{
      "content" => %{
        "multipart/form-data" => %{
          "schema" =>
            Oasis.Test.JSONSchema.compile!(
              %{"properties" => %{"file" => %{"items" => %{}, "type" => "array"}}})
        }
      }
    }

    upload1 = %Plug.Upload{
      content_type: "image/png",
      filename: "test1.png",
      path: "/var/tmp/path/1"
    }

    upload2 = %Plug.Upload{
      content_type: "image/png",
      filename: "test2.png",
      path: "/var/tmp/path/2"
    }

    input = %{"file" => [upload1, upload2]}
    parsed = Validator.parse_and_validate!(param, "body", name, input)
    assert parsed == input
  end
end
