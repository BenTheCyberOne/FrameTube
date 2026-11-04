# FrameTube

A YouTube / YouTube VR player for Steam Frame, built in Godot 4.7 with OpenXR.

It plays streams through yt-dlp, the same approach as yt-dlp itself, NewPipe, FreeTube and SmartTube, which are
all open source on GitHub. That goes against YouTube's terms of service (an agreement between each viewer and
YouTube), so the Steam store is out, but publishing the source code is fine. If you publish it, keep the
downloaded tools (`bin/`, `bin-linux-arm64/`) out of the repo. If you ship ffmpeg yourself in a release,
include its GPL licence and a link to its source code.

## How it works

```
search/URL ─► yt-dlp -J ─► direct video + audio URLs ─► ffmpeg -i (reads projection/stereo metadata)
                             │
   ffmpeg (video, GPU hwaccel) ─► raw NV12 on stdout ─► thread ─► R8 + RG8 textures ─► video.gdshader
   ffmpeg (audio)              ─► f32le PCM on stdout ─► thread ─► AudioStreamGenerator (master clock)
```

The shader converts YUV to RGB and maps the frame onto a flat screen or an inside-out sphere. It supports
equirectangular and YouTube's cubemap layout, and uses `VIEW_INDEX` to give each eye its half of a stereo
frame. Everything is plain GDScript with no GDExtensions, so the same project runs on Windows and on the
Frame's ARM64 Linux.

## Helper binaries

Put these in `bin/`. In the editor that's `FrameTube/bin/`; in an export it's a `bin/` folder next to the
executable. They can also go in `user://bin` or anywhere on PATH. `bin/` holds the Windows builds and
`bin-linux-arm64/` holds the Frame builds.

| Tool   | Windows (desktop testing) | Steam Frame (Linux ARM64) |
|--------|---------------------------|---------------------------|
| yt-dlp | `yt-dlp.exe`              | `yt-dlp_linux_aarch64` → rename to `yt-dlp` |
| ffmpeg | `ffmpeg.exe` (BtbN build) | BtbN `linuxarm64-gpl` build → `ffmpeg` |
| deno   | `deno.exe`                | `deno-aarch64-unknown-linux-gnu` → `deno` |

Recent yt-dlp versions need a JavaScript runtime (Deno) to get YouTube's full format list. If `bin/deno`
exists, FrameTube passes it to yt-dlp automatically. On Linux, run `chmod +x bin/*`. YouTube changes often,
so run `yt-dlp -U` whenever things stop resolving.

## Running

- **Desktop test mode** (no headset / OpenXR runtime): press F5 in Godot. Right-drag to look around, click
  the panel. Keys: `Space` pause, `←/→` seek 10s, `Tab`/`H` show/hide panel, `P` cycle projection, `R` recenter.
- **Stream from the PC (recommended for 5.7K/8K)**: start SteamVR with the Frame connected for wireless PC VR
  streaming, then run FrameTube on Windows (F5 in Godot, or a Windows export with `bin/` next to it). It starts
  in VR automatically, and the PC does the decoding.
- **Native on the Steam Frame**: export with the "Steam Frame (Linux arm64)" preset (install Godot's export
  templates first). Copy `build/linux-arm64/` to the Frame, then copy the contents of `bin-linux-arm64/` into a
  `bin/` folder next to the executable and run `chmod +x bin/*`. Add it as a non-Steam game. The x86_64 preset
  also works, through the Frame's x86 emulation, but runs slower.

### VR controls
| Input | Action |
|---|---|
| Trigger (pointing at panel) | click |
| Thumbstick up/down on panel | scroll results |
| Thumbstick flick left/right (pointing at nothing) | seek ∓10s |
| A / X (off panel) | play / pause |
| B / Y or Menu | show / hide panel |
| Thumbstick click | recenter |
| **Grip** while pointing at the screen | grab it: it follows your laser and always turns to face you |
| **Grip with both hands** on the screen | pull apart / push together to resize |
| Thumbstick while pointing at (or holding) the screen | up/down resize, left/right pull closer / push away |
| Grip on the toy | grab / throw the toy (the toy takes priority when your hand is on it) |

### Moving and resizing the screen (flat videos)

The size is continuous from 0.5 to 16 m tall, at 0.8 to 25 m away. The **Screen** button jumps to the next
preset (S 1.6 m, M 2.4 m, L 3.4 m, XL 4.8 m), and **Reset** puts it back at M, 4 m straight ahead. The screen
always faces you, so you can drag it overhead and watch lying down. Size and placement are saved.
**Recenter** keeps a hand-placed screen in the same spot relative to you; it only re-anchors the room to where
you're facing. In desktop mode: left-drag the screen to move it, scroll over it to resize, Shift+scroll to
change its distance. Bias lighting and the cinema's screen light follow the screen when you move it.

## Panel

Two pages, **Browse** and **Settings**, with the player controls always visible underneath.

- **Search / URL**, plus **History** (resume points), **Subscriptions**, **Watch later** and **Recommended**.
  The last three need an account.
- **Settings page**: Environment, Fidget toy, Accent colour, Bias lighting, Bloom, Account, Video decoder.
- **Account**: cycles none → Firefox → Chrome → Edge → Brave → Chromium. yt-dlp reads your YouTube login
  cookies from that browser, so sign in to YouTube there first. Firefox is the reliable choice: Chrome and
  Edge on Windows encrypt their cookies in a way yt-dlp often can't read. Alternatively, export a `cookies.txt`
  (Netscape format) with a browser extension and put it next to the app or in `user://`. It overrides the
  browser setting, and the button then shows "cookies.txt". Signing in also unlocks age-restricted and
  members-only videos.
- **View** (projection), **Screen** size (S/M/L/XL, flat videos only), **Max** quality, **decoder**, **Swap eyes**.

## Environments, lighting and the toy

Shown around flat videos; 360°/180° videos replace them with the video itself. All procedural (shaders and
built-in meshes in `shaders/sky.gdshader`, `shaders/floor.gdshader` and `scripts/environments.gd`), so
there are no asset files.

| Environment | Look |
|---|---|
| Midnight | Deep-blue night, faint stars, accent horizon glow, subtle grid |
| Starfield | Drifting nebula and a milky-way band, dense twinkling stars |
| Synthwave | Striped sunset sun above the screen, magenta sky, scrolling neon grid |
| Aurora | Animated northern-lights curtains over a dark teal night |
| Cinema | A dark theatre: seats, red curtains, warm wall sconces, accent LED strips |
| Daydream | Pastel sky with soft drifting clouds (the one bright option) |

- **Accent colour** (Sky, Violet, Rose, Mint, Amber, Lime) tints the panel, lasers, grid lines, nebula, aurora, LED
  strips and the toy.
- **Bias lighting**: the video's average colour (sampled every 4th frame from a coarse 8×6 grid) softly
  lights the floor in front of the screen and the sky behind it. In Cinema it also drives the light that
  spills from the screen onto the room. It's smoothed so scene cuts don't strobe.
- **Bloom**: glow on bright things (sun, grid, LEDs, toy). Turn it off if the Frame struggles. The sky
  shaders (Aurora and Starfield especially) are the other GPU cost to watch on the headset.
- **Fidget toy** (Orb, Cube, Spinner, Donut, Off): it floats low to your right. **Grip** grabs it; let go
  mid-swing to throw it, and it carries your hand's velocity and spin. **Swipe** a hand through it to spin and
  push it. The spinner keeps spinning on its axle for a long time. It springs back to its spot and bounces off
  the floor, with haptics and sparks on every touch. In desktop mode, click it.

Remembered between sessions: environment, toy, accent, bias lighting, bloom, quality, screen size, decoder,
swap eyes, account, the last 60 videos with their
resume positions (it resumes automatically after the first 15 seconds of a video, and not in the last 15
seconds), and any projection you picked by hand for a specific video. They're stored in Godot's user data
folder (`%APPDATA%\Godot\app_userdata\FrameTube` on Windows) as `settings.cfg` and `history.json`.

## Projections

Detected automatically, from the stream's metadata first and the title as a fallback:

| Stream says | Mode |
|---|---|
| Stereo side-by-side | 180 3D (SBS), i.e. VR180 |
| Stereo top/bottom | 360 3D (top/bottom) |
| Mesh projection (`ytmp`, WebM projection type 3) | 360 (cubemap) |
| Equirectangular | 360 (or 180 if tiled / "VR180" in the title) |
| Nothing | title keywords: "VR180", "360", "3D VR" |

**YouTube cubemap (EAC)**: many 360° videos, including most 4K VP9 streams, are served as a 3×2 grid of
cube faces (`[left][front][right] / [down][back][up]`, bottom row rotated) rather than as an equirectangular
image. The face orientations in `video.gdshader` were fitted face by face against ffmpeg's `v360=eac` filter,
and renders in six directions matched ffmpeg's.

If the guess is wrong, cycle it with **View**. The choice is remembered for that video. **Swap eyes** fixes
stereo that looks inside-out.

## Test mode

```
godotconsole.exe --path . --xr-mode off -- --play=<url> [--seek-at=12 --seek-to=120] [--replay-at=N]
    [--quit-at=24] [--shots=<dir>] [--panel] [--decoders=vulkan,none] [--search=<q> | --feed=<key>]
    [--file=<path> --size=WxH --projection=N --look="yaw,pitch;..."]
```
It logs engine stats every second: position, frames shown, queue depths, and A/V drift (`av_ms`, positive means
audio is ahead). It also saves screenshots and doesn't touch your real settings or history unless you pass
`--persist`.

## Known limitations / next steps

- **GPU decoding** is on by default. ffmpeg tries `-hwaccel vulkan`, then `d3d11va` (Windows only), then the CPU,
  and steps down automatically if one fails. Frames come out as NV12, the GPU's native format, so ffmpeg doesn't
  need to convert them on the CPU. On an RTX 5070 this used about 5× less CPU for 4K VP9 and 9× less for 8K AV1.
  On the Frame it likely falls back to the CPU unless the driver supports Vulkan video decoding.
- **Above 4K, the bottleneck is copying frames into Godot.** Godot's pipe reads top out around 47 fps at 4K
  (~580 MB/s), which works out to about 12 fps at 8K. Real 8K needs a GDExtension that hands decoded frames
  straight to the GPU texture (libmpv or FFmpeg).
- **Not yet supported:** 3D (stereo) cubemap 360°, and VR180 that uses YouTube's mesh projection without
  side-by-side stereo metadata. Neither turned up in testing. Some videos only offer the 8K AV1 version above
  1764p; YouTube's sub-4K VR180 versions (2204×1240, 3136×1764) look like a different layout and haven't been
  verified.
- **Start-up**: googlevideo refuses fresh audio URLs for 0–3 s. Video now starts without waiting, and audio
  joins mid-playback, trimmed so it stays in sync (measured within ±12 ms). Seeking restarts ffmpeg (~1–2 s).
- The Frame's controllers go through SteamVR's bindings for Godot's default action map. If a button doesn't
  respond, remap it in the SteamVR controller bindings for the app.
