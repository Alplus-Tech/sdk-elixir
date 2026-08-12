defmodule AlplusSDK.Id do
  @moduledoc """
  Client-generated `err_`-prefixed UUIDv7 event ids for the `POST /e/errors`
  wire protocol (ARCHITECTURE.md §8: dedup on the client `err_` UUIDv7 id).

  Mirrors `packages/sdk/src/core/id.ts`'s hex-dashed UUIDv7 rendering
  (`err_<8>-<4>-<4>-<4>-<12>`) rather than the monolith's own Crockford
  base32 `Alplus.Id` format: this id is a wire-protocol idempotency key sent
  to an HTTP endpoint, not an Ash resource primary key, and the ingest
  parser (`Alplus.Observe.ErrorEnvelope`) only requires a 4-64 byte string —
  it does not enforce a specific encoding.
  """

  @doc "Generates a new `err_`-prefixed UUIDv7 event id."
  @spec generate() :: String.t()
  def generate do
    "err_" <> uuidv7()
  end

  defp uuidv7 do
    <<rand_a::12, rand_b::62, _::6>> = :crypto.strong_rand_bytes(10)
    unix_ms = System.system_time(:millisecond)

    <<u0::32, u1::16, u2::16, u3::16, u4::48>> =
      <<unix_ms::48, 0x7::4, rand_a::12, 0x2::2, rand_b::62>>

    format(u0, u1, u2, u3, u4)
  end

  defp format(u0, u1, u2, u3, u4) do
    :io_lib.format("~8.16.0b-~4.16.0b-~4.16.0b-~4.16.0b-~12.16.0b", [u0, u1, u2, u3, u4])
    |> IO.iodata_to_binary()
    |> String.downcase()
  end
end
