defmodule Atanor.Admin.Scope do
  @moduledoc """
  The scopes of an admin token (design §10.2).

      cluster:admin                 token management, the audit log and every admin endpoint
      worker:<name>:<action>        one action on one worker
      worker:*:<action>             one action on every worker

  `<action>` is `deploy`, `activate`, `rollback` or `read`. `<name>` is a
  worker name (`a-z`, `0-9`, `_`, `-`). `*` is a whole-segment wildcard for
  workers only: there are no partial patterns, and `cluster:admin` does not
  imply any worker scope. The operator token (`:admin` `:token`) holds every
  scope.
  """

  @actions ~w(deploy activate rollback read)a

  @type t :: :cluster | {:worker, String.t(), atom}
  @type need :: :cluster | {:worker, String.t(), atom}

  @doc "The worker actions."
  @spec actions() :: [atom]
  def actions, do: @actions

  @doc "Parses one scope string."
  @spec parse(term) :: {:ok, t} | :error
  def parse("cluster:admin"), do: {:ok, :cluster}

  def parse("worker:" <> rest) do
    with [worker, action] <- String.split(rest, ":"),
         true <- worker == "*" or Atanor.Deployments.check_worker(worker) == :ok,
         action when action in @actions <- Enum.find(@actions, &(Atom.to_string(&1) == action)) do
      {:ok, {:worker, worker, action}}
    else
      _ -> :error
    end
  end

  def parse(_), do: :error

  @doc "The string of a parsed scope."
  @spec format(t) :: String.t()
  def format(:cluster), do: "cluster:admin"
  def format({:worker, worker, action}), do: "worker:#{worker}:#{action}"

  @doc "Whether the scopes (`:all` for the operator) cover the need."
  @spec allows?(:all | [t], need) :: boolean
  def allows?(:all, _need), do: true
  def allows?(scopes, :cluster), do: :cluster in scopes

  def allows?(scopes, {:worker, worker, action}),
    do: Enum.any?(scopes, &match?({:worker, w, ^action} when w in [worker, "*"], &1))
end
