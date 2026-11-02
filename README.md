# Dotist

<p align="right"><strong>English</strong> · <a href="README.zh-CN.md">简体中文</a></p>

**A local-first task window for macOS.** Dotist stays within reach as a small floating panel, keeps tasks in a local SQLite database, and exposes the same task service to the native UI and local MCP clients.

<p align="center">
  <img src="docs/images/dotist-main-en.png" width="360" alt="Dotist main task panel">
</p>

<p align="center"><sub>The main panel keeps groups, dates, and quick entry together without taking over the desktop.</sub></p>

## Why Dotist

Most task managers assume a full window and a cloud account. Dotist takes a smaller approach:

- **Local first.** Tasks and settings live on your Mac in SQLite and a local settings file.
- **Always close by.** Use a floating panel, a menu bar entry, or a compact bubble that expands on hover.
- **Keyboard friendly.** Add, indent, select, move, complete, and undo without reaching for the mouse.
- **One task service.** The SwiftUI interface and the built-in MCP server read and write through the same Swift task core.

## Features

- Nested tasks up to five levels, multi-select, drag-and-drop ordering, and undo/redo.
- Date filters for today, tomorrow, this week, next week, the next seven days, overdue, undated, completed, and custom ranges.
- Group tabs, per-group floating panels, group colors, and collapsible group sections.
- A compact floating bubble showing the remaining task count, with the next task revealed on hover.
- A command palette with `⌘K`.
- Calendar, board, and Gantt task views.
- Native macOS appearance, Liquid Glass surfaces, configurable fonts, and reduced-motion/accessibility handling.
- Local MCP access for compatible AI clients, disabled by default.

<p align="center">
  <img src="docs/images/dotist-calendar-en.png" width="900" alt="Dotist calendar, board, and Gantt task views">
</p>

<p align="center"><sub>Calendar, board, and Gantt views share the same tasks and dates as the floating panel.</sub></p>

## Install

1. Download the latest app from [GitHub Releases](https://github.com/Naastek/Dotist/releases/latest).
2. Move `Dotist.app` to **Applications** or another local folder.
3. Launch Dotist. The panel opens near the top-right corner of the screen.

Requirements: **macOS 26 or later** on an **Apple Silicon Mac**. Intel builds are not published.

The current app is ad-hoc signed and is not notarized by Apple. If macOS blocks the first launch, open **System Settings → Privacy & Security** and choose **Open Anyway**.

## Usage

### Add and edit tasks

- Type in the bottom input and press `Return` to add a task.
- Press `Return` again to keep adding siblings.
- Press `Tab` to indent, `Shift-Tab` to outdent, and `Esc` to cancel.
- Press `Space` or `⌘Return` to complete a task.
- Click a task title to edit it.

### Organize

- Use the group tabs along the left edge to switch groups.
- Drag tasks or whole subtrees to reorder or change nesting.
- Use `Shift` or `⌘` click for multi-select.
- Right-click a group for actions such as opening it in its own panel or changing its color.
- Use `⌘Z` and `Shift-⌘Z` for undo and redo.

### Find and focus

- Press `⌘K` to open the command palette.
- Use the date filters to narrow the list.
- Click the toolbar’s collapse button to turn the panel into a floating bubble.
- Open **Task views** for calendar, board, and Gantt layouts.
- Open Settings with `⌘,` or the menu bar item.

## Local MCP

Dotist includes an optional local MCP server. It is off by default and does not include an AI model.

Enable it in **Settings → MCP**, then copy the generated command or JSON configuration into your MCP client. The client launches the app executable in stdio proxy mode:

```sh
~/Applications/Dotist.app/Contents/MacOS/dotist --mcp
```

The proxy connects to the app’s local Unix socket service. Ordinary reads and writes do not steal keyboard focus; only `focus_task` brings the app forward. Each client gets its own MCP session while sharing the same task database and change notifications.

Available tools include `list_tasks`, `get_task`, `search_tasks`, `add_tasks`, `update_task`, `delete_task`, `restore_task`, date and parent operations, group operations, and `focus_task`.

## Data and privacy

- Tasks are stored in `~/Library/Application Support/com.dotist.app/tasks.sqlite`.
- Preferences are stored in `settings.json` next to the database.
- Dotist does not require an account and does not send tasks to a cloud service.
- Android and iCloud/CloudKit sync are not implemented. The SQLite schema reserves local change metadata for future work, but it is not an active sync feature.

## Development

The current macOS app is built with SwiftUI, AppKit, GRDB/SQLite, and the official Swift MCP SDK. It does not link Rust, Tauri, or a web runtime.

Requirements: macOS 26 or later, an Apple Silicon Mac, Xcode with a macOS 26+ SDK, Swift, and Python 3.

```sh
bash native/scripts/test-native.sh   # Swift core, MCP, and window tests
bash native/scripts/build-qa.sh      # isolated QA app
bash native/scripts/build-local.sh   # local release candidate
```

SwiftPM dependencies are locked by `native/Package.resolved`. Versioning, minimum macOS, and public update configuration live in `native/app.json`.

## Updates and release

Dotist uses Sparkle with GitHub Releases and the native `appcast.xml`. Automatic update checks are enabled by default; automatic installation is off by default. A downloaded update is installed when the app exits normally and takes effect on the next launch.

A push to `main` runs native tests, builds the app, creates a complete draft release, downloads and verifies the published assets, checks the current `main` SHA, and then publishes the release. The CI signing key must match the public Sparkle key in `native/app.json`.

The application bundle is currently ad-hoc signed. Apple Developer ID signing and notarization are separate from the Sparkle update trust root and have not yet been completed.

## Documentation

- [UI decisions](docs/ui-decisions.md): current interaction and visual contracts.
- [Native macOS app](docs/native-macos.md): data, windows, build, QA, signing, and updating.
- [Native architecture](docs/native-consolidation.md): Swift task service, MCP, and release architecture.
