defmodule AlplusSDK.PublishedInterfaceTest do
  use ExUnit.Case, async: false

  alias AlplusSDK.{Client, Test}

  defp start_test_client(opts) do
    name = :"published_#{System.unique_integer([:positive])}"

    start_supervised!(
      {Client,
       Keyword.merge(
         [
           name: name,
           key: "alp_p_test_key_123",
           test: true,
           integrations: [],
           flush_interval_ms: 0
         ],
         opts
       )}
    )

    Test.reset!(name)
    name
  end

  test "Test.events/1 records a captured exception without HTTP" do
    name = start_test_client([])

    id =
      AlplusSDK.capture_exception(%RuntimeError{message: "boom"},
        name: name,
        stacktrace: [{Foo, :bar, 0, []}]
      )

    assert String.starts_with?(id, "err_")
    assert :ok == AlplusSDK.flush(name: name, timeout: 1_000)

    [item] = Test.events(name)
    assert item["type"] == "exception"
    assert item["exception"]["value"] == "boom"
    assert [body] = Test.raw(name, :errors)
    assert is_binary(body)
  end

  test "before_send can drop an item" do
    name = start_test_client(before_send: fn _item -> nil end)

    AlplusSDK.capture_exception(%RuntimeError{message: "drop me"}, name: name)
    assert :ok == AlplusSDK.flush(name: name, timeout: 1_000)
    assert Test.events(name) == []
  end

  test "before_send can mutate an item" do
    name =
      start_test_client(
        before_send: fn item ->
          Map.put(item, :tags, Map.merge(item[:tags] || %{}, %{"via" => "before_send"}))
        end
      )

    AlplusSDK.capture_exception(%RuntimeError{message: "mutate"}, name: name)
    assert :ok == AlplusSDK.flush(name: name, timeout: 1_000)

    [item] = Test.events(name)
    assert item["tags"]["via"] == "before_send"
  end

  test "a raising before_send still sends the original item" do
    name = start_test_client(before_send: fn _item -> raise "nope" end)

    AlplusSDK.capture_exception(%RuntimeError{message: "keep me"}, name: name)
    assert :ok == AlplusSDK.flush(name: name, timeout: 1_000)

    [item] = Test.events(name)
    assert item["exception"]["value"] == "keep me"
  end

  test "set_user on the facade lands on the captured item" do
    name = start_test_client([])
    AlplusSDK.set_user(%{id: 42, email: "dev@example.com"})

    AlplusSDK.capture_exception(%RuntimeError{message: "identified"}, name: name)
    assert :ok == AlplusSDK.flush(name: name, timeout: 1_000)

    [item] = Test.events(name)
    assert item["user"] == %{"id" => "42", "email" => "dev@example.com"}
  after
    AlplusSDK.Scope.clear()
  end

  test "start_link attaches the logger handler by default" do
    name = :"auto_attach_#{System.unique_integer([:positive])}"

    start_supervised!(
      {Client, name: name, key: "alp_p_test_key_123", test: true, flush_interval_ms: 0}
    )

    Test.reset!(name)

    :logger.log(:error, "a deliberate error log line", %{})
    assert :ok == Client.flush(name, 1_000)

    [item] = Test.events(name)
    assert item["type"] == "message"
    assert item["message"] == "a deliberate error log line"
    assert item["mechanism"] == "logger"
  end
end
