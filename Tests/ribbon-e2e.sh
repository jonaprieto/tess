#!/bin/bash
# Runs aRibbonOfRealWindows, which moves real windows: only those of four apps it opens here and
# quits after, and it stops if any of them is already open. Meanwhile the running tess ignores
# them, through its config, which comes back byte for byte however this ends.
set -u
cd "$(dirname "$0")/.."

config="$HOME/.config/tess/config.json"
backup="$config.e2e"
names=("Chess" "Dictionary" "Font Book" "Weather")
bundles=(com.apple.Chess com.apple.Dictionary com.apple.FontBook com.apple.weather)

[ -f "$config" ] || { echo "no $config"; exit 1; }
[ -e "$backup" ] && { echo "$backup is there: a run did not finish, look at it first"; exit 1; }
for name in "${names[@]}"; do
  pgrep -x "$name" >/dev/null && { echo "$name is open: close it first"; exit 1; }
done
swift build --build-tests >/dev/null 2>&1 || { echo "the tests do not build"; exit 1; }

finish() {
  for name in "${names[@]}"; do osascript -e "tell application \"$name\" to quit" >/dev/null 2>&1; done
  sleep 1.5
  for name in "${names[@]}"; do pkill -x "$name"; done
  mv -f "$backup" "$config"
  build/tess reload >/dev/null
}
cp -p "$config" "$backup"
trap finish EXIT

python3 -I - "$config" "${bundles[@]}" <<'EOF'
import json, sys
path, bundles = sys.argv[1], sys.argv[2:]
config = json.load(open(path))
config["ignore"] = config.get("ignore", ["io.github.ender-wang.EdgeMark"]) + bundles
json.dump(config, open(path, "w"), indent=2)
EOF
[ $? -eq 0 ] || exit 1
# Without this the running tess would tile the test's windows in among those in use.
build/tess reload >/dev/null || { echo "tess did not reload"; exit 1; }
sleep 0.6
for name in "${names[@]}"; do open -g -a "$name"; done
sleep 3

out=$(RIBBON_E2E=1 swift test --skip-build --filter aRibbonOfRealWindows 2>&1)
status=$?
echo "$out" | grep -E "^E2E|recorded an issue|Test run|aRibbonOfRealWindows\(\) (passed|failed)|↳"
# A clean exit alone is not enough: a test process can end early and still report 0.
[ $status -eq 0 ] && echo "$out" | grep -q "Test aRibbonOfRealWindows() passed"
