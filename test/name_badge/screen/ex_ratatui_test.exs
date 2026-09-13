defmodule NameBadge.Screen.ExRatatuiTest do
  use ExUnit.Case, async: true

  import ExUnit.CaptureLog

  alias ExRatatui.CellSession
  alias ExRatatui.CellSession.Cell
  alias ExRatatui.CellSession.Diff
  alias ExRatatui.CellSession.Region
  alias ExRatatui.Event.Key
  alias NameBadge.Screen
  alias NameBadge.Screen.ExRatatui, as: Host
  alias RasterExRatatui.Raster
  alias RasterExRatatui.Session

  # The crash tests make app servers raise; their reports are expected noise.
  @moduletag :capture_log

  @frame_bytes 400 * 300

  defmodule HelloApp do
    @moduledoc false
    use ExRatatui.App

    alias ExRatatui.Layout.Rect
    alias ExRatatui.Widgets.Paragraph

    @impl true
    def mount(opts) do
      if pid = opts[:notify], do: send(pid, {:mounted, opts})
      {:ok, %{text: "HI"}}
    end

    @impl true
    def render(state, frame) do
      [{%Paragraph{text: state.text}, %Rect{x: 0, y: 0, width: frame.width, height: 1}}]
    end

    @impl true
    def handle_event(%Key{code: "down"}, state), do: {:noreply, %{state | text: "BYE"}}
    def handle_event(%Key{code: "home"}, _state), do: raise("boom")
    def handle_event(_event, state), do: {:noreply, state}
  end

  defmodule CubeApp do
    @moduledoc false
    use ExRatatui.App

    alias ExRatatui.Layout.Rect
    alias ExRatatui.ThreeD.{Light, Material, Mesh, Object, Scene}
    alias ExRatatui.Widgets.Viewport3D

    @impl true
    def mount(_opts), do: {:ok, %{}}

    @impl true
    def render(_state, frame) do
      scene = %Scene{
        objects: [%Object{mesh: Mesh.cube(), material: %Material{color: {128, 128, 128}}}],
        lights: [Light.ambient({255, 255, 255}, 1.0)],
        background: {255, 255, 255}
      }

      [
        {%Viewport3D{scene: scene, render_mode: :auto},
         %Rect{x: 0, y: 0, width: frame.width, height: frame.height}}
      ]
    end

    @impl true
    def handle_event(_event, state), do: {:noreply, state}
  end

  defmodule CrashOnMountApp do
    @moduledoc false
    use ExRatatui.App

    alias ExRatatui.Layout.Rect
    alias ExRatatui.Widgets.Paragraph

    # Mounts without drawing, then crashes on its first message: the exit
    # is the first thing the screen hears from it.
    @impl true
    def mount(_opts) do
      send(self(), :crash)
      {:ok, %{}, render?: false}
    end

    @impl true
    def render(_state, frame),
      do: [{%Paragraph{text: "x"}, %Rect{x: 0, y: 0, width: frame.width, height: 1}}]

    @impl true
    def handle_info(:crash, _state), do: raise("boom at start")

    @impl true
    def handle_event(_event, state), do: {:noreply, state}
  end

  defmodule MerelyBehaviourApp do
    @moduledoc false
    # Declares the behaviour without `use ExRatatui.App`, so __runtime__/0 is missing.
    @behaviour ExRatatui.App

    @impl true
    def mount(_opts), do: {:ok, %{}}

    @impl true
    def render(_state, _frame), do: []

    @impl true
    def handle_event(_event, state), do: {:noreply, state}
  end

  defmodule HelloScreen do
    @moduledoc false
    use NameBadge.Screen.ExRatatui, app: NameBadge.Screen.ExRatatuiTest.HelloApp
  end

  setup do
    {:ok, _} = Application.ensure_all_started(:telemetry)
    :ok
  end

  describe "raster/0" do
    test "is the badge panel: 400×300 pixels in 66×37 cells of 6×8" do
      raster = Host.raster()

      assert Raster.size(raster) == {400, 300}
      assert Raster.grid_size(raster) == {66, 37}
      assert Raster.font_size(raster) == {6, 8}
    end
  end

  describe "mount/2 against a real server" do
    test "seeds the frame with the app's first render" do
      screen = mount!(HelloApp)

      assert Process.alive?(Session.server(screen.assigns.session))
      assert byte_size(screen.assigns.frame) == @frame_bytes
      assert screen.assigns.frame != Raster.frame(Host.raster())
      assert screen.assigns.frame == Raster.frame(Session.raster(screen.assigns.session))
      assert ink?(screen.assigns.frame)
    end

    test "hands the app its mount options and the panel" do
      mount!(HelloApp, app_opts: [notify: self()])

      assert_receive {:mounted, opts}
      assert opts[:notify] == self()
      assert %{size: {400, 300}, grid_size: {66, 37}, cell_size: {6, 8}} = opts[:surface]
    end

    test "creates a pixel surface: a Viewport3D arrives as a region at the panel's resolution" do
      screen = mount!(CubeApp)

      assert [%Region{} = region] = Raster.grid(Session.raster(screen.assigns.session)).regions
      assert {region.pixel_width, region.pixel_height} == {66 * 6, 37 * 8}
      assert ink?(screen.assigns.frame)
    end

    test "an app that dies before its first frame leaves the crash frame at mount" do
      screen = mount!(CrashOnMountApp)

      assert Session.server(screen.assigns.session) == nil
      assert ink?(screen.assigns.frame)
      assert screen.assigns.frame != Raster.frame(Host.raster())
    end

    test "a key press flows back as a render that changes the frame" do
      screen = mount!(HelloApp)

      assert {:noreply, ^screen} = Host.handle_button(:button_2, :single_press, screen)
      assert_receive {Session, _ref, %Diff{}} = message, 1_000

      assert {:noreply, updated} = Host.handle_info(message, screen)
      assert updated.assigns.frame != screen.assigns.frame
    end

    test "render/1 hands NameBadge.Screen a 400×300 Dither image" do
      screen = mount!(HelloApp)

      image = Host.render(screen.assigns)

      assert is_reference(image)
      assert Dither.dimensions(image) == {400, 300}
    end

    test "raises when the app module does not `use ExRatatui.App`" do
      assert_raise ArgumentError, ~r/does not export __runtime__\/0/, fn ->
        Host.mount([app: MerelyBehaviourApp], %Screen{module: Host})
      end
    end

    test "raises when the app module cannot be loaded" do
      assert_raise ArgumentError, ~r/could not be loaded/, fn ->
        Host.mount([app: NotAModule.At.All], %Screen{module: Host})
      end
    end
  end

  describe "handle_button/3" do
    test "maps A, long A, and B to up, home, and down" do
      screen = pointed_at_self(mount!(HelloApp))

      Host.handle_button(:button_1, :single_press, screen)
      Host.handle_button(:button_1, :long_press, screen)
      Host.handle_button(:button_2, :single_press, screen)

      assert_received {:ex_ratatui_event, %Key{code: "up", kind: "press", modifiers: []}}
      assert_received {:ex_ratatui_event, %Key{code: "home", kind: "press"}}
      assert_received {:ex_ratatui_event, %Key{code: "down", kind: "press"}}
    end

    test "ignores buttons outside the key map" do
      screen = pointed_at_self(mount!(HelloApp))

      assert {:noreply, ^screen} = Host.handle_button(:button_2, :long_press, screen)
      refute_received {:ex_ratatui_event, _}
    end

    test "honours a custom key map from the mount args" do
      key_map = %{{:button_1, :single_press} => %Key{code: "left", kind: "press", modifiers: []}}
      screen = pointed_at_self(mount!(HelloApp, key_map: key_map))

      Host.handle_button(:button_1, :single_press, screen)

      assert_received {:ex_ratatui_event, %Key{code: "left"}}
    end

    test "is a no-op once the app has crashed" do
      screen = crash!(mount!(HelloApp))

      assert {:noreply, ^screen} = Host.handle_button(:button_1, :single_press, screen)
      refute_received {:ex_ratatui_event, _}
    end
  end

  describe "handle_info/2" do
    test "folds every queued render into one frame update" do
      screen = mount!(HelloApp)
      ref = screen.assigns.session.ref

      send(self(), {Session, ref, diff([%Cell{col: 1, symbol: "B"}])})
      send(self(), {Session, ref, diff([%Cell{col: 2, symbol: "C"}])})

      assert {:noreply, updated} =
               Host.handle_info({Session, ref, diff([%Cell{symbol: "A"}])}, screen)

      refute_received {Session, ^ref, _diff}

      raster = Session.raster(updated.assigns.session)
      cells = Raster.grid(raster).cells
      assert %{{0, 0} => %Cell{symbol: "A"}, {1, 0} => %Cell{symbol: "B"}} = cells
      assert %Cell{symbol: "C"} = cells[{2, 0}]
      assert updated.assigns.frame == Raster.frame(raster)
    end

    test "the app crashing shows the crash frame and ends the session" do
      screen = mount!(HelloApp)
      server = Session.server(screen.assigns.session)

      log = capture_log(fn -> send(self(), {:crashed, crash!(screen)}) end)

      assert_received {:crashed, updated}
      refute Process.alive?(server)
      assert Session.server(updated.assigns.session) == nil
      assert byte_size(updated.assigns.frame) == @frame_bytes
      assert ink?(updated.assigns.frame)
      assert updated.assigns.frame != screen.assigns.frame
      assert log =~ "ExRatatui app crashed"
    end

    test "ignores EXITs from other processes and unrelated messages" do
      screen = mount!(HelloApp)

      assert {:noreply, ^screen} =
               Host.handle_info({:EXIT, spawn(fn -> :ok end), :normal}, screen)

      assert {:noreply, ^screen} = Host.handle_info(:something_else, screen)
    end
  end

  describe "terminate/2" do
    test "stops the server and closes the cell session" do
      screen = mount!(HelloApp)
      session = screen.assigns.session
      server = Session.server(session)

      assert :ok = Host.terminate(:normal, screen)

      refute Process.alive?(server)
      assert {:error, _} = CellSession.draw(session.cell_session, [])
    end

    test "is safe after a crash, and without a session" do
      assert :ok = Host.terminate(:normal, crash!(mount!(HelloApp)))
      assert :ok = Host.terminate(:normal, %Screen{module: Host, assigns: %{}})
    end
  end

  describe "use NameBadge.Screen.ExRatatui" do
    test "defines a screen that mounts its app without mount args and delegates to the host" do
      {:ok, screen} = HelloScreen.mount([], %Screen{module: HelloScreen})
      server = Session.server(screen.assigns.session)

      assert Process.alive?(server)
      assert is_reference(HelloScreen.render(screen.assigns))

      assert {:noreply, ^screen} = HelloScreen.handle_button(:button_2, :single_press, screen)
      assert_receive {Session, _ref, %Diff{}} = message, 1_000
      assert {:noreply, updated} = HelloScreen.handle_info(message, screen)
      assert updated.assigns.frame != screen.assigns.frame

      assert :ok = HelloScreen.terminate(:normal, updated)
      refute Process.alive?(server)
    end
  end

  # The server is linked to the test process (the screen's stand-in), which
  # traps exits after mount, so a crash arrives as a message.
  defp mount!(app, args \\ []) do
    {:ok, screen} = Host.mount([app: app] ++ args, %Screen{module: Host})
    screen
  end

  # The app raises on "home"; the host folds the EXIT into the crash frame.
  defp crash!(screen) do
    server = Session.server(screen.assigns.session)
    Session.send_event(screen.assigns.session, %Key{code: "home", kind: "press"})
    assert_receive {:EXIT, ^server, _reason} = exit, 1_000
    {:noreply, screen} = Host.handle_info(exit, screen)
    screen
  end

  # Points the session's server at the test process to see what the host sends.
  defp pointed_at_self(screen), do: put_in(screen.assigns.session.server, self())

  defp diff(ops), do: %Diff{width: 66, height: 37, ops: ops}

  defp ink?(frame), do: :binary.match(frame, <<0>>) != :nomatch
end
