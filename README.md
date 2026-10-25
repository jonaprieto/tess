# tess

A tiling window manager for macOS 27 that never hides a window. Each monitor is a row of
columns, each column a stack; no virtual workspaces, so a crash, a hang or an unplugged
monitor cannot strand a window off-screen.

```sh
make install   # build, sign, start at login and after crashes; grant Accessibility once
make test      # layout rules, frames, commands and config
tess tree      # monitors, columns, windows, and what is not tiled
tess focus left
```

Keys and modes are in `tess default-config`. To change them, use Open config in the menu
bar item (it writes the defaults to `~/.config/tess/config.json` first), then `alt-shift-r`.
`alt-r` is resize mode and `alt-shift-semicolon` service mode (`r` re-tile, `w` rescue
windows, `f` float); both show their keys on screen while active.

Switching from AeroSpace:

```sh
launchctl bootout gui/$(id -u)/bobko.aerospace.keepalive
rm ~/Library/LaunchAgents/bobko.aerospace.keepalive.plist
make install
```

Log: `~/Library/Logs/tess.log`.

Limits: macOS Spaces other than native fullscreen are not modeled (windows on another
regular Space keep their place in the layout); an app with a minimum size can overlap its
neighbor; accordion and tess fullscreen reset when a window comes back from another Space.
