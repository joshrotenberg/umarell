defmodule Umarell.WorkEvent do
  @moduledoc """
  Represents a single ready GitHub issue handed off to the Scheduler.

  All four fields are required. `repo` is the `owner/repo` string from
  which the issue was fetched.
  """

  @enforce_keys [:repo, :number, :title, :body]
  defstruct [:repo, :number, :title, :body]

  @typedoc "A work event derived from one ready GitHub issue."
  @type t() :: %__MODULE__{
          repo: String.t(),
          number: pos_integer(),
          title: String.t(),
          body: String.t()
        }
end
