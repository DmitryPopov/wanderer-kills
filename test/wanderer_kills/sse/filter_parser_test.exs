defmodule WandererKills.SSE.FilterParserTest do
  use ExUnit.Case, async: true

  alias WandererKills.SSE.FilterParser
  alias WandererKills.Core.Support.Error

  describe "parse/1" do
    test "parses empty params to default filters" do
      assert {:ok, filters} = FilterParser.parse(%{})
      assert filters == %{system_ids: [], character_ids: [], min_value: nil, preload_days: 0}
    end

    test "parses system_ids correctly" do
      assert {:ok, filters} = FilterParser.parse(%{"system_ids" => "30000142,30000144"})
      assert filters.system_ids == [30_000_142, 30_000_144]
    end

    test "parses character_ids correctly" do
      assert {:ok, filters} = FilterParser.parse(%{"character_ids" => "123,456,789"})
      assert filters.character_ids == [123, 456, 789]
    end

    test "parses min_value as float" do
      assert {:ok, filters} = FilterParser.parse(%{"min_value" => "1000000.50"})
      assert filters.min_value == 1_000_000.50
    end

    test "parses min_value as integer" do
      assert {:ok, filters} = FilterParser.parse(%{"min_value" => "1000000"})
      assert filters.min_value == 1_000_000.0
    end

    test "handles empty strings as empty values" do
      assert {:ok, filters} =
               FilterParser.parse(%{
                 "system_ids" => "",
                 "character_ids" => "",
                 "min_value" => ""
               })

      assert filters == %{system_ids: [], character_ids: [], min_value: nil, preload_days: 0}
    end

    test "trims whitespace from IDs" do
      assert {:ok, filters} = FilterParser.parse(%{"system_ids" => " 30000142 , 30000144 "})
      assert filters.system_ids == [30_000_142, 30_000_144]
    end

    test "returns error for invalid system_ids" do
      assert {:error, %Error{type: :invalid_format}} =
               FilterParser.parse(%{"system_ids" => "abc,123"})
    end

    test "returns error for invalid character_ids" do
      assert {:error, %Error{type: :invalid_format}} =
               FilterParser.parse(%{"character_ids" => "123,invalid"})
    end

    test "returns error for negative min_value" do
      assert {:error, %Error{type: :invalid_format, message: message}} =
               FilterParser.parse(%{"min_value" => "-1000"})

      assert message =~ "must be non-negative"
    end

    test "returns error for invalid min_value" do
      assert {:error, %Error{type: :invalid_format}} =
               FilterParser.parse(%{"min_value" => "not_a_number"})
    end

    test "returns error for too many system_ids" do
      too_many = Enum.join(1..101, ",")

      assert {:error, %Error{type: :invalid_format, message: message}} =
               FilterParser.parse(%{"system_ids" => too_many})

      assert message =~ "Too many system_ids"
    end

    test "returns error for too many character_ids" do
      too_many = Enum.join(1..101, ",")

      assert {:error, %Error{type: :invalid_format, message: message}} =
               FilterParser.parse(%{"character_ids" => too_many})

      assert message =~ "Too many character_ids"
    end

    test "parses preload_days correctly" do
      assert {:ok, filters} = FilterParser.parse(%{"preload_days" => "30"})
      assert filters.preload_days == 30
    end

    test "caps preload_days at 90" do
      assert {:ok, filters} = FilterParser.parse(%{"preload_days" => "120"})
      assert filters.preload_days == 90
    end

    test "handles preload_days exactly at boundary (90)" do
      assert {:ok, filters} = FilterParser.parse(%{"preload_days" => "90"})
      assert filters.preload_days == 90
    end

    test "returns error for negative preload_days" do
      assert {:error, %Error{type: :invalid_format, message: message}} =
               FilterParser.parse(%{"preload_days" => "-5"})

      assert message =~ "must be non-negative"
    end

    test "returns error for invalid preload_days" do
      assert {:error, %Error{type: :invalid_format}} =
               FilterParser.parse(%{"preload_days" => "not_a_number"})
    end
  end

  describe "matches?/2" do
    setup do
      killmail = %{
        solar_system_id: 30_000_142,
        victim: %{character_id: 123_456},
        attackers: [
          %{character_id: 789_012},
          %{character_id: 345_678}
        ],
        zkb: %{total_value: 1_000_000.0}
      }

      {:ok, killmail: killmail}
    end

    test "matches when no filters specified", %{killmail: killmail} do
      filters = %{system_ids: [], character_ids: [], min_value: nil, preload_days: 0}
      assert FilterParser.matches?(killmail, filters)
    end

    test "matches by system_id", %{killmail: killmail} do
      filters = %{system_ids: [30_000_142], character_ids: [], min_value: nil, preload_days: 0}
      assert FilterParser.matches?(killmail, filters)

      filters = %{system_ids: [30_000_144], character_ids: [], min_value: nil, preload_days: 0}
      refute FilterParser.matches?(killmail, filters)
    end

    test "matches by victim character_id", %{killmail: killmail} do
      filters = %{system_ids: [], character_ids: [123_456], min_value: nil, preload_days: 0}
      assert FilterParser.matches?(killmail, filters)
    end

    test "matches by attacker character_id", %{killmail: killmail} do
      filters = %{system_ids: [], character_ids: [789_012], min_value: nil, preload_days: 0}
      assert FilterParser.matches?(killmail, filters)

      filters = %{system_ids: [], character_ids: [999_999], min_value: nil, preload_days: 0}
      refute FilterParser.matches?(killmail, filters)
    end

    test "matches by min_value", %{killmail: killmail} do
      filters = %{system_ids: [], character_ids: [], min_value: 500_000.0, preload_days: 0}
      assert FilterParser.matches?(killmail, filters)

      filters = %{system_ids: [], character_ids: [], min_value: 2_000_000.0, preload_days: 0}
      refute FilterParser.matches?(killmail, filters)
    end

    test "matches with combined filters", %{killmail: killmail} do
      filters = %{
        system_ids: [30_000_142],
        character_ids: [123_456],
        min_value: 500_000.0,
        preload_days: 0
      }

      assert FilterParser.matches?(killmail, filters)

      # Wrong system
      filters = %{
        system_ids: [30_000_144],
        character_ids: [123_456],
        min_value: 500_000.0,
        preload_days: 0
      }

      refute FilterParser.matches?(killmail, filters)
    end

    test "handles missing zkb data", %{killmail: killmail} do
      killmail = Map.delete(killmail, :zkb)
      filters = %{system_ids: [], character_ids: [], min_value: 1000.0, preload_days: 0}
      refute FilterParser.matches?(killmail, filters)
    end
  end
end
