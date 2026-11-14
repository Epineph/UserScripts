# UserScripts

## Find and encrypt files: `find-encrypt.sh`

[`find-encrypt.sh`](find-encrypt.sh) finds files across multiple paths, filters
by extensions or filename globs, and optionally uses fzf for selection. It
creates a verified encrypted 7z archive, with optional preserved paths and
explicit source deletion/pruning. See the [complete guide](docs/find-encrypt.md)
or `./find-encrypt.sh --help` for options and examples.

```bash
# Preview multiple file types from multiple roots.
./find-encrypt.sh -t ~/Downloads /mnt/images -e iso,img \
  --exclude ~/Downloads/old --keep-paths -o images --dry-run

# Choose the files interactively and enter a hidden passphrase.
./find-encrypt.sh -t ~/Downloads /mnt/images -e iso,img \
  --interactive --keep-paths -o images
```

## YouTube downloads: `yt-best`

[`yt-best.sh`](yt-best.sh) downloads yt-dlp's best available video and audio,
then merges them without re-encoding. The default container is MKV; use `--mp4`
to remux to MP4. See the [complete guide](docs/yt-best.md) or `./yt-best.sh --help`
for all options, cookie behavior, troubleshooting, and examples.

```bash
# Download as MP4; quote the URL so the shell preserves '&' and '?'.
yt-best --mp4 'https://www.youtube.com/watch?v=Y-W-w8yNiKU&t=1921s'

# Check the selected streams without downloading the full video.
yt-best --mp4 --simulate 'https://youtu.be/Y-W-w8yNiKU'

# Use your signed-in Chrome session immediately.
yt-best --browser chrome --mp4 'https://youtu.be/Y-W-w8yNiKU'
```

By default, the wrapper tries anonymously and retries once with Chrome cookies
when YouTube requests sign-in. On Linux/Hyprland it selects the Secret Service
keyring (`chrome+gnomekeyring`), which can decrypt this host's Chrome login
cookies. `--no-cookies` disables browser access and automatic cookie retries.
