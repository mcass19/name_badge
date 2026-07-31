defmodule NameBadge.Screen.ExRatatui.CodeBeam do
  @moduledoc """
  Blinking conference banner — the big-text showcase for the
  `NameBadge.Screen.ExRatatui` adapter and the screen meant to be left
  running on the badge during the Code BEAM Europe 2026 talk.

  Two messages take turns, each shown in both polarities, on a
  four-tick cycle:

  | Tick | Message                       | Polarity            |
  | ---- | ----------------------------- | ------------------- |
  | 0    | `HI CODE BEAM EUROPE 2026!`   | ink on paper        |
  | 1    | `HI CODE BEAM EUROPE 2026!`   | paper on ink        |
  | 2    | `I'M A TUI :)`                | ink on paper        |
  | 3    | `I'M A TUI :)`                | paper on ink        |

  At the 3 s tick that is a 12 s loop with each message legible for
  6 s of it. It sits alongside `Goathi` as a second, typographic way
  for ex_ratatui to say hi at the conference.

  Built on the reducer runtime — one `update/2` clause per
  `{:event, …}` / `{:info, …}` shape — so it doubles as a small tour of
  a self-ticking ExRatatui app.

  ## How the invert works

  The raster turns a cell to paper-on-ink only when it carries
  `bg: :black` or the `:reversed` modifier. On an inverted tick a
  full-frame `bg: :black` `Paragraph` paints ink across every cell, and
  each `BigText` line carries `:reversed` so its letters punch out as
  paper while the gaps show the ink field. The hint row inverts too, by
  flipping the reverse-video flag on each of its spans.

  ## Why four phases and not two

  Swapping the two messages directly — banner normal, then TUI card
  inverted — would strand pixels. A pixel inside a banner letter but
  outside a card letter is ink on both frames, so it never gets driven;
  the reverse holds for paper. Those static pixels sit beside
  neighbours flipping every tick for the length of a talk, which is how
  partial-refresh ghosting builds on this panel — and `NameBadge.Screen`
  renders everything after the first frame as `refresh_type: :partial`,
  so no periodic full refresh comes along to clean up after it.

  Showing each message in both polarities fixes it. Over one cycle every
  pixel takes both values, whichever letters it happens to fall inside:

  | Pixel falls in     | banner | banner inv | card  | card inv |
  | ------------------ | ------ | ---------- | ----- | -------- |
  | both letters       | ink    | paper      | ink   | paper    |
  | banner letter only | ink    | paper      | paper | ink      |
  | card letter only   | paper  | ink        | ink   | paper    |
  | neither            | paper  | ink        | paper | ink      |

  Every row carries both values, so nothing holds one state across a
  cycle and the adapter can stay on partial refresh. Collapsing this
  back to a two-phase swap reintroduces the ghosting.

  ## Why these sizes and line splits

  `BigText` builds large letters out of block glyphs. The badge's 6×8
  font only carries `█ ▀ ▄` (full and half blocks), so only the `:full`
  and `:half_height` pixel sizes render — the narrower sizes emit
  quadrant/half-width glyphs the font lacks. Both safe sizes are 8
  cells wide per character, which caps a line at 8 characters (66 ÷ 8)
  whichever one is in play.

  That cap is what splits both messages. `CODE BEAM` is nine
  characters, so the banner stacks five `:half_height` lines
  (5 × 4 + 4 gaps = 24 rows). `I'M A TUI :)` splits into three, and at
  `:full` those come to 26 rows — close enough to the banner's 24 that
  the panel does not read as half-empty on the swap, and the two sizes
  side by side make the screen a small tour of what `BigText` does.

  Note the plain ASCII apostrophe in `I'M`. A typographic `'` is not in
  the 6×8 font and renders as the placeholder checker glyph.

  ## Controls

  | Key (TUI) | Badge button      | Action                   |
  | --------- | ----------------- | ------------------------ |
  | `up`      | A (single press)  | Pause/resume the cycle   |
  | `home`    | A (long press)    | Reset to tick 0 (banner) |
  | `down`    | B (single press)  | Advance one phase now    |
  | —         | B (long press)    | Back to menu (handled by `NameBadge.Screen`) |

  `down` steps the cycle whether or not it is paused, so the flip can
  be landed on a beat mid-talk instead of waiting out the tick.
  """

  use ExRatatui.App, runtime: :reducer

  alias ExRatatui.BigText
  alias ExRatatui.Event.Key
  alias ExRatatui.Layout.Rect
  alias ExRatatui.Style
  alias ExRatatui.Subscription
  alias ExRatatui.Text.Span
  alias ExRatatui.Widgets.Paragraph
  alias NameBadge.ExRatatui.Frame

  # 3 s clears the badge's UC8276 partial-refresh budget (≈ 350 ms)
  # with margin, and is a calm, room-legible blink rather than a strobe.
  @tick_interval_ms 3_000

  @messages [
    %{lines: ~w(HI CODE BEAM EUROPE 2026!), pixel_size: :half_height, line_height: 4},
    %{lines: ["I'M", "A TUI", ":)"], pixel_size: :full, line_height: 8}
  ]

  # Every message gets one tick per polarity.
  @phase_count 2 * length(@messages)
  @line_gap 1

  @impl ExRatatui.App
  def init(_opts), do: {:ok, %{tick: 0, paused?: false}}

  @impl ExRatatui.App
  def update({:event, %Key{code: "up"}}, state),
    do: {:noreply, %{state | paused?: not state.paused?}}

  def update({:event, %Key{code: "home"}}, state),
    do: {:noreply, %{state | tick: 0}}

  # Manual advance ignores paused? on purpose — pausing the automatic
  # cycle and stepping it by hand is the point.
  def update({:event, %Key{code: "down"}}, state),
    do: {:noreply, %{state | tick: state.tick + 1}}

  def update({:info, :tick}, %{paused?: true} = state),
    do: {:noreply, state}

  def update({:info, :tick}, state),
    do: {:noreply, %{state | tick: state.tick + 1}}

  def update(_msg, state), do: {:noreply, state}

  @impl ExRatatui.App
  def subscriptions(_state) do
    [Subscription.interval(:code_beam_tick, @tick_interval_ms, :tick)]
  end

  @impl ExRatatui.App
  def render(state, frame) do
    inverted? = inverted?(state.tick)
    message = Enum.at(@messages, message_index(state.tick))

    fill(frame, inverted?) ++
      banner_lines(frame, message, inverted?) ++
      [{hint(state, inverted?), hint_rect(frame)}]
  end

  @doc """
  Whether the panel renders inverted (paper letters on an ink field)
  at the given tick. Public so tests can assert the alternation without
  going through `render/2`.

  Even ticks (including 0) render normal polarity; odd ticks invert.
  """
  @spec inverted?(non_neg_integer()) :: boolean()
  def inverted?(tick) when is_integer(tick) and tick >= 0, do: rem(tick, 2) == 1

  @doc """
  Index into the message list for the given tick — `0` for the
  conference banner, `1` for the `I'M A TUI :)` card. Public alongside
  `inverted?/1` so tests can assert the cycle directly.

  Each message holds for two consecutive ticks, one per polarity, so
  the sequence runs `0, 0, 1, 1, 0, 0, …`.
  """
  @spec message_index(non_neg_integer()) :: non_neg_integer()
  def message_index(tick) when is_integer(tick) and tick >= 0,
    do: div(rem(tick, @phase_count), 2)

  # On a normal tick nothing paints the background, so cells fall back
  # to paper. On an inverted tick a full-frame ink fill goes down first.
  defp fill(_frame, false), do: []

  defp fill(%{width: width, height: height}, true) do
    [{%Paragraph{style: %Style{bg: :black}}, %Rect{x: 0, y: 0, width: width, height: height}}]
  end

  defp banner_lines(frame, message, inverted?) do
    style = if inverted?, do: %Style{modifiers: [:reversed]}, else: %Style{}

    message.lines
    |> Enum.with_index()
    |> Enum.map(fn {text, index} ->
      widget =
        BigText.new(text, pixel_size: message.pixel_size, alignment: :center, style: style)

      {widget, line_rect(frame, message, index)}
    end)
  end

  # Stack the message's fixed-height lines, gap between each, vertically
  # centred in the content area above the single-row hint strip.
  defp line_rect(%{width: width, height: height}, message, index) do
    count = length(message.lines)
    block_height = count * message.line_height + (count - 1) * @line_gap
    top = max(0, div(height - 1 - block_height, 2))

    %Rect{
      x: 0,
      y: top + index * (message.line_height + @line_gap),
      width: width,
      height: message.line_height
    }
  end

  defp hint_rect(%{width: width, height: height}) do
    %Rect{x: 2, y: height - 1, width: width - 4, height: 1}
  end

  defp hint(state, inverted?) do
    pause_label = if state.paused?, do: " resume ", else: " pause "

    base =
      Frame.hint([
        {" A ", :chip},
        {pause_label, :label},
        {" A long ", :chip},
        {" reset ", :label},
        {" B ", :chip},
        {" next ", :label},
        {" B long ", :chip},
        {" back", :label}
      ])

    if inverted?, do: %Paragraph{base | text: Enum.map(base.text, &flip/1)}, else: base
  end

  # Flip a span's reverse-video flag so the hint inverts in lockstep
  # with the banner: chips that are reverse-video on a normal frame go
  # plain on an inverted one, and labels go the other way.
  defp flip(%Span{style: %Style{modifiers: modifiers} = style} = span) do
    modifiers =
      if :reversed in modifiers,
        do: List.delete(modifiers, :reversed),
        else: [:reversed | modifiers]

    %Span{span | style: %Style{style | modifiers: modifiers}}
  end
end
