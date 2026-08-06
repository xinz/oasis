defmodule Oasis.Spec.DocumentTest do
  use ExUnit.Case, async: true

  alias Oasis.Spec.Document

  describe "load/1" do
    test "unsupported extension returns Oasis.InvalidSpecError" do
      assert {:error, %Oasis.InvalidSpecError{message: message}} =
               Document.load("anything.txt")

      assert message =~ ~r/yml\/yaml or json format/
      assert message =~ "`.txt`"
    end

    test "missing file returns Oasis.FileNotFoundError" do
      path = Path.join(System.tmp_dir!(), "oasis_document_missing_#{System.unique_integer([:positive])}.json")
      refute File.exists?(path)

      assert {:error, %Oasis.FileNotFoundError{message: message}} = Document.load(path)
      assert message =~ inspect(path)
    end

    test "malformed YAML returns Oasis.InvalidSpecError with yaml parse message" do
      path = tmp_file("oasis_document_malformed", ".yaml", ":\n")
      on_exit(fn -> File.rm(path) end)

      assert {:error, %Oasis.InvalidSpecError{message: message}} = Document.load(path)
      assert message =~ ~r/Failed to parse yaml/
    end

    test "malformed JSON returns Oasis.InvalidSpecError with json parse message" do
      path = tmp_file("oasis_document_malformed", ".json", "not json")
      on_exit(fn -> File.rm(path) end)

      assert {:error, %Oasis.InvalidSpecError{message: message}} = Document.load(path)
      assert message =~ ~r/Failed to parse json/
    end
  end

  describe "load_external/1" do
    test "unsupported extension returns structured tuple" do
      assert {:error, {"unsupported_format", "anything.txt", ".txt"}} =
               Document.load_external("anything.txt")
    end

    test "missing file returns {\"missing_file\", path}" do
      path = Path.join(System.tmp_dir!(), "oasis_external_missing_#{System.unique_integer([:positive])}.yaml")
      refute File.exists?(path)

      assert {:error, {"missing_file", ^path}} = Document.load_external(path)
    end

    test "malformed YAML returns {\"yaml_parse_error\", path, msg}" do
      path = tmp_file("oasis_external_malformed", ".yaml", ":\n")
      on_exit(fn -> File.rm(path) end)

      assert {:error, {"yaml_parse_error", ^path, msg}} = Document.load_external(path)
      assert is_binary(msg)
    end

    test "malformed JSON returns {\"json_parse_error\", path}" do
      path = tmp_file("oasis_external_malformed", ".json", "not json")
      on_exit(fn -> File.rm(path) end)

      assert {:error, {"json_parse_error", ^path}} = Document.load_external(path)
    end

    test "loads percent-encoded file URIs and preserves their resource identity" do
      path = tmp_file("oasis external file", ".json", ~s({"type":"integer"}))
      on_exit(fn -> File.rm(path) end)
      uri = %URI{scheme: "file", path: path} |> URI.to_string()

      assert {:ok, %{document: %{"type" => "integer"}, base_uri: ^uri}} =
               Document.load_external(uri)
    end

    test "rejects non-schema external document roots" do
      path = tmp_file("oasis_external_list", ".json", "[1,2,3]")
      on_exit(fn -> File.rm(path) end)

      assert {:error, {"invalid_document", ^path, [1, 2, 3]}} =
               Document.load_external(path)
    end
  end

  defp tmp_file(prefix, ext, content) do
    path =
      Path.join(
        System.tmp_dir!(),
        "#{prefix}_#{System.unique_integer([:positive])}#{ext}"
      )

    File.write!(path, content)
    path
  end
end
