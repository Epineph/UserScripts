# yt-best

Run `./yt-best.sh` from this checkout or `yt-best` after installing a copy on
your PATH. `yt-best --help` includes the options and copyable examples.

The wrapper selects `bv*+ba/b`: the best format containing video, with the best
separate audio when needed, falling back to a combined format. It sets no size
or resolution cap and does not re-encode. Files are named with their title,
video ID, and format ID. Interrupted downloads can resume; existing downloads
are not overwritten. Saved yt-dlp configuration is ignored so it cannot silently
limit quality or override the wrapper's cookie choices.

## Options

| Option | Meaning |
| --- | --- |
| `-P, --path DIR`, `--path=DIR` | Output directory; defaults to the current directory. |
| `-b, --browser SPEC`, `--browser=SPEC` | Read this browser's cookies immediately. |
| `--cookies-from-browser SPEC`, `--cookies-from-browser=SPEC` | Alias for `--browser`. |
| `--no-cookies` | Disable browser access and automatic cookie retries. |
| `--mp4` | Merge/remux to MP4 without re-encoding. |
| `--keep-original`, `--keep-container` | Let yt-dlp choose a compatible container. |
| `-F, --list-formats` | Fetch metadata and list accessible formats. |
| `-s, --simulate` | Check stream selection without downloading the full video. |
| `-v, --verbose` | Include yt-dlp diagnostics, also with format listing. |
| `-h, --help` | Show explanations and examples. |
| `-V, --version` | Show the wrapper version. |
| `--` | Treat the remaining arguments as URLs. |

Choose only one cookie option. `--mp4` and `--keep-original` are mutually
exclusive. MP4 conversion fails if its container cannot hold the selected
codecs; it does not silently lower quality. A URL's `&t=` playback timestamp
does not trim the downloaded video.

## Chrome cookies and Hyprland

The default first attempt uses no browser cookies. If the YouTube extractor
reports a sign-in requirement, the wrapper retries that URL once using Chrome.
Unrelated network, format, and ffmpeg errors do not trigger browser access.
For multiple URLs, previously completed URLs are not replayed. A playlist URL
is retried as a whole; existing files remain protected by `--no-overwrites`.

Chrome cookies are read afresh by yt-dlp on the authenticated attempt. The
wrapper does not export a persistent cookie file. A private temporary stderr
log is removed when the wrapper exits.

On this Arch/Hyprland host, yt-dlp's desktop detection chooses `basictext`, which
cannot decrypt Chrome's encrypted v11 cookies. Explicitly selecting
`chrome+gnomekeyring` fixes that: it uses the Secret Service keyring containing
Chrome's encryption key. The wrapper applies this choice on Linux/Hyprland,
including to `--browser chrome` and `--browser 'chrome:Profile 1'`. Other desktop
sessions retain yt-dlp's default selection. An explicit keyring is always
preserved, for example `chrome+kwallet6:Default` or `chrome+basictext`.

Run as your normal desktop user, with access to the same unlocked keyring as
Chrome. The browser profile must be the one signed in to YouTube. To find its
directory, open `chrome://version` in that profile and inspect **Profile Path**.

## Examples

```bash
# Default MKV, with Chrome cookies only when YouTube requests sign-in.
yt-best 'https://youtu.be/Y-W-w8yNiKU'

# MP4, preserving the selected video/audio quality.
yt-best --mp4 'https://www.youtube.com/watch?v=Y-W-w8yNiKU&t=1921s'

# Custom directory, or let yt-dlp choose the container.
yt-best --mp4 -P "$HOME/Videos" 'https://youtu.be/Y-W-w8yNiKU'
yt-best --keep-original 'https://youtu.be/Y-W-w8yNiKU'

# Skip the anonymous attempt and use Chrome immediately.
yt-best --browser chrome --mp4 'https://youtu.be/Y-W-w8yNiKU'

# Another Chrome profile, preserving spaces as part of the spec.
yt-best --browser 'chrome:Profile 1' 'https://youtu.be/Y-W-w8yNiKU'

# Explicit keyring overrides for Secret Service or KWallet.
yt-best -b 'chrome+gnomekeyring:Default' 'https://youtu.be/Y-W-w8yNiKU'
yt-best -b 'chrome+kwallet6:Default' 'https://youtu.be/Y-W-w8yNiKU'

# Firefox also works as an explicit cookie source.
yt-best --cookies-from-browser firefox 'https://youtu.be/Y-W-w8yNiKU'

# Never access your browser cookies.
yt-best --no-cookies 'https://youtu.be/Y-W-w8yNiKU'

# Inspect metadata, then simulate the actual MP4 stream selection.
yt-best -F 'https://youtu.be/Y-W-w8yNiKU'
yt-best --mp4 --simulate 'https://youtu.be/Y-W-w8yNiKU'

# Include diagnostics for browser/profile problems.
yt-best -v -F --browser chrome 'https://youtu.be/Y-W-w8yNiKU'

# Multiple URLs (replace these two illustrative IDs).
yt-best --mp4 'https://youtu.be/VIDEO_ID_1' 'https://youtu.be/VIDEO_ID_2'
```

Always quote URLs. In Bash and Zsh, an unquoted `&` starts a background job and
splits the command before the script receives it. The wrapper cannot recover
arguments already interpreted by the shell.

## Requirements and troubleshooting

Downloads require `yt-dlp` and `ffmpeg`. Format listing and simulation do not
require ffmpeg and do not create the output directory. Simulation retains
`--check-formats`, so it may probe small media fragments. YouTube also needs a
supported JavaScript runtime and the yt-dlp EJS challenge scripts; Deno is
enabled by yt-dlp by default. This host already has these dependencies and
`python-secretstorage` for the Secret Service keyring.

If cookies still cannot be decrypted, check that you are running from your
desktop session as the same user as Chrome and that its keyring is unlocked.
An explicit keyring in `--browser` overrides automatic keyring selection. If
YouTube still requests sign-in after cookie extraction, open the same video in that
Chrome profile, complete any browser prompt, and retry. `--browser` bypasses
the initial anonymous attempt but cannot guarantee that YouTube accepts the
session.

Primary documentation:

- [yt-dlp cookie FAQ](https://github.com/yt-dlp/yt-dlp/wiki/FAQ#how-do-i-pass-cookies-to-yt-dlp)
- [YouTube cookie notes](https://github.com/yt-dlp/yt-dlp/wiki/Extractors#exporting-youtube-cookies)
- [JavaScript runtime/EJS setup](https://github.com/yt-dlp/yt-dlp/wiki/EJS)

## Installation and checks

To refresh a separately installed copy after editing the repository script:

```bash
sudo install -m 755 ./yt-best.sh /usr/local/bin/yt-best
cmp ./yt-best.sh /usr/local/bin/yt-best
yt-best --version
```

Offline regression checks use fake downloader commands, without accessing
Chrome or YouTube:

```bash
bash -n yt-best.sh
shellcheck yt-best.sh
shfmt -d -i 2 -ci yt-best.sh
/usr/bin/python3 -m pytest -q tests/test_yt_best.py
```
