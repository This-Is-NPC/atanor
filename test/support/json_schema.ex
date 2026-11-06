defmodule Atanor.Test.JSONSchema do
  @moduledoc """
  A small JSON Schema validator for the OpenAPI document of the admin API
  (docs/openapi/admin.json). It supports `$ref` into the document, `type`,
  `enum`, `const`, `pattern`, `minimum`, `minLength`, `maxLength`, `minItems`,
  `properties`, `required`, `items`, `allOf` and `oneOf`; other keywords
  (descriptions, examples, formats) are annotations.
  """

  @doc "Validates `value` against `schema`; returns `:ok` or the list of problems."
  @spec validate(map, term, map) :: :ok | {:error, [String.t()]}
  def validate(document, schema, value) do
    case check(document, schema, value, "$") do
      [] -> :ok
      problems -> {:error, problems}
    end
  end

  defp check(doc, %{"$ref" => "#/" <> path}, value, at) do
    check(doc, get_in(doc, String.split(path, "/")), value, at)
  end

  defp check(doc, schema, value, at) do
    Enum.flat_map(schema, fn {keyword, arg} -> keyword(doc, keyword, arg, value, at) end)
  end

  defp keyword(_doc, "type", type, value, at) do
    if Enum.any?(List.wrap(type), &type?(&1, value)),
      do: [],
      else: ["#{at}: expected #{inspect(type)}, got #{inspect(value)}"]
  end

  defp keyword(_doc, "enum", values, value, at),
    do: if(value in values, do: [], else: ["#{at}: #{inspect(value)} is not one of #{inspect(values)}"])

  defp keyword(_doc, "const", const, value, at),
    do: if(value == const, do: [], else: ["#{at}: expected #{inspect(const)}, got #{inspect(value)}"])

  defp keyword(_doc, "pattern", pattern, value, at) when is_binary(value),
    do:
      if(Regex.match?(Regex.compile!(pattern), value),
        do: [],
        else: ["#{at}: #{inspect(value)} does not match #{pattern}"]
      )

  defp keyword(_doc, "minimum", min, value, at) when is_number(value),
    do: if(value >= min, do: [], else: ["#{at}: #{value} is below #{min}"])

  defp keyword(_doc, "minLength", min, value, at) when is_binary(value),
    do: if(String.length(value) >= min, do: [], else: ["#{at}: shorter than #{min}"])

  defp keyword(_doc, "maxLength", max, value, at) when is_binary(value),
    do: if(String.length(value) <= max, do: [], else: ["#{at}: longer than #{max}"])

  defp keyword(_doc, "minItems", min, value, at) when is_list(value),
    do: if(length(value) >= min, do: [], else: ["#{at}: fewer than #{min} items"])

  defp keyword(doc, "properties", props, value, at) when is_map(value) do
    for {name, schema} <- props,
        Map.has_key?(value, name),
        problem <- check(doc, schema, value[name], "#{at}.#{name}"),
        do: problem
  end

  defp keyword(_doc, "required", names, value, at) when is_map(value),
    do: for(name <- names, not Map.has_key?(value, name), do: "#{at}: missing #{name}")

  defp keyword(doc, "items", schema, value, at) when is_list(value) do
    for {item, i} <- Enum.with_index(value), problem <- check(doc, schema, item, "#{at}[#{i}]"), do: problem
  end

  defp keyword(doc, "allOf", schemas, value, at), do: Enum.flat_map(schemas, &check(doc, &1, value, at))

  defp keyword(doc, "oneOf", schemas, value, at) do
    case Enum.count(schemas, &(check(doc, &1, value, at) == [])) do
      1 -> []
      n -> ["#{at}: matches #{n} of the oneOf schemas: #{inspect(value)}"]
    end
  end

  defp keyword(_doc, _annotation, _arg, _value, _at), do: []

  defp type?("object", v), do: is_map(v)
  defp type?("array", v), do: is_list(v)
  defp type?("string", v), do: is_binary(v)
  defp type?("integer", v), do: is_integer(v)
  defp type?("number", v), do: is_number(v)
  defp type?("boolean", v), do: is_boolean(v)
  defp type?("null", v), do: is_nil(v)
end
