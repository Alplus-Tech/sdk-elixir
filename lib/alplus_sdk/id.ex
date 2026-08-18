defmodule AlplusSDK.Id do
  @moduledoc false

  @doc "Generates a new `err_`-prefixed UUIDv7 event id."
  @spec generate() :: String.t()
  def generate do
    "err_" <> uuidv7()
  end

  @doc """
  Generates a new `ses_`-prefixed UUIDv7 session id for the `POST /e/sessions`
  wire protocol (issue #12). Opaque and used only for in-window ingest
  dedup -- never persisted past that, and never a PII carrier.
  """
  @spec generate_session_id() :: String.t()
  def generate_session_id do
    "ses_" <> uuidv7()
  end

  @doc """
  Generates a bare (unprefixed) UUIDv4, used as `AlplusSDK.heartbeat/3`'s
  `ping_id` -- the same `ping_id` wire param name/format JS's `heartbeat.ts`
  sends (`crypto.randomUUID()`, a standard v4 UUID), so Monitor's ingest can
  dedup retried pings of one logical heartbeat the same way regardless of
  which SDK sent it.
  """
  @spec generate_ping_id() :: String.t()
  def generate_ping_id do
    <<a::48, _::4, b::12, _::2, c::62>> = :crypto.strong_rand_bytes(16)
    <<u0::32, u1::16, u2::16, u3::16, u4::48>> = <<a::48, 0x4::4, b::12, 0x2::2, c::62>>
    format(u0, u1, u2, u3, u4)
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
