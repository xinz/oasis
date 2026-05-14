defmodule Oasis.JSONTest do
  use ExUnit.Case

  test "encode! and decode roundtrip complex data" do
    data = %{
      "name" => "oasis",
      "tags" => ["openapi", "plug"],
      "count" => 2,
      "meta" => %{"active" => true, "note" => nil}
    }

    encoded = Oasis.JSON.encode!(data)

    assert is_binary(encoded) or is_list(encoded)
    assert {:ok, ^data} = Oasis.JSON.decode(encoded)
  end

  test "decode! roundtrip complex data" do
    data = %{"name" => "oasis", "count" => 2, "unicode" => "測試"}

    assert data
           |> Oasis.JSON.encode!()
           |> Oasis.JSON.decode!() == data
  end

  test "encode_to_iodata! returns decodable iodata" do
    data = %{"items" => [1, 2, 3], "ok" => true}

    iodata = Oasis.JSON.encode_to_iodata!(data)
    binary = IO.iodata_to_binary(iodata)

    assert is_binary(iodata) or is_list(iodata)
    assert {:ok, ^data} = Oasis.JSON.decode(binary)
    assert binary == Oasis.JSON.encode!(data)
  end

  test "decode accepts binary input" do
    binary = ~s({"name":"oasis","count":2})

    assert {:ok, %{"name" => "oasis", "count" => 2}} = Oasis.JSON.decode(binary)
  end

  test "decode returns error for invalid json" do
    assert {:error, _reason} = Oasis.JSON.decode("{invalid")
  end

  test "decode! raises for invalid json" do
    try do
      Oasis.JSON.decode!("{invalid")
      flunk("expected decode! to raise for invalid json")
    rescue
      error ->
        assert Exception.message(error) != ""
    end
  end

  test "encode! handles scalar values" do
    assert Oasis.JSON.encode!(true) == "true"
    assert Oasis.JSON.encode!(nil) == "null"
    assert Oasis.JSON.encode!(123) == "123"
    assert Oasis.JSON.decode!(Oasis.JSON.encode!("hello")) == "hello"
  end
end
