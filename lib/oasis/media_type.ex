defmodule Oasis.MediaType do
  @moduledoc false

  @type parsed :: %{
          type: String.t(),
          subtype: String.t(),
          params: %{optional(String.t()) => String.t()}
        }

  @spec parse_content_type(String.t() | nil) :: parsed() | nil
  def parse_content_type(value) when is_binary(value) do
    case Plug.Conn.Utils.content_type(value) do
      {:ok, type, subtype, params} -> %{type: type, subtype: subtype, params: params}
      :error -> nil
    end
  end

  def parse_content_type(_value), do: nil

  @spec parse_media_range(String.t() | nil) :: parsed() | nil
  def parse_media_range(value) when is_binary(value) do
    case Plug.Conn.Utils.media_type(value) do
      {:ok, type, subtype, params} -> %{type: type, subtype: subtype, params: params}
      :error -> nil
    end
  end

  def parse_media_range(_value), do: nil

  @spec json?(String.t() | parsed() | nil) :: boolean()
  def json?(value) when is_binary(value) do
    value
    |> parse_media_range()
    |> json?()
  end

  def json?(%{type: "application", subtype: subtype}) do
    subtype == "json" or String.ends_with?(subtype, "+json")
  end

  def json?(_value), do: false

  @spec parsers(String.t()) :: [:json | :multipart | :urlencoded]
  def parsers(value) do
    case parse_media_range(value) do
      %{type: "*", subtype: "*"} ->
        [:json, :multipart, :urlencoded]

      %{type: "application", subtype: "*"} ->
        [:json, :urlencoded]

      %{type: "multipart", subtype: "*"} ->
        [:multipart]

      %{type: "application", subtype: "x-www-form-urlencoded"} ->
        [:urlencoded]

      %{type: "multipart", subtype: subtype} when subtype in ["form-data", "mixed"] ->
        [:multipart]

      parsed when is_map(parsed) ->
        if json?(parsed), do: [:json], else: []

      nil ->
        []
    end
  end

  @spec validation_kind(String.t()) :: :json | :multipart | :form | :text | :unsupported
  def validation_kind(value) do
    case parse_media_range(value) do
      %{type: "application", subtype: "x-www-form-urlencoded"} ->
        :form

      %{type: "multipart", subtype: subtype} when subtype in ["form-data", "mixed"] ->
        :multipart

      %{type: "text", subtype: "plain"} ->
        :text

      parsed when is_map(parsed) ->
        if json?(parsed), do: :json, else: :unsupported

      nil ->
        :unsupported
    end
  end

  @doc false
  @spec select(map(), String.t() | nil) :: {String.t(), term()} | nil
  def select(content, request_content_type) when is_map(content) do
    with %{} = request <- parse_content_type(request_content_type) do
      content
      |> Enum.flat_map(fn {media_range, media_type} ->
        case parse_media_range(media_range) do
          %{} = parsed_range ->
            if matches?(parsed_range, request) do
              [{match_priority(parsed_range), media_range, media_type}]
            else
              []
            end

          nil ->
            []
        end
      end)
      |> Enum.sort_by(fn {priority, media_range, _media_type} -> {priority, media_range} end, :desc)
      |> case do
        [{_priority, media_range, media_type} | _rest] -> {media_range, media_type}
        [] -> nil
      end
    end
  end

  def select(_content, _request_content_type), do: nil

  defp matches?(range, request) do
    type_matches?(range.type, request.type) and
      subtype_matches?(range.subtype, request.subtype) and
      parameters_match?(range.params, request.params)
  end

  defp type_matches?("*", _request_type), do: true
  defp type_matches?(type, type), do: true
  defp type_matches?(_range_type, _request_type), do: false

  defp subtype_matches?("*", _request_subtype), do: true
  defp subtype_matches?(subtype, subtype), do: true
  defp subtype_matches?(_range_subtype, _request_subtype), do: false

  # Parameters declared by an OpenAPI media type key constrain the match. Extra
  # request parameters (for example, a charset) do not make a bare key fail.
  defp parameters_match?(declared, request) do
    Enum.all?(declared, fn
      {"charset", value} ->
        case Map.get(request, "charset") do
          request_value when is_binary(request_value) -> String.downcase(request_value) == String.downcase(value)
          nil -> false
        end

      {key, value} ->
        Map.get(request, key) == value
    end)
  end

  defp match_priority(range) do
    {
      if(range.type == "*", do: 0, else: 1),
      if(range.subtype == "*", do: 0, else: 1),
      map_size(range.params)
    }
  end
end
