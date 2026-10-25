# tess

A tiling window manager for macOS 27 that never hides a window. Each monitor is a row of
columns, each column a stack (or an accordion); no virtual workspaces, so a crash, a hang
or an unplugged monitor cannot strand a window off-screen.

Install (macOS 27, Apple Silicon):

```sh
brew tap jonaprieto/tap
brew install jonaprieto/tap/tess
brew services start tess   # now and at login; grant Accessibility once
```

From source:

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
- Hyper+J (or `g` in tess mode) is jump mode: every window shows a border and a letter on its
  top edge (it keeps the letter while it lives), every screen its number. A letter goes to
  that window, shift+letter swaps the focused window with it, a digit goes to that screen,
  shift+digit moves the focused window there. `"overlay": {"window_labels": "always"}` keeps
  the labels on screen all the time; `"off"` never shows them (also in Settings).

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

## Logs

- `~/Library/Logs/tess/events.jsonl`: one JSON object per line for everything that changes:
  apps opening and quitting, windows opening, closing, moving to another Space or keeping
  their own size, focus (by tess or by macOS), every command and where it came from (hotkey,
  CLI, menu, picker), the layout after it, screens, Spaces, modes, picks, config reloads,
  watchdog exits, and how long the picker took to open. A full snapshot of the model and the
  machine (macOS, uptime, thermal state, Low Power Mode, memory, tess's CPU and memory) is
  written at start, on screen changes and every ten minutes. Rotated at 20 MB. It stays on
  this Mac; picker queries are not recorded.
- `tess state` prints the same snapshot now.
- `~/Library/Logs/tess.log`: short human-readable notes.

Limits: macOS Spaces other than native fullscreen are not modeled; an app with a minimum
size can overlap its neighbor.
