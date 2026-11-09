# Third-party software and notices

FrameTube itself is MIT-licensed (see `LICENSE`). It's built with, or uses, the following.

## Included in the release downloads

### Godot Engine
FrameTube runs on the Godot Engine, which is compiled into `FrameTube.exe` / `FrameTube.x86_64` /
`FrameTube.arm64`.

> Copyright (c) 2014-present Godot Engine contributors (see AUTHORS.md).
> Copyright (c) 2007-2014 Juan Linietsky, Ariel Manzur.
>
> Permission is hereby granted, free of charge, to any person obtaining a copy of this software and
> associated documentation files (the "Software"), to deal in the Software without restriction, including
> without limitation the rights to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
> copies of the Software, and to permit persons to whom the Software is furnished to do so, subject to the
> following conditions:
>
> The above copyright notice and this permission notice shall be included in all copies or substantial
> portions of the Software.
>
> THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR IMPLIED, INCLUDING BUT NOT
> LIMITED TO THE WARRANTIES OF MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO
> EVENT SHALL THE AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER LIABILITY, WHETHER
> IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM, OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE
> USE OR OTHER DEALINGS IN THE SOFTWARE.

Godot includes third-party components (FreeType, HarfBuzz, the OpenXR loader, the default Open Sans font and
others) under their own permissive licenses. They're listed with their full license texts at
<https://godotengine.org/license> and in Godot's `COPYRIGHT.txt`.

## Downloaded by the app on first run (not included in the releases)

FrameTube doesn't ship these programs. On first run (or **Settings > Repair**) it downloads them from their
official GitHub releases, checks the published SHA-256 checksums, and keeps them in its own data folder. They
run as separate programs under their own licenses:

| Program | What it's for | License | Source |
|---|---|---|---|
| yt-dlp | finds the video and audio streams | The Unlicense (public domain) | <https://github.com/yt-dlp/yt-dlp> |
| FFmpeg (BtbN builds) | decodes video and audio, saves downloads | GPL v3 (these builds include GPL components) | <https://ffmpeg.org>, builds from <https://github.com/BtbN/FFmpeg-Builds> |
| Deno | runs YouTube's player code for yt-dlp | MIT | <https://github.com/denoland/deno> |

FFmpeg's source code is available from <https://ffmpeg.org/download.html>, and the exact build scripts from
the BtbN repository. FrameTube talks to these programs only through their command line and pipes, and doesn't
link to them.

## Trademarks and affiliation

FrameTube is an independent, unofficial project. It isn't affiliated with, endorsed by, or sponsored by
YouTube, Google, Valve or Steam. "YouTube" is a trademark of Google LLC; "Steam" and "Steam Frame" are
trademarks of Valve Corporation. The names are used only to describe what the app works with.

## Content

Videos are streamed from YouTube and belong to their creators. FrameTube doesn't host, store or distribute
any videos. Downloading is meant for your own offline viewing of videos you're allowed to watch: respect
creators' rights and YouTube's terms of service. Using a third-party client like FrameTube may go against
YouTube's terms of service; that's between each user and YouTube.
