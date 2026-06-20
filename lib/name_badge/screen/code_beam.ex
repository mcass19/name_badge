defmodule NameBadge.Screen.CodeBeam do
  @moduledoc """
  Menu-facing wrapper around `NameBadge.Screen.ExRatatui.CodeBeam` —
  hosts the blinking conference banner through `NameBadge.Screen.ExRatatui`
  with the adapter's default A/B/A-long key map.
  """

  use NameBadge.Screen.ExRatatui, app: NameBadge.Screen.ExRatatui.CodeBeam
end
