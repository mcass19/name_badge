defmodule NameBadge.Screen.ExRatatui.Banner do
  @moduledoc """
  Blinking big-text banner: the screen to leave running on the badge while it sits on a table or a lanyard.

  The messages are plain strings in `@messages` at the top of this module (or a `:messages` list in the app opts). Edit them, reorder them, add more: each one is word-wrapped and drawn with the largest `ExRatatui.BigText` size that fits the panel, and a `"\\n"` forces a line break. Text too long for even the smallest size falls back to ordinary wrapped text.

  ## Sizes

  `BigText` letters are 8 or 4 cells wide and 8 or 4 cells tall. On the 66×37 grid the text gets a 64×32 area: one row is kept for the hints, and a margin of 2 rows above and below and 1 column on each side keeps letters off the panel's edge. The candidates, largest first, are:

  | Size           | Characters per line | Lines that fit |
  | -------------- | ------------------- | -------------- |
  | `:full`        | 8                   | 4              |
  | `:half_width`  | 16                  | 4              |
  | `:half_height` | 8                   | 8              |
  | `:quadrant`    | 16                  | 8              |

  Lines are one row apart when there is room, and touch when there is not (the letters keep a blank row of their own, so they still read apart).

  A single word longer than 16 characters only fits as plain text. Stick to ASCII: a typographic apostrophe or an emoji is not in the badge font and renders as a hatched placeholder.

  ## The cycle

  Every message is shown twice in a row, first ink on paper, then paper on ink, one step per tick (3 s). With two messages that is `A, A inverted, B, B inverted`.

  Swapping messages without the inverted step would strand pixels: a pixel inside a letter of both messages is ink on every frame and never gets driven, and the panel only takes partial refreshes on this screen, which is how ghosting builds up over a long session. Showing each message in both polarities drives every pixel both ways once per cycle.

  ## Controls

  | Key      | Badge button     | Action                       |
  | -------- | ---------------- | ---------------------------- |
  | `up`     | A (single press) | Pause or resume the cycle    |
  | `home`   | A (long press)   | Back to the first message    |
  | `down`   | B (single press) | Next step now, even when paused |
  | —        | B (long press)   | Back to the menu             |
  """

  use ExRatatui.App, runtime: :reducer

  alias ExRatatui.BigText
  alias ExRatatui.Event.Key
  alias ExRatatui.Layout.Rect
  alias ExRatatui.Style
  alias ExRatatui.Subscription
  alias ExRatatui.Widgets.Paragraph
  alias NameBadge.Screen.ExRatatui.Hint

  @messages [
    "HI THERE!",
    "I'M A TUI :)"
  ]

  @tick_interval_ms 3_000

  # Margin around the text, in cells.
  @margin_rows 2
  @margin_cols 1

  # Largest first: {pixel_size, {cells per character wide, tall}}.
  @sizes [full: {8, 8}, half_width: {4, 8}, half_height: {8, 4}, quadrant: {4, 4}]

  @impl ExRatatui.App
  def init(opts) do
    case Keyword.get(opts, :messages, @messages) do
      [_ | _] = messages ->
        {:ok, %{messages: messages, tick: 0, paused?: false}}

      other ->
        raise ArgumentError, "expected :messages to be a non-empty list, got: #{inspect(other)}"
    end
  end

  @impl ExRatatui.App
  def update({:event, %Key{code: "up"}}, state),
    do: {:noreply, %{state | paused?: not state.paused?}}

  def update({:event, %Key{code: "home"}}, state), do: {:noreply, %{state | tick: 0}}
  def update({:event, %Key{code: "down"}}, state), do: {:noreply, %{state | tick: state.tick + 1}}
  def update({:info, :tick}, %{paused?: true} = state), do: {:noreply, state, render?: false}
  def update({:info, :tick}, state), do: {:noreply, %{state | tick: state.tick + 1}}
  def update(_message, state), do: {:noreply, state, render?: false}

  @impl ExRatatui.App
  def subscriptions(_state), do: [Subscription.interval(:banner_tick, @tick_interval_ms, :tick)]

  @impl ExRatatui.App
  def render(state, %{width: width, height: height}) do
    count = length(state.messages)
    inverted? = inverted?(state.tick)
    message = Enum.at(state.messages, message_index(state.tick, count))

    body = %Rect{
      x: @margin_cols,
      y: @margin_rows,
      width: width - 2 * @margin_cols,
      height: height - 1 - 2 * @margin_rows
    }

    hint =
      Hint.paragraph(
        [
          {"A", if(state.paused?, do: "resume", else: "pause")},
          {"A long", "first"},
          {"B", "next"},
          {"B long", "back"}
        ],
        inverted?: inverted?
      )

    fill(width, height, inverted?) ++
      message_widgets(message, body, inverted?) ++
      [{hint, %Rect{x: 0, y: height - 1, width: width, height: 1}}]
  end

  @doc """
  Whether the frame at `tick` is inverted (paper letters on ink): odd ticks are.

  ## Examples

      iex> Enum.map(0..3, &NameBadge.Screen.ExRatatui.Banner.inverted?/1)
      [false, true, false, true]
  """
  @spec inverted?(non_neg_integer()) :: boolean()
  def inverted?(tick), do: rem(tick, 2) == 1

  @doc """
  The index of the message shown at `tick` out of `count` messages: each one holds for two ticks.

  ## Examples

      iex> Enum.map(0..5, &NameBadge.Screen.ExRatatui.Banner.message_index(&1, 2))
      [0, 0, 1, 1, 0, 0]
  """
  @spec message_index(non_neg_integer(), pos_integer()) :: non_neg_integer()
  def message_index(tick, count), do: div(rem(tick, 2 * count), 2)

  @doc """
  Picks how `message` is drawn in a `width`×`height` cell area: the largest `BigText` size whose word-wrapped lines fit, or `:text` when none does.

  ## Examples

      iex> NameBadge.Screen.ExRatatui.Banner.fit("HELLO FROM A NAME BADGE", 64, 32)
      {:full, ["HELLO", "FROM A", "NAME", "BADGE"]}

      iex> NameBadge.Screen.ExRatatui.Banner.fit("ELIXIR\\nON A BADGE", 64, 32)
      {:full, ["ELIXIR", "ON A", "BADGE"]}

      iex> NameBadge.Screen.ExRatatui.Banner.fit("PIXEL REGIONS", 64, 12)
      {:half_width, ["PIXEL REGIONS"]}

      iex> NameBadge.Screen.ExRatatui.Banner.fit(String.duplicate("X", 17), 64, 32)
      {:text, ["XXXXXXXXXXXXXXXXX"]}
  """
  @spec fit(String.t(), pos_integer(), pos_integer()) :: {atom(), [String.t()]}
  def fit(message, width, height) do
    Enum.find_value(@sizes, {:text, [message]}, fn {size, {char_width, char_height}} ->
      with {:ok, lines} <- wrap(message, div(width, char_width)),
           true <- stack_height(length(lines), char_height, 0) <= height do
        {size, lines}
      else
        _ -> nil
      end
    end)
  end

  defp wrap(message, max_chars) do
    message
    |> String.split("\n")
    |> Enum.reduce_while({:ok, []}, fn paragraph, {:ok, lines} ->
      words = String.split(paragraph)

      if Enum.any?(words, &(String.length(&1) > max_chars)),
        do: {:halt, :error},
        else: {:cont, {:ok, lines ++ pack(words, max_chars)}}
    end)
  end

  # Greedy word packing; an empty paragraph keeps its blank line.
  defp pack([], _max_chars), do: [""]

  defp pack([first | rest], max_chars) do
    {lines, current} =
      Enum.reduce(rest, {[], first}, fn word, {lines, current} ->
        candidate = current <> " " <> word

        if String.length(candidate) <= max_chars,
          do: {lines, candidate},
          else: {[current | lines], word}
      end)

    Enum.reverse([current | lines])
  end

  defp stack_height(count, line_height, gap), do: count * line_height + (count - 1) * gap

  # A normal frame paints nothing behind the text (paper). An inverted one lays
  # an ink fill first; the text on top carries :reversed to punch out as paper.
  defp fill(_width, _height, false), do: []

  defp fill(width, height, true) do
    [{%Paragraph{style: %Style{bg: :black}}, %Rect{x: 0, y: 0, width: width, height: height}}]
  end

  defp text_style(true), do: %Style{modifiers: [:reversed]}
  defp text_style(false), do: %Style{}

  defp message_widgets(message, %Rect{} = body, inverted?) do
    case fit(message, body.width, body.height) do
      {:text, _lines} ->
        rows = min(body.height, div(String.length(message) + body.width - 1, body.width))
        top = body.y + div(body.height - rows, 2)

        [
          {%Paragraph{
             text: message,
             wrap: true,
             alignment: :center,
             style: text_style(inverted?)
           }, %Rect{body | y: top, height: body.height - (top - body.y)}}
        ]

      {size, lines} ->
        {_char_width, line_height} = Keyword.fetch!(@sizes, size)
        count = length(lines)
        gap = if stack_height(count, line_height, 1) <= body.height, do: 1, else: 0
        top = body.y + div(body.height - stack_height(count, line_height, gap), 2)

        lines
        |> Enum.with_index()
        |> Enum.map(fn {line, index} ->
          widget =
            BigText.new(line, pixel_size: size, alignment: :center, style: text_style(inverted?))

          {widget, %Rect{body | y: top + index * (line_height + gap), height: line_height}}
        end)
    end
  end
end
