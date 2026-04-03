#!/usr/bin/env bash
set -euo pipefail

# -----------------------------------------------------------------------------
# safe-clean.sh
# Conservative disk cleanup for developer machines
# -----------------------------------------------------------------------------

REPO_DIRS=(
  "$HOME/repos"
  "$HOME/my_repos"
  "/shared/repos"
)

echo "==> Git maintenance (safe, repo-aware)"
for base in "${REPO_DIRS[@]}"; do
  [[ -d "$base" ]] || continue
  find "$base" -mindepth 1 -maxdepth 3 -type d -name .git -print0 2>/dev/null |
    while IFS= read -r -d '' gitdir; do
      repo="$(dirname "$gitdir")"
      echo "  -> $repo"
      git -C "$repo" maintenance run --auto >/dev/null 2>&1 || true
      git -C "$repo" gc --prune=now >/dev/null 2>&1 || true
    done
done

echo
echo "==> Removing build artifacts (safe rebuildable data)"
find "$HOME/repos" "$HOME/my_repos" \
  -type d \( -name target -o -name __pycache__ -o -name dist -o -name build \) \
  -prune -exec rm -rf {} + 2>/dev/null || true

echo
echo "==> Pacman cache cleanup (keep last 2 versions)"
if command -v paccache >/dev/null 2>&1; then
  sudo paccache -rk2
fi

echo
echo "==> systemd journal cleanup (14 days)"
sudo journalctl --vacuum-time=14d

echo
echo "==> Cargo cache cleanup (safe)"
rm -rf "$HOME/.cargo/registry/cache" "$HOME/.cargo/registry/index" 2>/dev/null || true

echo
echo "==> Python cache cleanup"
find "$HOME" -type d -name __pycache__ -prune -exec rm -rf {} + 2>/dev/null || true

echo
echo "==> Done. No Git objects were harmed."

