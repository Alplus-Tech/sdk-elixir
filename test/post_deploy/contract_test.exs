defmodule ContractTestError do
  @moduledoc """
  Top-level (unnamespaced) so `Module.split/1 |> Enum.join(".")` --
  `PostDeploy.Envelope`'s exception-type derivation -- renders the bare
  `"ContractTestError"` the golden fixture expects, matching the Ruby SDK's
  own top-level `ContractTestError < StandardError` (see
  `sdks/ruby/spec/postdeploy/contract_spec.rb`).
  """
  defexception message: "canonical contract test exception"
end

defmodule PostDeploy.ContractTest do
  @moduledoc """
  Golden-envelope contract test (issue #18): builds each wire item from the
  canonical input documented in `sdks/contract/README.md` and asserts it
  equals the golden fixture, after normalizing the non-deterministic fields
  (`id`, `timestamp`, `started_at`, `duration_ms`) both sides carry.

  The exception item's stack frames are passed to `Envelope.exception_item/3`
  as already-built wire frames (maps, not `{module, fun, arity, location}`
  tuples) -- `Envelope.build_frame/2` passes a map straight through
  unchanged, which is exactly the "supply literal frames" mechanism the
  contract README documents as how three languages converge on one byte
  shape despite each having a different native stack-trace representation.
  """

  use ExUnit.Case, async: true

  alias PostDeploy.Envelope

  @contract_version "2.0.0"
  @non_deterministic_keys ~w(id timestamp)
  @expected_digests %{
    "exception_item.json" =>
      "sha256:a970a83c0b7f8a1d74b8602afd886941634c711e600e41e2dc6ea579f868a380",
    "message_item.json" =>
      "sha256:0f14c4f20605fed9a844646905047835033a7c6ade38fc1cb1d7da0158362e8f",
    "measure_event.json" =>
      "sha256:132914d7468c8909baad2509bfb17de8ee30d585259c783a72d21f9446b6a483",
    "session_item.json" =>
      "sha256:3bfe1d1458a03a3ced1b725c86d2a9aabbd57129f7aeb6a529d2d923ede8ec40"
  }

  # The golden contract is owned by the PostDeploy product (Alplus-Tech/alplus) and
  # consumed as an explicit, immutable input (issue #26): ALPLUS_CONTRACT_DIR
  # points at a checkout of `sdks/contract` at the pinned contract tag. There is
  # no monorepo-relative fallback -- an absent variable fails loudly.
  defp contract_dir do
    case System.get_env("ALPLUS_CONTRACT_DIR") do
      nil ->
        raise """
        ALPLUS_CONTRACT_DIR is not set. The golden contract is a versioned input \
        owned by Alplus-Tech/alplus. Point ALPLUS_CONTRACT_DIR at a checkout of \
        sdks/contract at the contract-v#{@contract_version} tag, then rerun.
        """

      dir ->
        verify_manifest!(dir)
        dir
    end
  end

  defp verify_manifest!(dir) do
    manifest = dir |> Path.join("manifest.json") |> File.read!() |> Jason.decode!()

    unless manifest["version"] == @contract_version and
             manifest["items"] == @expected_digests do
      raise "contract version or independently pinned digest mismatch"
    end

    checksum_file =
      dir
      |> Path.join("SHA256SUMS")
      |> File.stream!()
      |> Map.new(fn line ->
        [digest, name] = String.split(String.trim(line), ~r/\s+/, parts: 2)
        {name, "sha256:" <> digest}
      end)

    Enum.each(@expected_digests, fn {name, expected} ->
      unless checksum_file[name] == expected do
        raise "contract SHA256SUMS mismatch for #{name}"
      end

      digest = dir |> Path.join(name) |> File.read!() |> then(&:crypto.hash(:sha256, &1))
      actual = "sha256:" <> Base.encode16(digest, case: :lower)

      unless actual == expected do
        raise "contract checksum mismatch for #{name}: expected #{expected}, got #{actual}"
      end
    end)
  end

  defp golden(name) do
    contract_dir() |> Path.join(name) |> File.read!() |> Jason.decode!()
  end

  defp normalize(item) when is_map(item) do
    Map.drop(item, @non_deterministic_keys)
  end

  defp canonical_frames do
    [
      %{
        file: "app/worker.ex",
        function: "MyApp.Worker.perform/1",
        lineno: 42,
        colno: 5,
        in_app: true
      },
      %{file: "lib/some_lib.ex", function: "SomeLib.call/2", lineno: 10, in_app: false}
    ]
  end

  defp canonical_breadcrumbs do
    [
      %{
        "category" => "nav",
        "message" => "clicked checkout",
        "level" => "info",
        "ts" => "2024-01-01T00:00:00.000Z"
      },
      %{
        "category" => "http",
        "message" => "POST /api/orders",
        "level" => "info",
        "ts" => "2024-01-01T00:00:01.000Z"
      }
    ]
  end

  test "the exception item matches the golden" do
    item =
      Envelope.exception_item("err_ignored", %ContractTestError{},
        release: "1.0.0",
        environment: "test",
        stacktrace: canonical_frames(),
        fingerprint: ["checkout", "timeout"],
        breadcrumbs: canonical_breadcrumbs(),
        contexts: %{"extra" => %{"cart_id" => "cart_123", "items" => 3}},
        tags: %{"team" => "observability", "flow" => "checkout"},
        user: %{"id" => "user_42", "email" => "person@example.com"}
      )
      |> json_roundtrip()

    assert normalize(item) == normalize(golden("exception_item.json"))
  end

  test "the message item matches the golden" do
    item =
      Envelope.message_item("err_ignored", "canonical contract test message", "warning",
        release: "1.0.0",
        environment: "test",
        breadcrumbs: [
          %{
            "category" => "nav",
            "message" => "opened settings",
            "level" => "info",
            "ts" => "2024-01-01T00:00:00.000Z"
          }
        ],
        contexts: %{"extra" => %{"note" => "message-level context"}},
        tags: %{"team" => "observability"},
        user: %{"id" => "user_42", "email" => "person@example.com"}
      )
      |> json_roundtrip()

    assert normalize(item) == normalize(golden("message_item.json"))
  end

  test "the session item matches the golden" do
    session = %{id: "ses_ignored", status: :crashed}

    item =
      Envelope.session_item(session, release: "1.0.0", environment: "test")
      |> json_roundtrip()

    assert normalize(item) == normalize(golden("session_item.json"))
  end

  defp json_roundtrip(term), do: term |> Jason.encode!() |> Jason.decode!()
end
