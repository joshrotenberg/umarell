defmodule Umarell.ConfigTest do
  use ExUnit.Case, async: false

  alias Umarell.Config

  @app :umarell

  setup do
    # Capture existing app env keys so we can restore them after each test.
    keys = [
      :identity,
      :watched_repos,
      :poll_interval_ms,
      :concurrency,
      :labels,
      :test_command,
      :checkout_root,
      :model,
      :max_budget_usd
    ]

    saved =
      Enum.map(keys, fn k -> {k, Application.get_env(@app, k)} end)

    on_exit(fn ->
      Enum.each(saved, fn
        {k, nil} -> Application.delete_env(@app, k)
        {k, v} -> Application.put_env(@app, k, v)
      end)
    end)

    :ok
  end

  describe "defaults" do
    test "identity/0 returns nil when not configured" do
      Application.delete_env(@app, :identity)
      System.delete_env("UMARELL_IDENTITY")
      assert Config.identity() == nil
    end

    test "watched_repos/0 returns default list" do
      Application.delete_env(@app, :watched_repos)
      assert Config.watched_repos() == ["joshrotenberg/umarell"]
    end

    test "poll_interval_ms/0 returns 30_000 by default" do
      Application.delete_env(@app, :poll_interval_ms)
      assert Config.poll_interval_ms() == 30_000
    end

    test "concurrency/0 returns 1 by default" do
      Application.delete_env(@app, :concurrency)
      assert Config.concurrency() == 1
    end

    test "labels/0 returns default label map" do
      Application.delete_env(@app, :labels)

      assert Config.labels() == %{
               ready: "agent:ready",
               working: "agent:working",
               blocked: "agent:blocked"
             }
    end

    test "test_command/0 returns default command string" do
      Application.delete_env(@app, :test_command)
      assert Config.test_command() == "mix format --check-formatted && mix test"
    end

    test "checkout_root/0 returns nil when not configured" do
      Application.delete_env(@app, :checkout_root)
      System.delete_env("UMARELL_CHECKOUT_ROOT")
      assert Config.checkout_root() == nil
    end

    test "model/0 returns nil when not configured" do
      Application.delete_env(@app, :model)
      System.delete_env("UMARELL_MODEL")
      assert Config.model() == nil
    end

    test "max_budget_usd/0 returns nil when not configured" do
      Application.delete_env(@app, :max_budget_usd)
      System.delete_env("UMARELL_MAX_BUDGET_USD")
      assert Config.max_budget_usd() == nil
    end
  end

  describe "application config overrides" do
    test "identity/0 returns configured value" do
      Application.put_env(@app, :identity, "my-bot")
      assert Config.identity() == "my-bot"
    end

    test "watched_repos/0 returns configured list" do
      Application.put_env(@app, :watched_repos, ["owner/repo1", "owner/repo2"])
      assert Config.watched_repos() == ["owner/repo1", "owner/repo2"]
    end

    test "poll_interval_ms/0 returns configured value" do
      Application.put_env(@app, :poll_interval_ms, 60_000)
      assert Config.poll_interval_ms() == 60_000
    end

    test "concurrency/0 returns configured value" do
      Application.put_env(@app, :concurrency, 4)
      assert Config.concurrency() == 4
    end

    test "labels/0 returns configured map" do
      custom = %{ready: "custom:ready", working: "custom:working", blocked: "custom:blocked"}
      Application.put_env(@app, :labels, custom)
      assert Config.labels() == custom
    end

    test "test_command/0 returns configured command" do
      Application.put_env(@app, :test_command, "mix test --only unit")
      assert Config.test_command() == "mix test --only unit"
    end

    test "checkout_root/0 returns configured path" do
      Application.put_env(@app, :checkout_root, "/tmp/checkouts")
      assert Config.checkout_root() == "/tmp/checkouts"
    end

    test "model/0 returns configured model" do
      Application.put_env(@app, :model, "claude-3-opus")
      assert Config.model() == "claude-3-opus"
    end

    test "max_budget_usd/0 returns configured float" do
      Application.put_env(@app, :max_budget_usd, 5.0)
      assert Config.max_budget_usd() == 5.0
    end
  end

  describe "environment variable overrides" do
    test "identity/0 reads from UMARELL_IDENTITY env var" do
      Application.delete_env(@app, :identity)
      System.put_env("UMARELL_IDENTITY", "env-bot")

      on_exit(fn -> System.delete_env("UMARELL_IDENTITY") end)

      assert Config.identity() == "env-bot"
    end

    test "checkout_root/0 reads from UMARELL_CHECKOUT_ROOT env var" do
      Application.delete_env(@app, :checkout_root)
      System.put_env("UMARELL_CHECKOUT_ROOT", "/tmp/env-checkouts")

      on_exit(fn -> System.delete_env("UMARELL_CHECKOUT_ROOT") end)

      assert Config.checkout_root() == "/tmp/env-checkouts"
    end

    test "model/0 reads from UMARELL_MODEL env var" do
      Application.delete_env(@app, :model)
      System.put_env("UMARELL_MODEL", "claude-sonnet")

      on_exit(fn -> System.delete_env("UMARELL_MODEL") end)

      assert Config.model() == "claude-sonnet"
    end

    test "max_budget_usd/0 reads and parses UMARELL_MAX_BUDGET_USD env var" do
      Application.delete_env(@app, :max_budget_usd)
      System.put_env("UMARELL_MAX_BUDGET_USD", "10.5")

      on_exit(fn -> System.delete_env("UMARELL_MAX_BUDGET_USD") end)

      assert Config.max_budget_usd() == 10.5
    end
  end
end
