# tess

A tiling window manager for macOS 27 that never hides a window. Each monitor is a row of
columns, each column a stack (or an accordion); no virtual workspaces, so a crash, a hang
or an unplugged monitor cannot strand a window off-screen.

```sh
make install   # build, sign, start at login and after crashes; grant Accessibility once
make test
tess tree      # monitors, columns, windows, and what is not tiled
tess focus left
```

## Keys

Everything is in `tess default-config`. The ones to know:

- `alt-h/j/k/l` focus, `alt-shift-h/j/k/l` move, `alt-1/2/3` screens, `alt-enter` fullscreen.
- Hyper+T (Nav+T on the Air96): tess mode, where the same actions need no modifier.
- Hyper+G (Nav+G) or `alt-space`: the picker.
- `alt-shift-backspace`: send everything on this screen to the next one.

## Picker

Type to filter windows (every Space), Brave and Safari tabs, apps, and, once you type,
Brave bookmarks and browser history. Enter shows a map of every screen: a letter takes
that window's place, shift+letter goes beside it, enter goes next to the focused window,
a digit picks a screen, `g` just jumps, `f` floats.

- `cd ~/folder` or `code ~/folder` opens a folder in iTerm or VS Code (Tab completes).
- `f name` finds files by name (Spotlight, ranked by fzf); `rg text` finds text in files.
- In tess mode, `x` closes the focused window and picks what fills its place.

## Settings

Settings in the menu bar item (or `tess settings`) edits gaps, picker verbs, app lists and
key bindings. It writes only what differs from the defaults to
`~/.config/tess/config.json`; the file layers on top of the defaults, and `null` removes a
default binding.

## Permissions

Accessibility (asked at first start). Automation for Brave and Safari (asked the first time
the picker reads tabs). Browser history needs Full Disk Access for
`~/tess/build/tess` (System Settings, Privacy & Security); without it the picker still lists
tabs and Brave bookmarks.

Log: `~/Library/Logs/tess.log`.

Limits: macOS Spaces other than native fullscreen are not modeled; an app with a minimum
size can overlap its neighbor.
