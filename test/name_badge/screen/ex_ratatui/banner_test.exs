defmodule NameBadge.Screen.ExRatatui.BannerTest do
  use ExUnit.Case, async: true

  alias ExRatatui.CellSession
  alias ExRatatui.Event.Key
  alias ExRatatui.Frame
  alias ExRatatui.Widgets.BigText
  alias ExRatatui.Widgets.Paragraph
  alias NameBadge.Screen.ExRatatui.Banner

  doctest Banner
  doctest NameBadge.Screen.ExRatatui.Hint

  @frame %Frame{width: 66, height: 37}

  describe "init/1" do
    test "starts on the first message, running" do
      assert {:ok, %{tick: 0, paused?: false, messages: [_ | _]}} = Banner.init([])
    end

    test "takes the messages from the app opts" do
      assert {:ok, %{messages: ["ONE"]}} = Banner.init(messages: ["ONE"])
    end

    test "rejects an empty message list" do
      assert_raise ArgumentError, ~r/non-empty list/, fn -> Banner.init(messages: []) end
    end
  end

  describe "update/2" do
    setup do
      {:ok, state} = Banner.init(messages: ["ONE", "TWO"])
      %{state: state}
    end

    test "A pauses and resumes; a paused tick neither advances nor renders", %{state: state} do
      assert {:noreply, %{paused?: true} = paused} = Banner.update({:event, key("up")}, state)
      assert {:noreply, ^paused, render?: false} = Banner.update({:info, :tick}, paused)
      assert {:noreply, %{paused?: false}} = Banner.update({:event, key("up")}, paused)
    end

    test "ticks and B advance the cycle, long A goes back to the start", %{state: state} do
      assert {:noreply, %{tick: 1} = state} = Banner.update({:info, :tick}, state)
      assert {:noreply, %{tick: 2} = state} = Banner.update({:event, key("down")}, state)

      assert {:noreply, %{tick: 3}} =
               Banner.update({:event, key("down")}, %{state | paused?: true})

      assert {:noreply, %{tick: 0}} = Banner.update({:event, key("home")}, state)
    end

    test "ignores anything else without rendering", %{state: state} do
      assert {:noreply, ^state, render?: false} = Banner.update({:event, key("x")}, state)
      assert {:noreply, ^state, render?: false} = Banner.update({:info, :other}, state)
    end
  end

  test "subscribes to a 3 s tick" do
    {:ok, state} = Banner.init([])

    assert [%ExRatatui.Subscription{interval_ms: 3_000, message: :tick}] =
             Banner.subscriptions(state)
  end

  describe "render/2" do
    test "a normal step draws the message as BigText on paper" do
      {:ok, state} = Banner.init(messages: ["HI THERE"])
      widgets = Banner.render(state, @frame)

      assert [%BigText{pixel_size: :full, style: %{modifiers: []}} | _] = big_texts(widgets)
      refute Enum.any?(widgets, &ink_fill?/1)
      assert hint_text(widgets) =~ "pause"
    end

    test "an inverted step fills the frame with ink and punches the text out" do
      {:ok, state} = Banner.init(messages: ["HI THERE"])
      widgets = Banner.render(%{state | tick: 1, paused?: true}, @frame)

      assert Enum.any?(widgets, &ink_fill?/1)
      assert Enum.all?(big_texts(widgets), &(:reversed in &1.style.modifiers))
      assert hint_text(widgets) =~ "resume"
    end

    test "each message holds for a normal and an inverted step" do
      {:ok, state} = Banner.init(messages: ["ONE", "TWO"])

      texts =
        for tick <- 0..4 do
          state |> Map.put(:tick, tick) |> Banner.render(@frame) |> big_texts() |> hd()
        end

      assert Enum.map(texts, &text/1) == ["ONE", "ONE", "TWO", "TWO", "ONE"]
    end

    test "text too long for BigText falls back to a wrapped paragraph" do
      message = "a_word_far_too_long_for_big_text and more"
      {:ok, state} = Banner.init(messages: [message])
      widgets = Banner.render(state, @frame)

      assert big_texts(widgets) == []
      assert Enum.any?(widgets, &match?({%Paragraph{text: ^message, wrap: true}, _rect}, &1))
    end

    test "keeps a margin around the text" do
      {:ok, state} = Banner.init([])

      for {%BigText{}, rect} <- Banner.render(state, @frame) do
        assert rect.x >= 1 and rect.x + rect.width <= @frame.width - 1
        assert rect.y >= 2 and rect.y + rect.height <= @frame.height - 1 - 2
      end
    end

    test "every default message draws on a real cell session" do
      {:ok, state} = Banner.init([])
      session = CellSession.new(@frame.width, @frame.height)

      for tick <- 0..(2 * length(state.messages) - 1) do
        assert :ok = CellSession.draw(session, Banner.render(%{state | tick: tick}, @frame))
      end

      CellSession.close(session)
    end
  end

  describe "fit/3" do
    test "picks smaller sizes as the text grows" do
      assert {:full, _} = Banner.fit("HELLO", 66, 36)

      assert {:half_width, ["WELCOME TO THE", "ELIXIR TUI TALK"]} =
               Banner.fit("WELCOME TO THE ELIXIR TUI TALK", 66, 20)

      # Five 8-letter words: one per line at both 8 and 16 characters per line, too many rows at 8 tall.
      assert {:half_height, lines} = Banner.fit(String.duplicate("BEAMBEAM ", 5), 66, 36)
      assert length(lines) == 5

      assert {:quadrant, _} =
               Banner.fit("A LONGER SENTENCE THAT NEEDS SMALL LETTERS TO FIT HERE", 66, 24)
    end

    test "keeps blank lines from explicit line breaks" do
      assert {:full, ["HI", "", "THERE"]} = Banner.fit("HI\n\nTHERE", 66, 36)
    end
  end

  test "NameBadge.Screen.Banner hosts the app from the menu" do
    {:ok, _} = Application.ensure_all_started(:telemetry)
    screen = %NameBadge.Screen{module: NameBadge.Screen.Banner}

    {:ok, screen} = NameBadge.Screen.Banner.mount([], screen)

    assert Process.alive?(RasterExRatatui.Session.server(screen.assigns.session))
    assert :ok = NameBadge.Screen.Banner.terminate(:normal, screen)
  end

  defp key(code), do: %Key{code: code, kind: "press", modifiers: []}

  defp big_texts(widgets), do: for({%BigText{} = widget, _rect} <- widgets, do: widget)

  defp text(%BigText{lines: lines}) do
    Enum.map_join(lines, "\n", fn line -> Enum.map_join(line.spans, & &1.content) end)
  end

  defp ink_fill?({%Paragraph{text: "", style: %{bg: :black}}, _rect}), do: true
  defp ink_fill?(_widget), do: false

  defp hint_text(widgets) do
    {%Paragraph{text: line}, _rect} = List.last(widgets)
    Enum.map_join(line.spans, & &1.content)
  end
end
