# FrameTube

Watch YouTube and YouTube VR videos (360°, 180°, 3D) in your Steam Frame, or on a big virtual screen.

## Quick start (no technical knowledge needed)

1. Download the zip for your device from the releases page:
   - **FrameTube-Windows**: run it on your PC and stream to the Steam Frame. Smoothest, even 8K VR videos.
   - **FrameTube-SteamFrame**: runs right on the headset, no PC needed.
2. Unzip it and open FrameTube. The step-by-step guide is in the zip ("How to install.txt"); the same text is in
   [`docs/install-windows.txt`](docs/install-windows.txt) and [`docs/install-steamframe.txt`](docs/install-steamframe.txt).
3. The first time, FrameTube downloads what it needs by itself (about 300 MB, once). Then tap a **Discover**
   topic or search, and pick a video.

Everything else is automatic: it works out what kind of VR video it is, keeps its YouTube helper up to date,
remembers where you stopped, and tucks the menu away while you watch (B / Y or Menu brings it back).

---

## About the project

Built in Godot 4.7 with OpenXR. It plays streams through yt-dlp, the same approach as yt-dlp itself, NewPipe,
FreeTube and SmartTube, which are all open source on GitHub. That goes against YouTube's terms of service (an
agreement between each viewer and YouTube), so the Steam store is out, but publishing the source code is fine.
Releases don't contain any third-party binaries: the app downloads yt-dlp, ffmpeg and Deno from their official
GitHub releases on first run.

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

## Helper programs (automatic)

FrameTube needs yt-dlp (finds the video streams), ffmpeg (decodes them) and Deno (which yt-dlp uses for
YouTube's player code). **The app installs them itself** (`scripts/setup.gd`). On first run (or **Settings >
Repair**) it downloads the right builds for the platform from their official GitHub releases, checks them against
the published SHA-256 checksums, extracts just the executable, and puts it in the app's data folder (`user://bin`:
`%APPDATA%\Godotpp_userdata\FrameTubein` on Windows, `~/.local/share/godot/app_userdata/FrameTube/bin` on
Linux). yt-dlp updates itself every 3 days in the background, and once more automatically if a video fails in a
way that suggests YouTube changed something.

| Tool   | Windows (x86_64) | Steam Frame (Linux ARM64) | Linux x86_64 |
|--------|------------------|---------------------------|--------------|
| yt-dlp | `yt-dlp.exe` | `yt-dlp_linux_aarch64` | `yt-dlp_linux` |
| ffmpeg | BtbN `win64-gpl` .zip | BtbN `linuxarm64-gpl` .tar.xz | BtbN `linux64-gpl` .tar.xz |
| deno   | `x86_64-pc-windows-msvc` .zip | `aarch64-unknown-linux-gnu` .zip | `x86_64-unknown-linux-gnu` .zip |

For development you can still drop copies into `bin/` (editor) or a `bin/` folder next to the executable; those
win over the managed ones. Both folders are gitignored.

## Building releases

```
python tools/build_release.py C:\path	o\godotconsole.exe
```
This exports the Windows, Steam Frame (Linux arm64) and Linux x86_64 presets (Godot 4.7 export templates needed)
and writes `build/release/FrameTube-<platform>-v<version>.zip`, each with its plain-language install guide. The
Linux executables are marked runnable inside the zip, so nobody needs a terminal. The version comes from
`config/version` in `project.godot`.

## Running from the editor

- **Desktop test mode** (no headset / OpenXR runtime): press F5 in Godot. Right-drag to look around, click
  the panel. Keys: `Space` pause, `←/→` seek 10s, `Tab`/`H` show/hide panel, `P` cycle projection, `R` recenter.
- **PC VR / streaming to the Frame**: start SteamVR with the Frame connected, then F5. It starts in VR.

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

Two pages, **Browse** and **Settings**, with the player controls always visible underneath. A **Welcome**
page takes over on first run while the helpers download (progress bar, "Try again" on failure).

- **Startup list**: "Continue watching" if you've watched something before, otherwise a Discover topic, so
  there's always something to tap. In VR the keyboard appears only when you tap the search box.
- **Search / URL**, the **Discover** topics (VR180 3D, 360 nature, Roller coasters, Space, Underwater,
  Concerts, Relax), plus **Continue watching** (resume points), **Subscriptions**, **Watch later** and
  **For you**. The last three need an account.
- **The menu tucks itself away** 3 s after a video starts (unless you're using it). The first time, a hint says
  how to bring it back.
- **Errors in plain words**: age-restricted, private, members-only, unavailable, no internet, sign-in needed.
  Anything that looks like YouTube changed something triggers an automatic yt-dlp update and one retry.
- **Settings page**: Room, Fidget toy, Colour theme, Ambient glow, Glow effects, YouTube account; under
  *Advanced*: Video decoding and Repair (re-downloads the helpers), plus version info.
- **YouTube account**: cycles Not signed in → Firefox → Chrome → Edge → Brave → Chromium. yt-dlp reads your YouTube login
  cookies from that browser, so sign in to YouTube there first. Firefox is the reliable choice: Chrome and
  Edge on Windows encrypt their cookies in a way yt-dlp often can't read. Alternatively, export a `cookies.txt`
  (Netscape format) with a browser extension and put it next to the app or in `user://`. It overrides the
  browser setting, and the button then shows "cookies.txt". Signing in also unlocks age-restricted and
  members-only videos.
- Player row: **Video type** (auto-detected; cycle it if a video looks wrong), **Screen** size + **Reset**,
  **Quality** (HD / 2K / 4K / 5K / 8K maximum), **Swap eyes**.

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
