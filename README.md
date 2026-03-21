# Finite

A spatial terminal multiplexer for macOS. Terminals live on an infinite canvas that you can pan, zoom, and arrange freely.

Built on [Ghostty](https://ghostty.org)'s terminal engine via [libghostty](https://github.com/ghostty-org/ghostty).

<p align="center">
  <img src="https://i.imgur.com/laXCGji.jpeg" alt="Finite" width="100%">
</p>

## Building

### Requirements

- macOS 26 or later
- Xcode 26 or later
- [Zig](https://ziglang.org/) (`brew install zig`)

### Setup

Ghostty is included as a git submodule and cloned automatically with `--recurse-submodules`.

```bash
git clone --recurse-submodules https://github.com/ceIia/finite.git
cd finite/Finite
make setup    # builds GhosttyKit, copies headers and resources
make build    # debug build
make release  # release build, installs to /Applications
```

`make setup` builds the GhosttyKit framework from the bundled Ghostty source, caches it by commit SHA, symlinks it into the Xcode project, and copies terminfo and shell-integration resources.

## Usage

### Canvas

The canvas is infinite. Pan with the trackpad or scroll wheel, zoom with pinch gestures. Double-click empty space to zoom to fit all terminals.

Scroll direction is detected automatically: horizontal scrolling pans the canvas, vertical scrolling goes to the terminal under the cursor. Hold `Ctrl` to force canvas panning.

### Terminals

| Action | Shortcut |
|---|---|
| New Terminal | `Cmd+N` |
| Duplicate Terminal | `Cmd+Shift+D` |
| Close Terminal | `Cmd+W` |

New terminals are placed automatically next to the focused terminal without overlapping. Duplicating copies the terminal's config and working directory.

### Selection

| Action | How |
|---|---|
| Select | Click a terminal |
| Multi-select | `Cmd+Click` |
| Range select | `Shift+Click` in sidebar |
| Marquee select | Drag on empty canvas |
| Deselect all | `Escape` |

Selected terminals can be moved as a group, closed together, or tidied into a grid with `Cmd+Opt+T`.

### Dragging and Resizing

Drag terminals by their title bar, or `Opt+Drag` from anywhere on the terminal. Resize from any edge or corner. Snap guides appear when edges align with other terminals. Hold `Cmd` to disable snapping. A cell size indicator shows during resize.

### Navigation

| Shortcut | Action |
|---|---|
| `Cmd+Opt+Arrow` | Move focus to nearest terminal in that direction |
| `Cmd+Opt+F` | Zoom to fit focused terminal |
| `Cmd+Opt+0` | Zoom to fit all |

### Sidebar

Toggle with `Cmd+Opt+S`. Lists all terminals with status indicators: focused (blue), selected (faded blue), activity (pulsing orange), running process (bolt icon). Hovering a row briefly pulses the terminal on the canvas.

### Minimap

Toggle with `Cmd+Opt+M`. Shows a thumbnail overview of all terminals and the current viewport in the bottom-right corner.

### State Persistence

Window position, canvas transform, terminal layout, and working directories are saved on quit and restored on next launch. State is stored at `~/.config/finite/state.json`.

## All Shortcuts

| Shortcut | Action |
|---|---|
| `Cmd+N` | New Terminal |
| `Cmd+Shift+D` | Duplicate Terminal |
| `Cmd+W` | Close Terminal |
| `Cmd+Opt+S` | Toggle Sidebar |
| `Cmd+Opt+M` | Toggle Minimap |
| `Cmd+Opt+0` | Zoom to Fit All |
| `Cmd+Opt+F` | Zoom to Fit Terminal |
| `Cmd+Opt+T` | Tidy Selection |
| `Cmd+Opt+Arrow` | Navigate |
| `Escape` | Deselect All |
| `Cmd+Click` | Toggle selection |
| `Opt+Drag` | Move terminal from anywhere |
| `Ctrl+Scroll` | Force canvas pan |
| `Cmd` (while dragging) | Disable snap guides |

## License

See [LICENSE](../LICENSE).
