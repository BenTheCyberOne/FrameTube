<p align="center"><img src="docs/logo.png" width="128" alt="FrameTube logo"></p>

# FrameTube

Watch YouTube and YouTube VR videos (360°, 180°, 3D) in your Steam Frame, or on a big virtual screen.
Free and open source ([MIT](LICENSE)).

> FrameTube is an independent project. It isn't affiliated with, endorsed by or sponsored by YouTube, Google
> or Valve. See [Third-party notices](THIRD_PARTY_NOTICES.md) and [License & credits](#license--credits).

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
`%APPDATA%\Godot\app_userdata\FrameTube\bin` on Windows, `~/.local/share/godot/app_userdata/FrameTube/bin` on
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
python tools/build_release.py C:\path\to\godotconsole.exe
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
| **Grip** while pointing at the menu | move the menu (it turns to face you) |
| **Grip with both hands** on the menu | pull apart / push together to resize it (45 % to 200 %) |
| Thumbstick while holding the menu | up/down resize, left/right pull closer / push away |
| Grip on the toy | grab / throw the toy (the toy takes priority when your hand is on it) |

The menu remembers its size and where you put it relative to your view, so it opens in that spot wherever
you're facing. **Settings > Menu size** steps through Small / Normal / Large / Extra large and puts a moved menu
back in front of you. Desktop: Ctrl+scroll over the menu resizes it, Ctrl+left-drag moves it.

**Hands and controllers** (Settings > Show in VR: *Hands + controllers* (default), *Hands only*,
*Controllers only* or *Nothing*): controllers are drawn using the headset's own controller model when the
runtime provides one (OpenXR render models) and a plain stand-in otherwise. Hands are drawn from the tracked
joints: optical hand tracking when the controllers are put down, or the hand pose the runtime works out from a
held controller. An optically tracked hand hides its controller, so it isn't drawn over your fingers.

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
- **Search / URL**, the **Discover** topics, plus **Continue watching** (resume points), **Subscriptions**,
  **Watch later** and **For you**. The last three need an account.
- **Discover topics** are pills with a badge for the kind of video they find (VR180, 360°, 2D): Travel,
  Concerts, Nature, Roller coasters, Space, Underwater and Relax to start with. After a search, **+ Save "…"**
  adds it as a topic (its badge is guessed from the words); **Edit** turns the pills into × buttons that
  remove them. Settings > *Discover topics* hides the row, and *Original topics* brings back the defaults.
- **Infinite scrolling**: searches and feeds load 20 videos at first, then 20 more whenever you scroll near
  the bottom (yt-dlp `-I start:end`), skipping any repeats, until YouTube runs out. The status line counts
  them and says how many the family filter hid.
- **The menu tucks itself away** 3 s after a video starts (unless you're using it). The first time, a hint says
  how to bring it back.
- **Errors in plain words**: age-restricted, private, members-only, unavailable, no internet, sign-in needed.
  Anything that looks like YouTube changed something triggers an automatic yt-dlp update and one retry.
- **Results** are two-column cards: thumbnail (cached in `user://thumbs`) with duration / LIVE chip,
  VR180 / 360° / 3D / 4K / 5.7K / 8K+ badges (from the title) and a resume bar, then title, channel ✓, views and a
  description snippet. (Search results don't include upload dates, so there are none.)
- **Settings page** (scrolls), in sections:
  - *Watching*: Resume videos, When a video ends (Stop / Replay / Play next in the list), Hide the menu while
    watching, Discover topics, Original topics, Menu size (Small / Normal / Large / Extra large, or any size by
    gripping the menu), Screen shape, Subtitle size, Saved videos, Save downloads to, Receive videos from other
    devices, Subtitles to save.
  - *Safety & account*: **Family-friendly filter** (on by default), YouTube account, Clear watch history (press
    twice).
  - *Room & look*: Room, Fidget toy, When you let go of the toy, Vibration, Show in VR (hands /
    controllers), Colour theme, Ambient glow, Glow effects.
  - *Advanced*: Video decoding, Repair (re-downloads the helpers), version info.
- **Volume** slider in the player controls (desktop: ↑/↓), remembered between sessions.
- **Subtitles** (player row): cycles Off and the video's tracks: every human-made one, plus auto-generated
  captions in the video's language and English (YouTube's ~100 machine translations are skipped). Fetched as
  YouTube's `json3` timed text (`scripts/subtitles.gd`) and timed off the video clock. Shown on the lower part of
  a flat screen (pushed forward on curved screens) or head-locked low in your view for 360°/180° (above the
  menu while it's open). The chosen language switches on automatically for the next video. Size: Settings >
  Subtitle size.
- **Speed** (player row): 0.5× to 2×. ffmpeg retimes the video (`setpts`, output stays at the source fps so
  2× costs no extra decoding) and the audio (`atempo`, which keeps the pitch); the engine's clock runs at the
  chosen speed. Measured at 2×: media time +2.0 s per second, A/V within ±17 ms.
- **Screen shape** (Settings > Watching): Flat, Curved (radius 1.8× the viewing distance) or Extra curved
  (radius = distance, so every point is equally far away). It's a generated arc mesh that follows the distance
  as you move the screen; the laser uses a ray-cylinder test.
- **Parental lock** (Settings > Safety & account): a 4-digit PIN, typed twice on a keypad, stored as a salted
  SHA-256 hash. Once set, it's needed to turn the family filter **off**, change the YouTube account, clear
  history, or change/remove the lock. Turning the filter on never asks. 5 wrong tries pause input for 60 s.
  Forgotten PIN: delete `settings.cfg` in the app's data folder (the install guides explain where). This is a
  deterrent for kids, not a security boundary against someone who can use the file manager.
- **Family-friendly filter**: hides results whose title, description or channel contain adult, gore or horror
  words (whole-word list in `youtube.gd`, `FAMILY_BLOCK`), asks YouTube to leave the worst terms out of every
  search (`-sexy -lingerie …`), and refuses videos YouTube marks 18+ even if a link is pasted. The status line
  says how many results it hid. It's a keyword filter, not a guarantee: YouTube's own Restricted Mode is tied to
  an account and isn't available to the app.
- **YouTube account > Sign in**: opens a browser window with a fresh, private FrameTube profile at Google's
  sign-in page. When the YouTube login appears, FrameTube copies it to `user://cookies.txt` (which yt-dlp
  uses), closes the window and deletes the profile. Press the button again to cancel; once signed in, press it
  twice to sign out. Signing in unlocks subscriptions, Watch later, age-restricted and members-only videos, and
  stops most "sign in to confirm you're not a bot" errors.
  - Why a throwaway profile: YouTube keeps replacing ("rotating") the login cookies of a browser that has
    YouTube open, which breaks copies of them. This profile is never opened again, so the copy lasts much
    longer than one read from your everyday browser. yt-dlp refreshes it as it's used.
  - Firefox (preferred) is read with yt-dlp. Chrome, Edge, Brave and Chromium take two steps, because Google
    refuses sign-in ("this browser may not be secure") in a browser started with remote debugging. First an
    ordinary window with nothing attached: sign in, then close it (on Linux it closes by itself once the login
    shows up in the profile's cookie file; Windows locks that file). Then FrameTube reopens the profile
    invisibly with its local DevTools connection, which hands over the cookies already decrypted, and
    closes it. If one browser fails, the next press uses the next one installed.
  - On SteamOS it finds native installs and Flatpaks (Firefox from Discover). The window opens best from
    Desktop Mode.
  - When YouTube ends the session, FrameTube notices, removes it and asks you to sign in again.
  - A hand-made `cookies.txt` (Netscape format) next to the app also works; the button then shows "Using cookies.txt".
- **Download** (player controls, or the button on any search result; only when you press it): saves the video at the current quality (with Auto: the stream that's playing) to
  `Videos/FrameTube` (Windows: your Videos folder; SteamOS: `~/Videos/FrameTube`), with live progress; press
  again to cancel. Saved videos appear under **Downloads** on Browse and play from the file, with no internet
  needed and instant seeking. They keep their video type, resume point and the family filter. Press **Saved**, then
  **Delete?** to remove one; Settings > Saved videos shows the count/size and opens the folder. Subtitle tracks are saved
  alongside (`<video>.<lang>.json3`) and work offline; Settings > Subtitles to save picks which languages
  (all, the video's own language, and/or specific ones; none at all is fine too). Cards in the Downloads list
  have a **Delete** button (press it, then **Sure?**). Live streams can't be saved. Downloading is for your own offline viewing: respect
  creators' rights and YouTube's terms.
- **Sending videos between devices** (`scripts/link.gd`): FrameTube on the PC and on the Frame find each
  other on the home network and can move saved videos across. See [below](#sending-videos-between-devices).
- Player row: **Video type** (auto-detected; cycle it if a video looks wrong), **Screen** size + **Reset**,
  **Quality** (Auto / HD / 2K / 4K / 5.7K / 8K maximum), **Swap eyes**.
  - **Auto** (the default) shows what it picked, e.g. "Auto (8K)". 360°/180° videos spread their pixels all
    around you, so they need far more than a flat screen: 4K over 360° is only about 10 pixels per degree,
    half of what the headset shows, which is why 4K 360 looks soft. Auto takes VR videos up to 8K (5.7K when
    they're over 30 fps) and flat videos up to 4K. On the Frame by itself (ARM) it stays at 4K. If frames keep
    arriving too slowly (under 90% of the frame rate for about 5 s), it steps down one level from the same spot
    and stays there until you pick a quality or restart.

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
  push it. The spinner keeps spinning on its axle for a long time. Haptics and sparks on every touch. In desktop
  mode, click it. **When you let go of the toy**: *Floats back* (springs back to its spot), *Stays put* (coasts
  to a stop and floats wherever you leave it) or *Falls* (gravity: drops, bounces and rolls to a stop on the
  floor). Recenter calls it back to its spot in any mode.

Remembered between sessions: environment, toy, accent, bias lighting, bloom, quality, screen size, decoder,
swap eyes, account, Discover topics, the last 500 videos with their
resume positions (it resumes automatically after the first 15 seconds of a video, and not in the last 15
seconds), and any projection you picked by hand for a specific video. They're stored in Godot's user data
folder (`%APPDATA%\Godot\app_userdata\FrameTube` on Windows) as `settings.cfg` and `history.json`.

## Sending videos between devices

The Frame plays 4K smoothly by itself, but downloading is faster on the PC, and while you stream from the PC
the Frame's own FrameTube isn't running. So:

- **Settings > Save downloads to** cycles *This PC* and the other FrameTubes it has seen (Steam Frames first).
  With a device picked, a download runs here, then the file is **moved** there. With Auto quality, downloads
  for a Steam Frame are capped at 4K, which it plays smoothly on its own.
- In **Downloads**, a second button **Send to Frame / Send to PC** sends a **copy**. While a video is on its way
  that button shows *Waiting for Frame*, *Allow it there* or *Sending 42%*; pressing it stops sending.
- Transfers wait until both devices are open on the same network and then start by themselves. The PC can be
  left running in its desktop window while you start FrameTube on the Frame.

How it works:
- **Discovery**: every copy broadcasts a small JSON "I'm here" on UDP port 47811 every 2.5 s (to
  255.255.255.255 and each private network's .255 address) and listens for the others. Devices it has seen are
  remembered with their last address, which is tried every 20 s even without a broadcast. If a device comes
  back with a new identity (FrameTube reinstalled), the old entry is replaced.
- **Transfer**: TCP to the receiver's port (47812, or the next free one). The sender sends one JSON line (who it
  is, its secret for this receiver, the video's details, and the file list with sizes), then the bytes. The
  receiver sends one JSON line back before and after. It runs on a worker thread on the sending side, and
  8 MB per frame on the receiving side, so playback isn't disturbed.
- **Trust**: the first time a device sends, the receiver shows **"Allow videos from …?"** at the top of the menu
  (and opens the menu). With a parental lock, Allow needs the PIN. The sender picks a random 128-bit secret
  per receiver; once allowed, the receiver only accepts that device with that secret. *Not now* refuses it
  until FrameTube restarts. At most 3 unknown devices can be waiting for an answer.
- **What's accepted**: one video (mkv / mp4 / webm / mov / m4v) plus subtitle `.json3` files of up to 16 MB, only
  if there's room (plus 300 MB to spare), only for a valid YouTube id that isn't already saved. Files are
  written as `.part` and renamed when complete, under names the receiver makes up itself (sanitized title plus
  id) in its own Downloads folder. A transfer that stops part-way is deleted and sent again later. Received
  videos keep their age limit, so the family filter still applies.
- Settings > **Receive videos from other devices** turns receiving off; it also forgets the devices you'd
  allowed. Sending always works.

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

Other test hooks (after `--`): `--search=<q> --scroll-test=N` (scrolls to the bottom N times and checks for
repeats), `--topics-test`, `--rig-test` (menu, toy and hands), `--pin-test`, `--langs-test`, and the device link:
```
# receiver                                       # sender (another copy of the project, so user:// differs)
FRAMETUBE_VIDEOS=<dirB> godot --path projB ...   FRAMETUBE_VIDEOS=<dirA> godot --path projA ...
  -- --link-test --link-port=47900 --link-allow    -- --link-test --link-port=47910 --link-send=<file>
                                                    [--link-peer=127.0.0.1:47900 --link-no-discovery] [--link-move]
```
`FRAMETUBE_VIDEOS` points the Downloads folder somewhere else.

## Known limitations / next steps

- **GPU decoding** is on by default. ffmpeg tries `-hwaccel vulkan`, then `d3d11va` (Windows only), then the CPU,
  and steps down automatically if one fails. Frames come out as NV12, the GPU's native format, so ffmpeg doesn't
  need to convert them on the CPU. On an RTX 5070 this used about 5× less CPU for 4K VP9 and 9× less for 8K AV1.
  On the Frame it likely falls back to the CPU unless the driver supports Vulkan video decoding.
- **Above 4K, the bottleneck is copying frames into Godot.** The pipe itself does ~2.5 GB/s; the cost was
  assembling each frame from 64 KB reads. Growing a PackedByteArray with `append_array` managed ~17 fps at
  8K; copying the pieces into a buffer allocated once at full size (StreamPeerBuffer) holds a steady 30 fps
  at 8K (tested with HEVC and AV1 files and a real 8K AV1 360 stream, RTX 5070). 8K60 still tops out at
  ~30 fps and 5.7K60 at ~53, so Auto uses 5.7K or 4K for high-frame-rate VR. Beyond that needs a GDExtension
  that hands decoded frames straight to the GPU texture (libmpv or FFmpeg).
- **Not yet supported:** 3D (stereo) cubemap 360°, and VR180 that uses YouTube's mesh projection without
  side-by-side stereo metadata. Neither turned up in testing. Some videos only offer the 8K AV1 version above
  1764p; YouTube's sub-4K VR180 versions (2204×1240, 3136×1764) look like a different layout and haven't been
  verified.
- **Start-up**: googlevideo refuses fresh audio URLs for 0–3 s. Video now starts without waiting, and audio
  joins mid-playback, trimmed so it stays in sync (measured within ±12 ms). Seeking restarts ffmpeg (~1–2 s).
- The Frame's controllers go through SteamVR's bindings for Godot's default action map. If a button doesn't
  respond, remap it in the SteamVR controller bindings for the app.

## License & credits

FrameTube is released under the [MIT License](LICENSE): free to use, change and share, including in your own
projects, as long as the copyright notice comes along.

- Built with [Godot Engine](https://godotengine.org) (MIT).
- On first run it downloads [yt-dlp](https://github.com/yt-dlp/yt-dlp) (Unlicense),
  [FFmpeg](https://ffmpeg.org) ([BtbN builds](https://github.com/BtbN/FFmpeg-Builds), GPL) and
  [Deno](https://deno.com) (MIT). They aren't part of this repository or the releases; FrameTube runs them as
  separate programs. Details in [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md).

**Disclaimer.** FrameTube is an independent, unofficial project. It isn't affiliated with, endorsed by or
sponsored by YouTube, Google, Valve or Steam; those names are trademarks of their owners and appear only to
describe what the app works with. FrameTube doesn't host or distribute videos: they're streamed from YouTube
and belong to their creators. Using a third-party YouTube client may go against YouTube's terms of service,
which is between you and YouTube. Download only for your own offline viewing, and respect creators' rights.
The software is provided "as is", without warranty of any kind (see the license).
