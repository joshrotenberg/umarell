defmodule Umarell.Config do
  @moduledoc """
  Daemon configuration accessors.

  Values resolve from application config (set in `config/runtime.exs`) with
  documented defaults. Some values fall back to environment variables when not
  set via application config.
  """

  @app :umarell

  @doc """
  Returns the GitHub login the agent acts as.

  Used as the assignment-mutex key and PR author marker. Reads from the
  `UMARELL_IDENTITY` environment variable. Returns `nil` if unset.
  """
  @spec identity() :: String.t() | nil
  def identity do
    Application.get_env(@app, :identity, System.get_env("UMARELL_IDENTITY"))
  end

  @doc """
  Returns the list of `owner/repo` strings the agent watches.

  Default: `["joshrotenberg/umarell"]`.
  """
  @spec watched_repos() :: [String.t()]
  def watched_repos do
    Application.get_env(@app, :watched_repos, ["joshrotenberg/umarell"])
  end

  @doc """
  Returns the polling interval in milliseconds.

  Default: `30_000`.
  """
  @spec poll_interval_ms() :: non_neg_integer()
  def poll_interval_ms do
    Application.get_env(@app, :poll_interval_ms, 30_000)
  end

  @doc """
  Returns the global concurrency cap.

  Default: `1`.
  """
  @spec concurrency() :: pos_integer()
  def concurrency do
    Application.get_env(@app, :concurrency, 1)
  end

  @doc """
  Returns the label map used to tag issues.

  Default: `%{ready: "agent:ready", working: "agent:working", blocked: "agent:blocked"}`.
  """
  @spec labels() :: %{ready: String.t(), working: String.t(), blocked: String.t()}
  def labels do
    Application.get_env(@app, :labels, %{
      ready: "agent:ready",
      working: "agent:working",
      blocked: "agent:blocked"
    })
  end

  @doc """
  Returns the local-green gate command.

  Default: `"mix format --check-formatted && mix test"`.
  """
  @spec test_command() :: String.t()
  def test_command do
    Application.get_env(@app, :test_command, "mix format --check-formatted && mix test")
  end

  @doc """
  Returns the directory under which working checkouts live.

  Reads from the `UMARELL_CHECKOUT_ROOT` environment variable. Returns `nil` if unset.
  """
  @spec checkout_root() :: String.t() | nil
  def checkout_root do
    Application.get_env(@app, :checkout_root, System.get_env("UMARELL_CHECKOUT_ROOT"))
  end

  @doc """
  Returns the model name passed through to `claude`.

  Reads from the `UMARELL_MODEL` environment variable. Returns `nil` if unset.
  """
  @spec model() :: String.t() | nil
  def model do
    Application.get_env(@app, :model, System.get_env("UMARELL_MODEL"))
  end

  @doc """
  Returns the maximum budget in USD passed through to `claude`.

  Reads from the `UMARELL_MAX_BUDGET_USD` environment variable and parses it as a
  float. Returns `nil` if unset.
  """
  @spec max_budget_usd() :: float() | nil
  def max_budget_usd do
    case Application.get_env(@app, :max_budget_usd) do
      nil ->
        case System.get_env("UMARELL_MAX_BUDGET_USD") do
          nil -> nil
          val -> String.to_float(val)
        end

      val ->
        val
    end
  end
end
