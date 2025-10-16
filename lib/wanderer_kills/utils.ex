defmodule WandererKills.Utils do
  @moduledoc """
  Shared utility functions for the WandererKills application.
  """

  @doc """
  Safely navigates nested map structures to retrieve values.

  Takes a map, a path (list of keys), and an optional default value.
  Returns the value at the specified path or the default if any key
  in the path doesn't exist or if the value is nil.

  ## Examples

      iex> WandererKills.Utils.safe_get(%{a: %{b: %{c: 42}}}, [:a, :b, :c])
      42
      
      iex> WandererKills.Utils.safe_get(%{a: %{b: nil}}, [:a, :b, :c], "default")
      "default"
      
      iex> WandererKills.Utils.safe_get(nil, [:a, :b], "fallback")
      "fallback"
  """
  @spec safe_get(map() | nil, list(), any()) :: any()
  def safe_get(map, path, default \\ nil)
  def safe_get(nil, _path, default), do: default
  def safe_get(map, [], _default), do: map

  def safe_get(map, [key | rest], default) when is_map(map) do
    case Map.get(map, key) do
      nil -> default
      value -> safe_get(value, rest, default)
    end
  end

  def safe_get(_map, _path, default), do: default
end
