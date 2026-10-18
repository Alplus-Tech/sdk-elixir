defmodule PostDeploy.Id do
  @moduledoc false

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
