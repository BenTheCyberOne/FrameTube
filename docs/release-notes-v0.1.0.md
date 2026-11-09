# FrameTube v0.1.0: first release

Watch YouTube and YouTube VR videos (360°, 180°, 3D) in your Steam Frame, either streamed from a PC or
running on the headset by itself. Free and open source (MIT).

**This is an early release.** It's been used and tested on Windows with a Steam Frame over SteamVR streaming.
The standalone Steam Frame build (Linux ARM64) hasn't been tried on the headset yet. Please report what works
and what doesn't.

## Downloads

| File | For |
|---|---|
| `FrameTube-Windows-v0.1.0.zip` | Windows PC, streamed to the Steam Frame (or any SteamVR headset). Smoothest, up to 8K. |
| `FrameTube-SteamFrame-v0.1.0.zip` | Runs on the Steam Frame itself (SteamOS, ARM64), no PC needed. Best up to 4K. |
| `FrameTube-Linux-v0.1.0.zip` | Linux PCs (x86_64). |

Unzip and follow "How to install.txt" inside. On first run FrameTube downloads its video helpers (yt-dlp,
FFmpeg, Deno, about 300 MB, once) from their official releases. Windows will warn that the app isn't
recognised (it isn't code-signed): choose **More info > Run anyway**.

## What's in it

**Watching**
- Search, paste a link, or tap a **Discover** topic. Lists keep loading as you scroll.
- 360°, 180° (VR180), 3D side-by-side and top/bottom, and YouTube's cubemap 360, detected automatically.
- **Auto quality**: up to 8K for VR videos on a PC, 4K on the Frame by itself. It steps down if playback can't keep up.
- GPU video decoding with automatic fallback, steady 30 fps at 8K on a PC.
- Subtitles (including offline), playback speed 0.5×–2×, resume where you stopped, play next.

**Your space**
- A big flat screen you can grab, move, resize and curve; six environments (Midnight, Starfield, Synthwave,
  Aurora, Cinema, Daydream); ambient glow from the video; colour themes.
- A menu you can grab, move and resize with both hands.
- See your hands, your controllers, both or neither.
- A fidget toy to grab, throw and spin, which floats back, stays put, or falls to the floor.

**Downloads**
- Save videos (with subtitles) to watch without internet.
- **Send videos between the PC and the Frame** over Wi-Fi: let the PC download for the Frame, or send
  anything in Downloads across. Asks once per device before accepting anything.

**Account & family**
- Optional YouTube sign-in through a throwaway browser profile (Firefox, Chrome, Edge, Brave) for
  subscriptions, Watch later and age-restricted videos.
- Family-friendly filter (on by default) and a parental PIN lock.

## Known limitations
- Not tested on the Steam Frame by itself yet; controller buttons there go through SteamVR's default bindings.
- 8K at 60 fps tops out around 30 fps (Auto picks 5.7K or 4K for those).
- 3D cubemap 360 videos aren't supported yet.
- Sending videos needs FrameTube open on both devices, on the same network.

## Notices
FrameTube is an independent project, not affiliated with or endorsed by YouTube, Google or Valve. Videos
belong to their creators: download only for your own offline viewing. Third-party licenses are in
`Third-party notices.txt` in each zip and in `THIRD_PARTY_NOTICES.md` in the repository.
