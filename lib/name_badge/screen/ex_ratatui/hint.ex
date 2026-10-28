defmodule NameBadge.Screen.ExRatatui.Hint do
  @moduledoc """
  The button hint row shared by the badge's ExRatatui apps: a reverse-video chip per button followed by its label.
  """

  alias ExRatatui.Style
  alias ExRatatui.Text.Line
  alias ExRatatui.Text.Span
  alias ExRatatui.Widgets.Paragraph

  @doc """
  Builds a centred hint row from `{button, label}` pairs.

  With `inverted?: true` the polarity flips (plain chips, reverse-video labels) so the row reads on a frame filled with ink.

  ## Examples

      iex> hint = NameBadge.Screen.ExRatatui.Hint.paragraph([{"A", "next"}])
      iex> Enum.map(hint.text.spans, &{&1.content, &1.style.modifiers})
      [{" A ", [:reversed]}, {" next  ", []}]
  """
  @spec paragraph([{String.t(), String.t()}], keyword()) :: Paragraph.t()
  def paragraph(entries, opts \\ []) do
    inverted? = Keyword.get(opts, :inverted?, false)

    spans =
      Enum.flat_map(entries, fn {button, label} ->
        [span(" #{button} ", not inverted?), span(" #{label}  ", inverted?)]
      end)

    %Paragraph{text: %Line{spans: spans}, alignment: :center}
  end

  defp span(content, true), do: %Span{content: content, style: %Style{modifiers: [:reversed]}}
  defp span(content, false), do: %Span{content: content}
end
