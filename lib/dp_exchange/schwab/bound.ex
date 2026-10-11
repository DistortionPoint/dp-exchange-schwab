defmodule DpExchange.Schwab.Bound do
  @moduledoc """
  Bounds venue-supplied text before it enters an error tuple, a notice, a log line or
  telemetry metadata.

  **Why this exists.** A venue's `detail`, `message`, `error_description`, or a LOGIN
  response's `msg` is text this package does not control. A proxy's HTML error page or a
  hostile or broken reply can make it megabytes long, and it would then sit in every
  caller's error tuple, be copied into every notice, and be written to logs. Every other
  venue in the family bounds such text the same way; this is that rule, in one place.

  - A binary is cut to #{2_048} bytes on a valid UTF-8 boundary and marked with its full
    size, so a truncated value never reads as complete. A short binary comes out unchanged.
  - Any other term is rendered with `inspect(term, limit: 50, printable_limit: 2_048)`.
  - `reason/1` is the same for the reason terms of a disconnect or crash
    (`limit: 50, printable_limit: 1_024`).
  """

  @max_bytes 2_048

  @doc """
  Bounds venue-supplied text. `nil` stays `nil`; a short binary is returned unchanged; a
  long binary is cut on a UTF-8 boundary and marked with its full size; any other term is
  inspected with a limit.
  """
  @spec text(term()) :: String.t() | nil
  def text(nil), do: nil

  def text(value) when is_binary(value) and byte_size(value) <= @max_bytes, do: value

  def text(value) when is_binary(value) do
    excerpt(binary_part(value, 0, @max_bytes), 3) <> "… (#{byte_size(value)} bytes)"
  end

  def text(value), do: inspect(value, limit: 50, printable_limit: @max_bytes)

  @doc """
  Renders a reason or other term for a notice, log line or telemetry metadata, bounded.
  """
  @spec reason(term()) :: String.t()
  def reason(term), do: inspect(term, limit: 50, printable_limit: 1_024)

  # A byte prefix trimmed back to a whole UTF-8 character. A UTF-8 character is at most four
  # bytes, so three trims suffice; a prefix still invalid after that was never UTF-8.
  defp excerpt(prefix, trims_left) do
    if String.valid?(prefix) or trims_left == 0,
      do: prefix,
      else: excerpt(binary_part(prefix, 0, byte_size(prefix) - 1), trims_left - 1)
  end
end
