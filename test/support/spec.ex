defmodule Oasis.Test.Support.Spec do
  alias Oasis.Spec.Document

  def yaml_to_json_schema(yaml_str) do
    {:ok, data} = YamlElixir.read_from_string(yaml_str)
    Document.new(data)
  end
end
