# Exrawk

wayluigi-based file explorer. Yazi-style three-panel UX, rawk conventions,
shared command-line. Linux x86_64.

![Exrawk three-panel file explorer](https://files.paths.place/exrawk-1.png)
![Exrawk with the preview pane and command palette](https://files.paths.place/exrawk-2.png)

## Layout

```
bookmarks │ tabs + file list │ preview
```

Multi-tab cwds in the middle column. The right pane is a read-only
`rawk-bufferlib` editor preview with a title bar showing the active entry.
Icons are vendored from yazi's TOML and rendered through a Nerd-Font glyph.

## Run

```
./Exrawk             # open at $PWD
./Exrawk path/to/dir # open with that as the starting cwd
```

## Keys (filelist focused)

| Key | Action |
|---|---|
| `j` `k` `Up` `Down` | Move selection |
| `Enter` / `l` / `Right` | Enter dir / open file via configured handler |
| `Backspace` / `h` / `Left` | Up one dir |
| `Home` / `End` | Top / bottom |
| `b` | Focus bookmarks pane |
| `c` | Chord leader (`c b` = bookmark, `c d` = rm-rf prefill, `c n` = touch prefill, `c N` = mkdir prefill, `c h` = toggle hidden, `c y` = yank, `c p` = paste, `c x` = mv prefill, `c c`/`c f` = clip selection/cwd) |
| `.` | Toggle hidden files |
| `Shift+j/k` | Extend yank multiselect while moving |

Window-level:

| Key | Action |
|---|---|
| `Alt+C` | Open command palette |
| `Alt+F` / `Alt+E` / `Alt+V` | File / Edit / View menu |
| `Alt+T` / `Alt+Q` | New / close tab |
| `Alt+Shift+Left` / `Right` | Cycle tabs |

## Commands

Type after `Alt+C`. Chain segments with `&&` (`cd /tmp && tab.new`). Unknown
names fall through to bash under the active tab's cwd.

| Command | What |
|---|---|
| `:cd <path>` / `:refresh` | Change cwd / re-list |
| `:tab.new` `:tab.close` `:tab.next` `:tab.prev` | Tab ops |
| `:hidden [on\|off]` / `:hidden.toggle` | Dotfile visibility |
| `:preview.toggle` | Right-pane preview on/off |
| `:sort <dirs-first\|name\|mtime>` | Sort mode |
| `:bookmark.add` / `:bookmark.del` | Bookmark current cwd |
| `:open` | Run the external handler for the selected file |
| `:clip <path>` / `:paste` / `:yank.clear` | Clipboard + yank |
| `:focus.files` / `:focus.bookmarks` | Move focus |
| `:theme <name>` | Switch theme |
| `:exit` | Quit |

Shell prefix: `dt <cmd>` runs detached (double-fork, reparented to init) for
launches that outlive the bash wait — `dt feh foo.png`, `dt mpv ./clip.mkv`.

## Config

`~/.config/Exrawk/config` — seeded on first run with probed font paths.

```
font_path:        # primary mono .ttf (empty → luigi bitmap)
icon_font_path:   # Symbols Nerd Font fallback (probed)
font_size:        14
theme:            default
hidden:           off
preview:          on
sort:             dirs-first
open.text:        edrawk
open.image:
open.video:
open.audio:
```

Other state: `bookmarks`, `recents.dirs` in the same dir.

## Build

```
./download-deps.sh
./release.sh --local
```

X11 and Wayland flavors via `-d:wayland`, same as Prawk.

## License

GPLv3.
