defmodule Umarell.Job.Workspace do
  @moduledoc """
  Prepares a local git checkout of a target repository for the Worker.

  Slice 0: single checkout per repo under `Config.checkout_root/0`, concurrency 1.
  Worktrees are deferred to a later slice.

  ## API

  - `prepare/3` -- clones or fetches the repo under the checkout root and
    creates branch `umarell/issue-<number>`.

  ## Injectable seam

  All git operations are routed through an injectable `git_fn`. The default
  implementation shells to `git` via `System.cmd/3`. In tests, pass a
  `git_fn` that returns canned `{output, exit_code}` tuples without touching
  the filesystem or network.

  The `git_fn` signature is:

      (command :: String.t(), args :: [String.t()], opts :: keyword()) ::
        {output :: String.t(), exit_code :: integer()}
  """

  alias Umarell.Config

  @doc """
  Prepares a checkout of `repo` (`owner/repo` string) and creates the branch
  `umarell/issue-<number>` in it.

  Returns `{:ok, checkout_path}` on success or `{:error, reason}` on failure.

  ## Options

  - `:git_fn` -- injectable git executor. Defaults to a `System.cmd`-based
    implementation. Must accept `(command, args, opts)` and return
    `{output, exit_code}`.
  - `:checkout_root` -- overrides `Config.checkout_root/0`. Useful in tests.
  """
  @spec prepare(String.t(), pos_integer(), keyword()) ::
          {:ok, String.t()} | {:error, term()}
  def prepare(repo, number, opts \\ []) do
    checkout_root = Keyword.get(opts, :checkout_root, Config.checkout_root())
    git_fn = Keyword.get(opts, :git_fn, &default_git_fn/3)
    branch = "umarell/issue-#{number}"
    checkout_path = Path.join([checkout_root, repo])

    if File.dir?(checkout_path) do
      fetch_and_branch(checkout_path, branch, git_fn)
    else
      clone_and_branch(repo, checkout_path, branch, git_fn)
    end
  end

  # Clones the repo into checkout_path, then creates the branch.
  defp clone_and_branch(repo, checkout_path, branch, git_fn) do
    parent = Path.dirname(checkout_path)
    File.mkdir_p!(parent)
    repo_url = "https://github.com/#{repo}.git"

    with {:ok, _} <- run_git(git_fn, "clone", [repo_url, checkout_path], []),
         {:ok, _} <- create_branch(checkout_path, branch, git_fn) do
      {:ok, checkout_path}
    end
  end

  # Fetches from origin in an existing checkout, then creates the branch.
  defp fetch_and_branch(checkout_path, branch, git_fn) do
    with {:ok, _} <- run_git(git_fn, "fetch", ["origin"], cd: checkout_path),
         {:ok, _} <- create_branch(checkout_path, branch, git_fn) do
      {:ok, checkout_path}
    end
  end

  defp create_branch(checkout_path, branch, git_fn) do
    run_git(git_fn, "checkout", ["-b", branch, "origin/main"], cd: checkout_path)
  end

  defp run_git(git_fn, command, args, opts) do
    case git_fn.(command, args, opts) do
      {_output, 0} = result -> {:ok, result}
      {output, code} -> {:error, {code, output}}
    end
  end

  defp default_git_fn(command, args, opts) do
    System.cmd("git", [command | args], Keyword.merge([stderr_to_stdout: true], opts))
  end
end
