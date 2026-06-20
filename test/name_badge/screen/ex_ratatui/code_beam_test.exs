defmodule NameBadge.Screen.ExRatatui.CodeBeamTest do
  use ExUnit.Case, async: true

  alias ExRatatui.Event.Key
  alias ExRatatui.Layout.Rect
  alias ExRatatui.Style
  alias ExRatatui.Subscription
  alias ExRatatui.Text.Span
  alias ExRatatui.Widgets.{BigText, Paragraph}
  alias NameBadge.Screen.ExRatatui.CodeBeam

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

    test "ignores unmapped keys" do
      state = %{tick: 5, paused?: false}
      assert {:noreply, ^state} = CodeBeam.update({:event, key("down")}, state)
      assert {:noreply, ^state} = CodeBeam.update({:event, key("q")}, state)
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

  describe "inverted?/1" do
    test "renders normal polarity on even ticks, inverted on odd ticks" do
      refute CodeBeam.inverted?(0)
      assert CodeBeam.inverted?(1)
      refute CodeBeam.inverted?(2)
      assert CodeBeam.inverted?(3)
      refute CodeBeam.inverted?(100)
      assert CodeBeam.inverted?(101)
    end
  end

  describe "render/2 — banner" do
    test "spells HI / CODE / BEAM / EUROPE / 2026 across five centred big-text lines" do
      lines = big_text_lines(CodeBeam.render(%{tick: 0, paused?: false}, frame()))

      assert Enum.map(lines, &big_text_string/1) == ~w(HI CODE BEAM EUROPE 2026)

      for %BigText{pixel_size: pixel_size, alignment: alignment} <- lines do
        # half_height is the only narrow-enough size whose glyphs the
        # badge's 6×8 font actually has — see the design doc.
        assert pixel_size == :half_height
        assert alignment == :center
      end
    end

    test "even ticks carry no inversion fill — ink letters on paper" do
      widgets = CodeBeam.render(%{tick: 0, paused?: false}, frame())

      refute Enum.any?(widgets, &inversion_fill?/1)

      for line <- big_text_lines(widgets) do
        refute :reversed in line.style.modifiers
      end
    end

    test "odd ticks add a full-frame ink fill and reverse every line" do
      widgets = CodeBeam.render(%{tick: 1, paused?: false}, frame())

      assert [{fill, fill_rect} | _] = widgets
      assert inversion_fill?({fill, fill_rect})
      assert fill_rect.width == frame().width
      assert fill_rect.height == frame().height

      lines = big_text_lines(widgets)
      assert length(lines) == 5

      for line <- lines do
        assert :reversed in line.style.modifiers
      end
    end

    test "even and odd frames differ, so the blink is live" do
      even = CodeBeam.render(%{tick: 0, paused?: false}, frame())
      odd = CodeBeam.render(%{tick: 1, paused?: false}, frame())

      refute even == odd
    end

    test "every rect fits within the frame in both polarities" do
      for tick <- [0, 1] do
        for {_widget, rect} <- CodeBeam.render(%{tick: tick, paused?: false}, frame()) do
          assert rect.x + rect.width <= frame().width
          assert rect.y + rect.height <= frame().height
        end
      end
    end
  end

  describe "render/2 — hint" do
    test "reflects pause state" do
      running = hint_text(CodeBeam.render(%{tick: 0, paused?: false}, frame()))
      paused = hint_text(CodeBeam.render(%{tick: 0, paused?: true}, frame()))

      assert running =~ "pause"
      assert paused =~ "resume"
    end

    test "key chips render in reverse-video on a normal frame" do
      [%Span{} | _] = spans = hint_spans(CodeBeam.render(%{tick: 0, paused?: false}, frame()))

      reversed = %Style{modifiers: [:reversed]}
      assert %Span{content: " A ", style: ^reversed} = Enum.at(spans, 0)
    end

    test "the hint inverts with the rest of the panel on an odd frame" do
      normal = hint_spans(CodeBeam.render(%{tick: 0, paused?: false}, frame()))
      inverted = hint_spans(CodeBeam.render(%{tick: 1, paused?: false}, frame()))

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
  defp key(code), do: %Key{code: code, kind: "press", modifiers: []}

  defp big_text_lines(widgets) do
    for {%BigText{} = widget, _rect} <- widgets, do: widget
  end

  defp big_text_string(%BigText{lines: lines}) do
    lines
    |> Enum.flat_map(& &1.spans)
    |> Enum.map_join(& &1.content)
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
