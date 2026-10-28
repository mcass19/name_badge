defmodule NameBadge.Screen.ExRatatui do
  @moduledoc """
  `NameBadge.Screen` host for an `ExRatatui.App`: runs the app on the 400×300 panel with a `RasterExRatatui.Session` and turns badge buttons into key events.

  ## Wiring

      ExRatatui.App
            │
            ▼
      RasterExRatatui.Session (started in `mount/2`, from the screen's own process)
            │  every render arrives as a message
            ▼
      handle_info/2 → Session.handle/2 → the kept gray8 frame, Session.frame/1
            │
            ▼
      assign(screen, :frame, frame) → render/1 → Dither image → Display.render_png/2

  The raster is `RasterExRatatui.Raster` with the `RasterExRatatui.Font.Default6x8` font and the `RasterExRatatui.PixelFormat.Mono` format: a 66×37 cell grid whose cells are 6×8 pixels. The session creates the cell session with that cell size, so pixel-mode widgets (`ExRatatui.Widgets.Viewport3D`, `ExRatatui.Widgets.Image`) arrive as real bitmaps and are ordered-dithered onto the panel.

  Everything runs inside the screen's own process rather than a `RasterExRatatui.Surface`: `NameBadge.Screen` already owns rendering, refresh dedupe, and navigation, and a crashed app must leave a crash frame on the panel instead of taking the screen down. `Session.handle/2` folds every render waiting in the mailbox into one, so a slow e-ink refresh always shows the latest frame.

  ## Mount args

      mount: [
        app: MyTui,       # required; the module must `use ExRatatui.App`
        app_opts: [],     # optional, forwarded to the app's mount/1 or init/1
        key_map: %{...}   # optional, overrides the button mapping below
      ]

  ## Default key map

  | Badge input      | `ExRatatui.Event.Key` |
  | ---------------- | --------------------- |
  | A (single press) | `code: "up"`          |
  | A (long press)   | `code: "home"`        |
  | B (single press) | `code: "down"`        |
  | B (long press)   | intercepted by `NameBadge.Screen` (back to the menu) |

  A `:key_map` is keyed by `{:button_1 | :button_2, :single_press | :long_press}` with `t:ExRatatui.Event.Key.t/0` values.
  """

  use NameBadge.Screen

  require Logger

  alias ExRatatui.CellSession
  alias ExRatatui.Event.Key
  alias ExRatatui.Layout.Rect
  alias ExRatatui.Widgets.Paragraph
  alias RasterExRatatui.Font.Default6x8
  alias RasterExRatatui.PixelFormat.Mono
  alias RasterExRatatui.Raster
  alias RasterExRatatui.Session

  @display_size {400, 300}

  # The app normally draws its first frame while it starts. Waiting a little
  # for it seeds the screen with real content instead of a blank frame that
  # flickers on every screen switch.
  @initial_frame_timeout 100

  @default_key_map %{
    {:button_1, :single_press} => %Key{code: "up", kind: "press", modifiers: []},
    {:button_1, :long_press} => %Key{code: "home", kind: "press", modifiers: []},
    {:button_2, :single_press} => %Key{code: "down", kind: "press", modifiers: []}
  }

  @doc """
  Returns an empty raster for the badge panel: 400×300 pixels, 6×8 cells, 1-bit tones.
  """
  @spec raster() :: Raster.t()
  def raster, do: Raster.new(size: @display_size, font: Default6x8, format: Mono)

  @impl NameBadge.Screen
  def mount(args, screen) do
    app_mod = Keyword.fetch!(args, :app)
    app_opts = Keyword.get(args, :app_opts, [])
    key_map = Keyword.get(args, :key_map, @default_key_map)

    ensure_ex_ratatui_app!(app_mod)

    # The app server is linked to the screen; trapping its exit turns a
    # crash into a crash frame, and keeps long-press B working.
    Process.flag(:trap_exit, true)

    {:ok, session} =
      Session.start(raster(), app: app_mod, app_opts: app_opts, keep_frame: true)

    screen = screen |> assign(:key_map, key_map) |> assign(:session, session)

    case Session.await(session, @initial_frame_timeout) do
      {:render, _patches, session} -> {:ok, shown(screen, session)}
      {:timeout, session} -> {:ok, shown(screen, session)}
      {:exit, reason, session} -> {:ok, crashed(screen, session, reason)}
    end
  end

  @impl NameBadge.Screen
  def render(assigns) do
    {width, height} = @display_size
    Dither.from_raw!(assigns.frame, width, height)
  end

  @impl NameBadge.Screen
  def handle_button(button, press_type, screen) do
    # Once the app has crashed the session has no server and this is a no-op;
    # long-press B still goes back, NameBadge.Screen intercepts it.
    case Map.fetch(screen.assigns.key_map, {button, press_type}) do
      {:ok, %Key{} = event} -> Session.send_event(screen.assigns.session, event)
      :error -> :ok
    end

    {:noreply, screen}
  end

  @impl NameBadge.Screen
  def handle_info(message, screen) do
    case Session.handle(screen.assigns.session, message) do
      {:render, _patches, session} -> {:noreply, shown(screen, session)}
      {:exit, reason, session} -> {:noreply, crashed(screen, session, reason)}
      :unknown -> {:noreply, screen}
    end
  end

  @impl NameBadge.Screen
  def terminate(_reason, screen) do
    if session = screen.assigns[:session], do: Session.stop(session)
    :ok
  end

  defp shown(screen, session) do
    screen |> assign(:session, session) |> assign(:frame, Session.frame(session))
  end

  defp crashed(screen, session, reason) do
    Logger.error("ExRatatui app crashed: #{inspect(reason)}")
    screen |> assign(:session, session) |> assign(:frame, crash_frame())
  end

  defp crash_frame do
    raster = raster()
    {cols, rows} = Raster.grid_size(raster)
    session = CellSession.new(cols, rows)
    mid = div(rows, 2)

    :ok =
      CellSession.draw(session, [
        {%Paragraph{text: "TUI CRASHED", alignment: :center},
         %Rect{x: 0, y: mid - 1, width: cols, height: 1}},
        {%Paragraph{text: "LONG-PRESS B FOR MENU", alignment: :center},
         %Rect{x: 0, y: mid + 1, width: cols, height: 1}}
      ])

    snapshot = CellSession.take_cells(session)
    :ok = CellSession.close(session)

    {raster, _patches} = Raster.apply(raster, snapshot)
    Raster.frame(raster)
  end

  defp ensure_ex_ratatui_app!(app_mod) do
    case Code.ensure_loaded(app_mod) do
      {:module, ^app_mod} ->
        if not function_exported?(app_mod, :__runtime__, 0) do
          raise ArgumentError,
                "#{inspect(app_mod)} does not export __runtime__/0: `use ExRatatui.App` " <>
                  "instead of only declaring `@behaviour ExRatatui.App`"
        end

      {:error, _reason} ->
        raise ArgumentError, "app module #{inspect(app_mod)} could not be loaded"
    end
  end

  @doc """
  Defines a menu-facing `NameBadge.Screen` that hosts a fixed `ExRatatui.App`, since `NameBadge.ScreenManager.navigate/1` carries no mount args.

      defmodule NameBadge.Screen.Banner do
        use NameBadge.Screen.ExRatatui, app: NameBadge.Screen.ExRatatui.Banner
      end

  Accepts the mount args documented above: `:app` (required), `:app_opts`, and `:key_map`.
  """
  defmacro __using__(opts) do
    quote bind_quoted: [opts: opts] do
      use NameBadge.Screen

      @host_args Keyword.take(opts, [:app, :app_opts, :key_map])

      @impl NameBadge.Screen
      def mount(_args, screen), do: NameBadge.Screen.ExRatatui.mount(@host_args, screen)

      @impl NameBadge.Screen
      defdelegate render(assigns), to: NameBadge.Screen.ExRatatui

      @impl NameBadge.Screen
      defdelegate handle_button(button, press_type, screen), to: NameBadge.Screen.ExRatatui

      @impl NameBadge.Screen
      defdelegate handle_info(message, screen), to: NameBadge.Screen.ExRatatui

      @impl NameBadge.Screen
      defdelegate terminate(reason, screen), to: NameBadge.Screen.ExRatatui
    end
  end
end
