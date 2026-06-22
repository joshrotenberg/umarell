defmodule Umarell.WorkEventTest do
  use ExUnit.Case, async: true

  alias Umarell.WorkEvent

  describe "struct creation" do
    test "creates a WorkEvent with all required fields" do
      event = %WorkEvent{
        repo: "owner/repo",
        number: 42,
        title: "Fix something",
        body: "Description here"
      }

      assert event.repo == "owner/repo"
      assert event.number == 42
      assert event.title == "Fix something"
      assert event.body == "Description here"
    end

    test "enforce_keys: all four fields are required" do
      # @enforce_keys is checked at compile time for struct literals.
      # Verify via struct/2 (runtime path) that missing required keys raise.
      assert_raise ArgumentError, fn ->
        struct!(WorkEvent, number: 1, title: "t", body: "b")
      end

      assert_raise ArgumentError, fn ->
        struct!(WorkEvent, repo: "o/r", title: "t", body: "b")
      end

      assert_raise ArgumentError, fn ->
        struct!(WorkEvent, repo: "o/r", number: 1, body: "b")
      end

      assert_raise ArgumentError, fn ->
        struct!(WorkEvent, repo: "o/r", number: 1, title: "t")
      end
    end
  end
end
