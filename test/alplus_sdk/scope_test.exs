defmodule AlplusSDK.ScopeTest do
  @moduledoc """
  Scope state lives in the process dictionary, so every test here must own
  its process -- `async: true` is safe (each test runs in its own process,
  which is exactly the isolation `AlplusSDK.Scope` relies on), but tests
  must not assume state survives across `Task`/spawned processes.
  """

  use ExUnit.Case, async: true

  alias AlplusSDK.Scope

  setup do
    Scope.clear()
    :ok
  end

  test "current/0 is empty before anything is set" do
    assert %Scope{user: nil, tags: %{}, contexts: %{}, breadcrumbs: []} = Scope.current()
  end

  test "set_user/1 sets (normalized to string keys/values) and nil clears the ambient user" do
    :ok = Scope.set_user(%{id: "u1", email: "u1@example.com"})
    assert Scope.current().user == %{"id" => "u1", "email" => "u1@example.com"}

    :ok = Scope.set_user(nil)
    assert Scope.current().user == nil
  end

  test "set_user/1 stringifies a non-binary id (a normal Phoenix integer PK)" do
    :ok = Scope.set_user(%{id: 42, email: "u1@example.com"})
    assert Scope.current().user == %{"id" => "42", "email" => "u1@example.com"}
  end

  test "set_tag/2 stringifies key and value and accumulates" do
    :ok = Scope.set_tag(:org_id, 42)
    :ok = Scope.set_tag("plan", :pro)

    assert Scope.current().tags == %{"org_id" => "42", "plan" => "pro"}
  end

  test "set_context/2 stores a named context map" do
    :ok = Scope.set_context(:request, %{method: "GET"})
    assert Scope.current().contexts == %{"request" => %{method: "GET"}}
  end

  test "add_breadcrumb/1 appends and caps the ring buffer at 100" do
    for n <- 1..150 do
      :ok = Scope.add_breadcrumb(%{"message" => "step #{n}"})
    end

    breadcrumbs = Scope.current().breadcrumbs
    assert length(breadcrumbs) == 100
    assert List.first(breadcrumbs)["message"] == "step 51"
    assert List.last(breadcrumbs)["message"] == "step 150"
  end

  test "clear/0 resets everything" do
    Scope.set_user(%{id: "u1"})
    Scope.set_tag("a", "b")
    Scope.add_breadcrumb(%{"message" => "x"})

    :ok = Scope.clear()

    assert Scope.current() == %Scope{}
  end

  test "setters never raise on invalid input" do
    assert :ok == Scope.set_user("not a map")
    assert :ok == Scope.set_context("name", "not a map")
    assert :ok == Scope.add_breadcrumb("not a map")
  end
end
