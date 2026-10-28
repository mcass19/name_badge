defmodule NameBadge.Screen.ExRatatui.Showcase do
  @moduledoc """
  Pixel regions on a 1-bit badge: a spinning, shaded 3D object and a photo drawn as real bitmaps next to a live BEAM dashboard made of ordinary cells.

      ┌ 3D cube ──────────────────────┐┌ Thomas Lefebvre / Unsplash ───┐
      │                               ││                               │
      │    Viewport3D pixel region    ││   Image pixel region (photo)  │
      │                               ││                               │
      └───────────────────────────────┘└───────────────────────────────┘
      ┌ BEAM ────────────────────────────────────────────────────────────┐
      │ procs 312   mem 42.1 MB   run queue 0   up 00:12:31              │
      │ reductions ▂▃▅▇█▆▅▃▂▁                                            │
      │ memory     ▅▅▅▆▆▆▆▇▇▇                                            │
      │ proc mem   ██████████████░░░░░░░░░░░░░░░░░░░░░░░░░░░             │
      └──────────────────────────────────────────────────────────────────┘

  The host creates the cell session with the font's 6×8 cell size, so `ExRatatui.Widgets.Viewport3D` and `ExRatatui.Widgets.Image` hand over RGB bitmaps at the panel's own resolution instead of half-block cells, and `RasterExRatatui.PixelFormat.Mono` orders-dither them onto the panel.

  ## Photos

  The photos are 186×144 grayscale PNGs in `priv/showcase/`, the pane's exact pixel size, read at compile time. They come from [Lorem Picsum](https://picsum.photos), which serves [Unsplash](https://unsplash.com/license) photos (free to use; the pane title credits the photographer anyway). A 1-bit ordered dither turns midtones into dot patterns, so a plain photo comes out flat and muddy: each one was contrast-stretched first (2% auto-contrast, then contrast ×1.5). To add one, prepare it the same way, drop it in `priv/showcase/`, and add it to `@photos`.

  Every tick (2 s, comfortably above a partial refresh) turns the object and samples the VM.

  ## Controls

  | Key    | Badge button     | Action                         |
  | ------ | ---------------- | ------------------------------ |
  | `up`   | A (single press) | Next 3D object                 |
  | `home` | A (long press)   | Next photo                     |
  | `down` | B (single press) | Pause or resume ticking        |
  | —      | B (long press)   | Back to the menu               |
  """

  use ExRatatui.App, runtime: :reducer

  alias ExRatatui.Event.Key
  alias ExRatatui.Image
  alias ExRatatui.Layout
  alias ExRatatui.Layout.Rect
  alias ExRatatui.Style
  alias ExRatatui.Subscription
  alias ExRatatui.Text.Line
  alias ExRatatui.Text.Span
  alias ExRatatui.ThreeD.Camera
  alias ExRatatui.ThreeD.Light
  alias ExRatatui.ThreeD.Material
  alias ExRatatui.ThreeD.Mesh
  alias ExRatatui.ThreeD.Object
  alias ExRatatui.ThreeD.Scene
  alias ExRatatui.ThreeD.Transform
  alias ExRatatui.Widgets.Block
  alias ExRatatui.Widgets.Gauge
  alias ExRatatui.Widgets.Paragraph
  alias ExRatatui.Widgets.Sparkline
  alias ExRatatui.Widgets.Viewport3D
  alias NameBadge.Screen.ExRatatui.Hint

  @tick_interval_ms 2_000
  @step :math.pi() / 8
  @history 64
  @shapes [:cube, :orbit, :cylinder]
  @white {255, 255, 255}
  # A light gray with some ambient response keeps the lit side dotted against the
  # paper background and the shadowed side gray instead of solid ink.
  @material %Material{color: {210, 210, 210}, ambient: 0.35, specular: 0.2}

  # One pane's inner area is 31×18 cells, 186×144 pixels: the photos' size.
  # Credits stay ASCII: the badge font has no accented letters.
  @photos_dir Path.expand("../../../../priv/showcase", __DIR__)
  @photos [
    {"bear.png", "Thomas Lefebvre"},
    {"puppy.png", "Andre Spieker"},
    {"camera.png", "Jennifer Trovato"}
  ]

  for {file, _author} <- @photos, do: @external_resource(Path.join(@photos_dir, file))

  @photo_bytes Enum.map(@photos, fn {file, author} ->
                 {File.read!(Path.join(@photos_dir, file)), author}
               end)

  @impl ExRatatui.App
  def init(_opts) do
    photos =
      Enum.map(@photo_bytes, fn {bytes, author} ->
        {:ok, image} = Image.new(bytes, resize: :fit, background: @white)
        {image, author}
      end)

    {:ok,
     %{
       shape: :cube,
       angle: 0.0,
       paused?: false,
       photos: photos,
       photo: 0,
       stats: sample(),
       reductions: [],
       memory: []
     }}
  end

  @impl ExRatatui.App
  def update({:event, %Key{code: "up"}}, state),
    do: {:noreply, %{state | shape: next_shape(state.shape)}}

  def update({:event, %Key{code: "home"}}, state),
    do: {:noreply, %{state | photo: rem(state.photo + 1, length(state.photos))}}

  def update({:event, %Key{code: "down"}}, state),
    do: {:noreply, %{state | paused?: not state.paused?}}

  def update({:info, :tick}, %{paused?: true} = state), do: {:noreply, state, render?: false}
  def update({:info, :tick}, state), do: {:noreply, tick(state, sample())}
  def update(_message, state), do: {:noreply, state, render?: false}

  @impl ExRatatui.App
  def subscriptions(_state), do: [Subscription.interval(:showcase_tick, @tick_interval_ms, :tick)]

  @doc """
  Advances `state` by one tick with a fresh VM `sample`: turns the object and appends the reduction and memory deltas to their histories.
  """
  @spec tick(map(), map()) :: map()
  def tick(state, sample) do
    %{
      state
      | angle: state.angle + @step,
        stats: sample,
        reductions: push(state.reductions, max(sample.reductions - state.stats.reductions, 0)),
        memory: push(state.memory, div(sample.memory, 1024))
    }
  end

  @doc """
  The 3D object after `shape` in the cycle.

  ## Examples

      iex> Enum.map([:cube, :orbit, :cylinder], &NameBadge.Screen.ExRatatui.Showcase.next_shape/1)
      [:orbit, :cylinder, :cube]
  """
  @spec next_shape(atom()) :: atom()
  def next_shape(shape) do
    index = Enum.find_index(@shapes, &(&1 == shape))
    Enum.at(@shapes, rem(index + 1, length(@shapes)))
  end

  @impl ExRatatui.App
  def render(state, %{width: width, height: height}) do
    area = %Rect{x: 0, y: 0, width: width, height: height}

    [title, panes, beam, hints] =
      Layout.split(area, :vertical, [{:length, 1}, {:length, 20}, {:fill, 1}, {:length, 1}])

    [left, right] = Layout.split(panes, :horizontal, [{:fill, 1}, {:fill, 1}])
    {image, author} = Enum.at(state.photos, state.photo)

    viewport = %Viewport3D{
      scene: scene(state.shape, state.angle),
      camera: camera(state.shape),
      render_mode: :auto
    }

    hint =
      Hint.paragraph([
        {"A", "shape"},
        {"A long", "photo"},
        {"B", if(state.paused?, do: "resume", else: "pause")},
        {"B long", "back"}
      ])

    [
      {title_line(), title},
      {%Block{title: " 3D #{state.shape} ", borders: [:all]}, left},
      {viewport, inner(left)},
      {%Block{title: " #{author} / Unsplash ", borders: [:all]}, right},
      {image, inner(right)}
    ] ++ beam_widgets(state, beam) ++ [{hint, hints}]
  end

  defp title_line do
    %Paragraph{
      text: %Line{
        spans: [
          %Span{content: " ex_ratatui ", style: %Style{modifiers: [:reversed]}},
          %Span{content: " 3D and images on a 1-bit badge"}
        ]
      }
    }
  end

  defp beam_widgets(state, area) do
    content = inner(area)

    [stats, _gap, reductions, _gap2, memory, _gap3, gauge] =
      Layout.split(content, :vertical, [
        {:length, 1},
        {:length, 1},
        {:length, 4},
        {:length, 1},
        {:length, 4},
        {:length, 1},
        {:length, 1}
      ])

    %{stats: sample} = state
    ratio = if sample.memory > 0, do: min(sample.process_memory / sample.memory, 1.0), else: 0.0

    [
      {%Block{title: " BEAM ", borders: [:all]}, area},
      {%Paragraph{text: stats_text(sample)}, stats}
    ] ++
      labelled("reductions", %Sparkline{data: state.reductions}, reductions) ++
      labelled("memory", %Sparkline{data: above_minimum(state.memory)}, memory) ++
      labelled("proc mem", %Gauge{ratio: ratio, label: "#{round(ratio * 100)}%"}, gauge)
  end

  defp labelled(label, widget, area) do
    [label_rect, widget_rect] = Layout.split(area, :horizontal, [{:length, 11}, {:fill, 1}])
    [{%Paragraph{text: label}, label_rect}, {widget, widget_rect}]
  end

  defp stats_text(sample) do
    memory_mb = :erlang.float_to_binary(sample.memory / 1_048_576, decimals: 1)
    uptime = sample.uptime_ms |> div(1000) |> format_uptime()

    "procs #{sample.processes}   mem #{memory_mb} MB   run queue #{sample.run_queue}   up #{uptime}"
  end

  defp format_uptime(seconds) do
    [div(seconds, 3600), rem(div(seconds, 60), 60), rem(seconds, 60)]
    |> Enum.map_join(":", &String.pad_leading(Integer.to_string(&1), 2, "0"))
  end

  @doc """
  The scene for `shape` turned by `angle` radians.
  """
  @spec scene(atom(), float()) :: Scene.t()
  def scene(shape, angle) do
    %Scene{
      objects: objects(shape, angle),
      lights: [Light.ambient(@white, 0.6), Light.directional({0.5, 1.0, 0.3}, @white)],
      background: @white
    }
  end

  defp objects(:cube, angle) do
    [
      %Object{
        mesh: Mesh.cube(),
        material: @material,
        transform: rotation(angle * 0.6, angle, 0.0)
      }
    ]
  end

  defp objects(:cylinder, angle) do
    [
      %Object{
        mesh: Mesh.cylinder(),
        material: @material,
        transform: %Transform{rotation(angle, 0.0, angle * 0.5) | scale: {1.2, 1.6, 1.2}}
      }
    ]
  end

  defp objects(:orbit, angle) do
    radius = 1.3

    [
      %Object{
        mesh: Mesh.sphere(),
        material: @material,
        transform: %Transform{scale: {1.3, 1.3, 1.3}}
      },
      %Object{
        mesh: Mesh.cube(),
        material: @material,
        transform: %Transform{
          rotation(angle, angle, 0.0)
          | position: {radius * :math.cos(angle), 0.35, radius * :math.sin(angle)},
            scale: {0.45, 0.45, 0.45}
        }
      }
    ]
  end

  defp rotation(x, y, z), do: %Transform{rotation: {:euler_xyz, {x, y, z}}}

  defp camera(:orbit), do: %Camera{position: {2.2, 1.8, 3.2}, target: {0.0, 0.0, 0.0}}
  defp camera(_shape), do: %Camera{position: {1.7, 1.4, 2.3}, target: {0.0, 0.0, 0.0}}

  defp inner(%Rect{x: x, y: y, width: width, height: height}) do
    %Rect{x: x + 1, y: y + 1, width: max(width - 2, 0), height: max(height - 2, 0)}
  end

  defp push(history, value), do: Enum.take(history ++ [value], -@history)

  # Memory moves by a few percent at most; plotting it above its own minimum
  # makes the trend visible instead of a solid block.
  defp above_minimum([]), do: []

  defp above_minimum(history) do
    minimum = Enum.min(history)
    Enum.map(history, &(&1 - minimum))
  end

  defp sample do
    {reductions, _since_last_call} = :erlang.statistics(:reductions)
    {uptime_ms, _since_last_call} = :erlang.statistics(:wall_clock)

    %{
      processes: :erlang.system_info(:process_count),
      memory: :erlang.memory(:total),
      process_memory: :erlang.memory(:processes),
      reductions: reductions,
      run_queue: :erlang.statistics(:total_run_queue_lengths),
      uptime_ms: uptime_ms
    }
  end
end
