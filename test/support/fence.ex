defmodule Atanor.Test.Fence do
  @moduledoc """
  Lets a run turn the local-time fence off (`ATANOR_TEST_FENCE=off`) or only the deferral after an early
  takeover (`ATANOR_TEST_FENCE=no_defer`), to show that the fence tests fail without them.
  """

  @doc "The `routing:` options for the fence, honouring `ATANOR_TEST_FENCE`."
  @spec routing(keyword) :: keyword
  def routing(opts \\ []) do
    mode = System.get_env("ATANOR_TEST_FENCE")
    Keyword.merge(opts, fence: mode != "off", fence_defer_after_takeover: mode not in ["off", "no_defer"])
  end
end
