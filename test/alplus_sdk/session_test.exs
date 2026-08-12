defmodule AlplusSDK.SessionTest do
  use ExUnit.Case, async: true

  alias AlplusSDK.Session

  setup do
    Session.clear()
    :ok
  end

  test "current/0 is nil until start/0 is called" do
    assert Session.current() == nil
  end

  test "start/0 opens a healthy session with a ses_-prefixed opaque id" do
    session = Session.start()

    assert session.status == :healthy
    assert String.starts_with?(session.id, "ses_")
    assert Session.current() == session
  end

  test "mark_errored/0 upgrades a healthy session to errored" do
    Session.start()
    Session.mark_errored()

    assert Session.current().status == :errored
  end

  test "mark_crashed/0 upgrades a healthy session to crashed" do
    Session.start()
    Session.mark_crashed()

    assert Session.current().status == :crashed
  end

  test "mark_errored/0 never downgrades a crashed session" do
    Session.start()
    Session.mark_crashed()
    Session.mark_errored()

    assert Session.current().status == :crashed
  end

  test "mark_errored/0 and mark_crashed/0 are no-ops when no session is active" do
    Session.mark_errored()
    Session.mark_crashed()

    assert Session.current() == nil
  end

  test "clear/0 removes the current session" do
    Session.start()
    Session.clear()

    assert Session.current() == nil
  end

  test "start/0 never raises" do
    assert %{status: :healthy} = Session.start()
  end
end
