defmodule AlplusSDK.CauseCarrier do
  defexception [:message, :cause]
end

defmodule AlplusSDK.EnvelopeTest do
  use ExUnit.Case, async: true

  alias AlplusSDK.{Envelope, Stack}

  defp json(term), do: term |> Jason.encode!() |> Jason.decode!()

  describe "format_mfa / KeyError arity lists" do
    test "an integer arity renders Mod.fun/n" do
      assert Stack.format_mfa(Map, :fetch!, 2) == "Map.fetch!/2"
    end

    test "an argument-list arity uses length(args) and never interpolates the list" do
      assert Stack.format_mfa(Map, :fetch!, ["entry_id", %{"other" => 1}]) == "Map.fetch!/2"
    end

    test "a KeyError stack with an args list builds an exception item instead of raising" do
      exception = %KeyError{key: "entry_id", term: %{}}

      stack = [
        {Map, :fetch!, ["entry_id", %{}], [file: ~c"lib/map.ex", line: 1]},
        {Awards.AlplusSmoke, :parse_entry, 1, [file: ~c"lib/awards/alplus_smoke.ex", line: 59]}
      ]

      item = Envelope.exception_item("err_key", exception, stacktrace: stack)

      assert item.exception.type == "KeyError"
      assert hd(item.exception.stacktrace.frames).function == "Map.fetch!/2"

      assert List.last(item.exception.stacktrace.frames).function ==
               "Awards.AlplusSmoke.parse_entry/1"
    end
  end

  describe "cause chain" do
    test "walks :cause / :cause_stacktrace into exception.cause" do
      inner = %KeyError{key: "entry_id", term: %{}}
      wrapper = %RuntimeError{message: "ShortlistImport failed for awards.csv"}

      inner_stack = [
        {Map, :fetch!, ["entry_id", %{}], [file: ~c"lib/map.ex", line: 1]}
      ]

      item =
        Envelope.exception_item("err_wrap", wrapper,
          stacktrace: [
            {Awards.AlplusSmoke, :run_wrapped_cause, 0, [file: ~c"lib/smoke.ex", line: 22]}
          ],
          cause: inner,
          cause_stacktrace: inner_stack
        )
        |> json()

      assert item["exception"]["type"] == "RuntimeError"
      assert item["exception"]["cause"]["type"] == "KeyError"
      assert item["exception"]["cause"]["value"] =~ "entry_id"
      assert hd(item["exception"]["cause"]["stacktrace"]["frames"])["function"] == "Map.fetch!/2"
      refute Map.has_key?(item["exception"]["cause"], "cause")
    end

    test "walks a :cause field on the exception struct" do
      inner = %RuntimeError{message: "root"}
      outer = %AlplusSDK.CauseCarrier{message: "outer", cause: inner}

      item = Envelope.exception_item("err_field", outer) |> json()

      assert item["exception"]["type"] == "AlplusSDK.CauseCarrier"
      assert item["exception"]["cause"]["type"] == "RuntimeError"
      assert item["exception"]["cause"]["value"] == "root"
    end

    test "omits the cause key when there is no cause" do
      item = Envelope.exception_item("err_plain", %RuntimeError{message: "solo"}) |> json()
      refute Map.has_key?(item["exception"], "cause")
    end

    test "a non-exception cause is dropped" do
      item =
        Envelope.exception_item("err_str", %RuntimeError{message: "outer"},
          cause: "just a string"
        )
        |> json()

      refute Map.has_key?(item["exception"], "cause")
    end

    test "bounds the chain at 4 causes" do
      chain =
        Enum.reduce(1..7, %AlplusSDK.CauseCarrier{message: "layer 0"}, fn n, acc ->
          %AlplusSDK.CauseCarrier{message: "layer #{n}", cause: acc}
        end)

      item = Envelope.exception_item("err_deep", chain) |> json()

      depths =
        Stream.unfold(item["exception"]["cause"], fn
          nil -> nil
          cause -> {cause["type"], cause["cause"]}
        end)
        |> Enum.count()

      assert depths == 4
    end
  end

  describe "source context" do
    @fixture Path.expand("../fixtures/source_context_sample.txt", __DIR__)

    test "attaches pre_context/context_line/post_context to an in_app frame" do
      lineno = 10

      stack = [
        {AlplusSDK.Stack, :frames, 3, [file: String.to_charlist(@fixture), line: lineno]}
      ]

      item =
        Envelope.exception_item("err_src", %RuntimeError{message: "boom"},
          stacktrace: stack,
          in_app_otp_apps: [:alplus_sdk],
          context_lines: 3
        )
        |> json()

      frame = hd(item["exception"]["stacktrace"]["frames"])
      assert frame["in_app"] == true
      assert frame["context_line"] =~ "raise \"boom on line ten\""
      assert length(frame["pre_context"]) == 3
      assert Enum.any?(frame["pre_context"], &String.contains?(&1, "def raise_here"))
      assert Enum.any?(frame["post_context"], &String.contains?(&1, "below_the_raise"))
    end

    test "skips source context when context_lines is 0" do
      stack = [
        {AlplusSDK.Stack, :frames, 3, [file: String.to_charlist(@fixture), line: 10]}
      ]

      item =
        Envelope.exception_item("err_off", %RuntimeError{message: "boom"},
          stacktrace: stack,
          in_app_otp_apps: [:alplus_sdk],
          context_lines: 0
        )
        |> json()

      frame = hd(item["exception"]["stacktrace"]["frames"])
      refute Map.has_key?(frame, "context_line")
      refute Map.has_key?(frame, "pre_context")
    end

    test "skips source context on a library frame" do
      stack = [
        {:erlang, :apply, 2, [file: String.to_charlist(@fixture), line: 10]}
      ]

      item =
        Envelope.exception_item("err_lib", %RuntimeError{message: "boom"},
          stacktrace: stack,
          in_app_otp_apps: [:alplus_sdk],
          context_lines: 3
        )
        |> json()

      frame = hd(item["exception"]["stacktrace"]["frames"])
      assert frame["in_app"] == false
      refute Map.has_key?(frame, "context_line")
    end
  end
end
