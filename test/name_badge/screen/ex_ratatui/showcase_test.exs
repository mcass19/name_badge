defmodule NameBadge.Screen.ExRatatui.ShowcaseTest do
  use ExUnit.Case, async: true

  alias ExRatatui.CellSession
  alias ExRatatui.CellSession.Region
  alias ExRatatui.Event.Key
  alias ExRatatui.Frame
  alias ExRatatui.ThreeD.Scene
  alias ExRatatui.Widgets.Image
  alias ExRatatui.Widgets.Paragraph
  alias ExRatatui.Widgets.Sparkline
  alias ExRatatui.Widgets.Viewport3D
  alias NameBadge.Screen.ExRatatui.Showcase

  doctest Showcase

  @frame %Frame{width: 66, height: 37}

  setup do
    {:ok, state} = Showcase.init([])
    %{state: state}
  end

  describe "init/1" do
    test "starts spinning a cube with the first photo", %{state: state} do
      assert %{shape: :cube, angle: +0.0, paused?: false, photo: 0, reductions: [], memory: []} =
               state

      assert [{%Image{state: ref}, "Thomas Lefebvre"} | _] = state.photos
      assert length(state.photos) == 3
      assert is_reference(ref)
      assert %{processes: _, memory: _, reductions: _, run_queue: _, uptime_ms: _} = state.stats
    end
  end

  describe "update/2" do
    test "A cycles the object and long A cycles the photo", %{state: state} do
      assert {:noreply, %{shape: :orbit}} = Showcase.update({:event, key("up")}, state)

      assert {:noreply, %{photo: 1} = state} = Showcase.update({:event, key("home")}, state)
      assert {:noreply, %{photo: 2} = state} = Showcase.update({:event, key("home")}, state)
      assert {:noreply, %{photo: 0}} = Showcase.update({:event, key("home")}, state)
    end

    test "B pauses ticks, and a paused tick does not render", %{state: state} do
      assert {:noreply, %{paused?: true} = paused} = Showcase.update({:event, key("down")}, state)
      assert {:noreply, ^paused, render?: false} = Showcase.update({:info, :tick}, paused)
    end

    test "a tick turns the object and samples the VM", %{state: state} do
      assert {:noreply, ticked} = Showcase.update({:info, :tick}, state)

      assert ticked.angle > state.angle
      assert [_reductions] = ticked.reductions
      assert [_memory] = ticked.memory
    end

    test "ignores anything else without rendering", %{state: state} do
      assert {:noreply, ^state, render?: false} = Showcase.update({:info, :other}, state)
    end
  end

  test "subscribes to a 2 s tick", %{state: state} do
    assert [%ExRatatui.Subscription{interval_ms: 2_000, message: :tick}] =
             Showcase.subscriptions(state)
  end

  describe "tick/2" do
    test "records reduction deltas and memory, keeping a bounded history", %{state: state} do
      state =
        Enum.reduce(1..70, state, fn i, state ->
          Showcase.tick(state, %{
            state.stats
            | reductions: state.stats.reductions + i,
              memory: i * 1024
          })
        end)

      assert length(state.reductions) == 64
      assert List.last(state.reductions) == 70
      assert List.last(state.memory) == 70
    end
  end

  describe "render/2" do
    test "draws a 3D viewport, the image, and the BEAM panel for every object", %{state: state} do
      state = Showcase.tick(state, state.stats)

      for shape <- [:cube, :orbit, :cylinder] do
        widgets = Showcase.render(%{state | shape: shape}, @frame)

        assert [%Viewport3D{scene: %Scene{objects: [_ | _]}}] =
                 for({%Viewport3D{} = w, _} <- widgets, do: w)

        assert [_image] = for({%Image{} = w, _} <- widgets, do: w)
        assert [_, _] = for({%Sparkline{} = w, _} <- widgets, do: w)
        assert Enum.any?(widgets, &match?({%Paragraph{text: "procs " <> _}, _}, &1))
      end
    end

    test "on the badge's pixel surface the viewport and image arrive as two regions", %{
      state: state
    } do
      session = CellSession.new(@frame.width, @frame.height, font_size: {6, 8})

      :ok = CellSession.draw(session, Showcase.render(state, @frame))
      snapshot = CellSession.take_cells(session)
      CellSession.close(session)

      # Each pane's inner area is 31×18 cells.
      assert [%Region{} = viewport, %Region{} = image] = snapshot.regions
      assert {viewport.width, viewport.height} == {31, 18}
      assert {image.width, image.height} == {31, 18}
      assert viewport.pixel_width > 0 and image.pixel_width > 0
    end

    test "the hint says resume while paused", %{state: state} do
      {%Paragraph{text: line}, _rect} =
        state |> Map.put(:paused?, true) |> Showcase.render(@frame) |> List.last()

      assert Enum.map_join(line.spans, & &1.content) =~ "resume"
    end
  end

  test "the image pane credits the photographer of the photo on screen", %{state: state} do
    titles =
      for photo <- 0..2 do
        widgets = Showcase.render(%{state | photo: photo}, @frame)
        for {%ExRatatui.Widgets.Block{title: title}, _} <- widgets, title =~ "Unsplash", do: title
      end

    assert titles == [
             [" Thomas Lefebvre / Unsplash "],
             [" Andre Spieker / Unsplash "],
             [" Jennifer Trovato / Unsplash "]
           ]
  end

  defp key(code), do: %Key{code: code, kind: "press", modifiers: []}
end
