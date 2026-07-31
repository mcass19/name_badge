defmodule NameBadge.Screen.ExRatatui.CodeBeamTest do
  use ExUnit.Case, async: true

  alias ExRatatui.Event.Key
  alias ExRatatui.Layout.Rect
  alias ExRatatui.Style
  alias ExRatatui.Subscription
  alias ExRatatui.Text.Span
  alias ExRatatui.Widgets.{BigText, Paragraph}
  alias NameBadge.Screen.ExRatatui.CodeBeam

  @banner ~w(HI CODE BEAM EUROPE 2026!)
  @card ["I'M", "A TUI", ":)"]

  describe "init/1" do
    test "starts at tick 0 and unpaused" do
      assert {:ok, %{tick: 0, paused?: false}} = CodeBeam.init([])
    end
  end

  describe "update/2 — events" do
    test "A (up) toggles paused?" do
      assert {:noreply, %{paused?: true}} =
               CodeBeam.update({:event, key("up")}, %{tick: 7, paused?: false})

      assert {:noreply, %{paused?: false}} =
               CodeBeam.update({:event, key("up")}, %{tick: 7, paused?: true})
    end

    test "A long (home) resets tick to 0, leaving pause state untouched" do
      assert {:noreply, %{tick: 0, paused?: false}} =
               CodeBeam.update({:event, key("home")}, %{tick: 99, paused?: false})

      assert {:noreply, %{tick: 0, paused?: true}} =
               CodeBeam.update({:event, key("home")}, %{tick: 99, paused?: true})
    end

    test "B (down) advances one phase, even while paused" do
      assert {:noreply, %{tick: 6, paused?: false}} =
               CodeBeam.update({:event, key("down")}, %{tick: 5, paused?: false})

      # Pausing the automatic cycle and stepping it by hand is the
      # point of the manual advance, so paused? must not block it.
      assert {:noreply, %{tick: 6, paused?: true}} =
               CodeBeam.update({:event, key("down")}, %{tick: 5, paused?: true})
    end

    test "ignores unmapped keys" do
      state = %{tick: 5, paused?: false}
      assert {:noreply, ^state} = CodeBeam.update({:event, key("q")}, state)
      assert {:noreply, ^state} = CodeBeam.update({:event, key("left")}, state)
    end
  end

  describe "update/2 — ticks" do
    test "tick advances when not paused" do
      assert {:noreply, %{tick: 1}} =
               CodeBeam.update({:info, :tick}, %{tick: 0, paused?: false})

      assert {:noreply, %{tick: 43}} =
               CodeBeam.update({:info, :tick}, %{tick: 42, paused?: false})
    end

    test "tick is a no-op when paused" do
      assert {:noreply, %{tick: 42}} =
               CodeBeam.update({:info, :tick}, %{tick: 42, paused?: true})
    end

    test "ignores unrelated info messages" do
      state = %{tick: 1, paused?: false}
      assert {:noreply, ^state} = CodeBeam.update({:info, :unrelated}, state)
    end
  end

  describe "subscriptions/1" do
    test "registers a hardware-friendly tick subscription with a stable id" do
      assert [
               %Subscription{
                 id: :code_beam_tick,
                 kind: :interval,
                 interval_ms: interval,
                 message: :tick
               }
             ] = CodeBeam.subscriptions(%{tick: 0, paused?: false})

      # The whole-screen invert must clear the badge's UC8276
      # partial-refresh budget (≈ 350 ms) with margin so frames don't
      # queue on hardware.
      assert interval >= 700
    end
  end

  describe "the four-phase cycle" do
    test "inverted?/1 renders normal polarity on even ticks, inverted on odd ticks" do
      refute CodeBeam.inverted?(0)
      assert CodeBeam.inverted?(1)
      refute CodeBeam.inverted?(2)
      assert CodeBeam.inverted?(3)
      refute CodeBeam.inverted?(100)
      assert CodeBeam.inverted?(101)
    end

    test "message_index/1 holds each message for two consecutive ticks" do
      assert Enum.map(0..9, &CodeBeam.message_index/1) == [0, 0, 1, 1, 0, 0, 1, 1, 0, 0]
    end

    test "each message is shown in both polarities within one cycle" do
      phases = for tick <- 0..3, do: {CodeBeam.message_index(tick), CodeBeam.inverted?(tick)}

      # This is the property the whole design rests on: a two-phase
      # swap would strand pixels that fall inside one message's letters
      # but not the other's, and partial refresh never drives them.
      assert Enum.sort(phases) == [{0, false}, {0, true}, {1, false}, {1, true}]
    end
  end

  describe "render/2 — messages" do
    test "the banner spells HI / CODE / BEAM / EUROPE / 2026! at :half_height" do
      for tick <- [0, 1] do
        lines = big_text_lines(render(tick))

        assert Enum.map(lines, &big_text_string/1) == @banner

        for %BigText{pixel_size: pixel_size, alignment: alignment} <- lines do
          # :half_height and :full are the only sizes whose block glyphs
          # the badge's 6×8 font actually has — see the moduledoc.
          assert pixel_size == :half_height
          assert alignment == :center
        end
      end
    end

    test "the card spells I'M / A TUI / :) at :full" do
      for tick <- [2, 3] do
        lines = big_text_lines(render(tick))

        assert Enum.map(lines, &big_text_string/1) == @card

        for %BigText{pixel_size: pixel_size, alignment: alignment} <- lines do
          assert pixel_size == :full
          assert alignment == :center
        end
      end
    end

    test "every line uses a plain ASCII apostrophe, which the 6×8 font has" do
      refute Enum.any?(@banner ++ @card, &String.contains?(&1, "’"))
    end

    test "no line exceeds the 8-character cap that 8-cells-per-glyph imposes" do
      for line <- @banner ++ @card do
        assert String.length(line) <= 8, "#{inspect(line)} is wider than the 66-cell panel"
      end
    end
  end

  describe "render/2 — polarity" do
    test "even ticks carry no inversion fill — ink letters on paper" do
      for tick <- [0, 2] do
        widgets = render(tick)

        refute Enum.any?(widgets, &inversion_fill?/1)

        for line <- big_text_lines(widgets) do
          refute :reversed in line.style.modifiers
        end
      end
    end

    test "odd ticks add a full-frame ink fill and reverse every line" do
      for {tick, expected_lines} <- [{1, 5}, {3, 3}] do
        widgets = render(tick)

        assert [{fill, fill_rect} | _] = widgets
        assert inversion_fill?({fill, fill_rect})
        assert fill_rect.width == frame().width
        assert fill_rect.height == frame().height

        lines = big_text_lines(widgets)
        assert length(lines) == expected_lines

        for line <- lines do
          assert :reversed in line.style.modifiers
        end
      end
    end

    test "all four phases render differently, so the cycle is live" do
      frames = for tick <- 0..3, do: render(tick)

      assert frames |> Enum.uniq() |> length() == 4
    end

    test "the cycle repeats every four ticks" do
      for tick <- 0..3 do
        assert render(tick) == render(tick + 4)
      end
    end
  end

  describe "render/2 — geometry" do
    test "every rect fits within the frame in all four phases" do
      for tick <- 0..3 do
        for {_widget, rect} <- render(tick) do
          assert rect.x + rect.width <= frame().width
          assert rect.y + rect.height <= frame().height
        end
      end
    end

    test "message lines stay clear of the hint row" do
      hint_row = frame().height - 1

      for tick <- 0..3 do
        for {%BigText{}, rect} <- render(tick) do
          assert rect.y + rect.height <= hint_row
        end
      end
    end

    test "both messages carry comparable vertical weight" do
      banner = text_block_height(render(0))
      card = text_block_height(render(2))

      assert banner == 24
      assert card == 26
    end
  end

  describe "render/2 — hint" do
    test "reflects pause state" do
      running = hint_text(render(0))
      paused = hint_text(CodeBeam.render(%{tick: 0, paused?: true}, frame()))

      assert running =~ "pause"
      assert paused =~ "resume"
    end

    test "advertises the manual advance" do
      assert hint_text(render(0)) =~ "next"
    end

    test "fits inside the hint strip" do
      strip_width = frame().width - 4

      assert String.length(hint_text(render(0))) <= strip_width

      assert String.length(hint_text(CodeBeam.render(%{tick: 0, paused?: true}, frame()))) <=
               strip_width
    end

    test "key chips render in reverse-video on a normal frame" do
      [%Span{} | _] = spans = hint_spans(render(0))

      reversed = %Style{modifiers: [:reversed]}
      assert %Span{content: " A ", style: ^reversed} = Enum.at(spans, 0)
    end

    test "the hint inverts with the rest of the panel on an odd frame" do
      normal = hint_spans(render(0))
      inverted = hint_spans(render(1))

      # Same text, opposite polarity: a chip that is reverse-video on
      # the normal frame is plain on the inverted frame, and vice versa.
      assert Enum.map(normal, & &1.content) == Enum.map(inverted, & &1.content)

      normal_a = Enum.find(normal, &(&1.content == " A "))
      inverted_a = Enum.find(inverted, &(&1.content == " A "))
      assert :reversed in normal_a.style.modifiers
      refute :reversed in inverted_a.style.modifiers
    end
  end

  defp frame, do: %Rect{x: 0, y: 0, width: 66, height: 37}
  defp render(tick), do: CodeBeam.render(%{tick: tick, paused?: false}, frame())
  defp key(code), do: %Key{code: code, kind: "press", modifiers: []}

  defp big_text_lines(widgets) do
    for {%BigText{} = widget, _rect} <- widgets, do: widget
  end

  defp big_text_string(%BigText{lines: lines}) do
    lines
    |> Enum.flat_map(& &1.spans)
    |> Enum.map_join(& &1.content)
  end

  # Top of the first line to the bottom of the last, gaps included.
  defp text_block_height(widgets) do
    rects = for {%BigText{}, rect} <- widgets, do: rect
    tops = Enum.map(rects, & &1.y)
    bottoms = Enum.map(rects, &(&1.y + &1.height))

    Enum.max(bottoms) - Enum.min(tops)
  end

  # The inversion fill is the only Paragraph whose style paints an ink
  # background across its whole rect.
  defp inversion_fill?({%Paragraph{style: %Style{bg: :black}}, _rect}), do: true
  defp inversion_fill?(_), do: false

  defp hint_paragraph(widgets) do
    [paragraph] =
      for {%Paragraph{style: %Style{bg: bg}} = p, _rect} <- widgets, bg != :black, do: p

    paragraph
  end

  defp hint_spans(widgets), do: hint_paragraph(widgets).text

  defp hint_text(widgets) do
    widgets |> hint_spans() |> Enum.map_join(& &1.content)
  end
end
