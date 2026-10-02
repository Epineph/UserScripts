chrome-zoom() {
  if pgrep -u "$UID" -x chrome >/dev/null; then
    print -u2 "Quit Chrome completely first, including background processes."
    return 1
  fi

  python3 - "${1:-125}" <<'PY'
import json, math, os, shutil, sys, tempfile
from pathlib import Path

percent = float(sys.argv[1])
if not 25 <= percent <= 500:
    sys.exit("Choose a percentage between 25 and 500.")

config = Path(os.environ.get("XDG_CONFIG_HOME") or Path.home() / ".config")
prefs = config / "google-chrome/Default/Preferences"
data = json.loads(prefs.read_text())
data.setdefault("partition", {}).setdefault("default_zoom_level", {})["x"] = (
    math.log(percent / 100) / math.log(1.2)
)

shutil.copy2(prefs, prefs.with_name("Preferences.zoom-backup"))
with tempfile.NamedTemporaryFile(mode="w", dir=prefs.parent, delete=False) as f:
    json.dump(data, f)
    temporary = Path(f.name)
temporary.replace(prefs)
print(f"Default page zoom set to {percent:g}%. Start Chrome normally.")
PY
