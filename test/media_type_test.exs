defmodule Oasis.MediaTypeTest do
  use ExUnit.Case, async: true

  alias Oasis.MediaType

  test "parses concrete content types and media ranges" do
    assert MediaType.parse_content_type("Application/Vnd.Oasis+JSON; charset=UTF-8") == %{
             type: "application",
             subtype: "vnd.oasis+json",
             params: %{"charset" => "UTF-8"}
           }

    assert MediaType.parse_media_range("application/*") == %{
             type: "application",
             subtype: "*",
             params: %{}
           }

    assert MediaType.parse_content_type("*/*") == nil
    assert MediaType.parse_content_type(nil) == nil
    assert MediaType.parse_media_range("invalid") == nil
    assert MediaType.parse_media_range(nil) == nil
  end

  test "classifies JSON media types" do
    assert MediaType.json?("application/json")
    assert MediaType.json?("application/problem+json; charset=utf-8")
    assert MediaType.json?(%{type: "application", subtype: "json", params: %{}})

    refute MediaType.json?("text/json")
    refute MediaType.json?("application/xml")
    refute MediaType.json?(nil)
  end

  test "selects Plug parsers for concrete and wildcard declarations" do
    assert MediaType.parsers("*/*") == [:json, :multipart, :urlencoded]
    assert MediaType.parsers("application/*") == [:json, :urlencoded]
    assert MediaType.parsers("multipart/*") == [:multipart]
    assert MediaType.parsers("application/x-www-form-urlencoded") == [:urlencoded]
    assert MediaType.parsers("multipart/form-data; boundary=x") == [:multipart]
    assert MediaType.parsers("multipart/mixed") == [:multipart]
    assert MediaType.parsers("application/vnd.api+json") == [:json]
    assert MediaType.parsers("Application/JSON") == [:json]

    for lookalike <- [
          "application/json-seq",
          "application/x-www-form-urlencoded-extra",
          "multipart/form-datax",
          "multipart/mixedness"
        ] do
      assert MediaType.parsers(lookalike) == []
    end

    assert MediaType.parsers("application/xml") == []
    assert MediaType.parsers("invalid") == []
  end

  test "classifies request validation behavior" do
    assert MediaType.validation_kind("application/json") == :json
    assert MediaType.validation_kind("application/vnd.api+json") == :json
    assert MediaType.validation_kind("application/x-www-form-urlencoded") == :form
    assert MediaType.validation_kind("multipart/form-data; boundary=x") == :multipart
    assert MediaType.validation_kind("multipart/mixed") == :multipart
    assert MediaType.validation_kind("text/plain; charset=utf-8") == :text
    assert MediaType.validation_kind("application/xml") == :unsupported
    assert MediaType.validation_kind("invalid") == :unsupported
  end

  test "selects the most specific matching OpenAPI media range" do
    content = %{
      "*/*" => :fallback,
      "application/*" => :application,
      "application/json" => :json
    }

    assert MediaType.select(content, "application/json; charset=utf-8") ==
             {"application/json", :json}

    assert MediaType.select(content, "application/xml") ==
             {"application/*", :application}

    assert MediaType.select(content, "text/plain") == {"*/*", :fallback}
  end

  test "matches declared parameters and treats charset values case-insensitively" do
    content = %{
      "application/json" => :bare,
      "application/json; charset=utf-8" => :utf8
    }

    assert MediaType.select(content, "application/json; charset=UTF-8") ==
             {"application/json; charset=utf-8", :utf8}

    assert MediaType.select(
             %{"multipart/form-data; boundary=expected" => :multipart},
             "multipart/form-data; boundary=other"
           ) == nil
  end

  test "returns nil for invalid or unavailable selections" do
    assert MediaType.select(%{"invalid" => :value}, "application/json") == nil
    assert MediaType.select(%{"application/json" => :value}, "invalid") == nil
    assert MediaType.select(:not_a_map, "application/json") == nil
  end
end
