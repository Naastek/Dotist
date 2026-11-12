# Dotist

<p align="right"><strong>English</strong> · <a href="README.zh-CN.md">简体中文</a></p>

**A native, local-first task window for macOS.** Dotist stays within reach as a lightweight floating panel, stores tasks in a local SQLite database, and exposes the same task service to the native UI and an optional local MCP interface.

<p align="center">
  <img src="docs/images/dotist-main-en.png" width="360" alt="Dotist floating task panel">
</p>

<p align="center"><sub>The floating task panel keeps groups, dates, and quick entry together (fictional English sample data).</sub></p>

## Features

**A sheet of glass on your desktop**
- **Native interface**: Built with SwiftUI and AppKit for Apple Silicon Macs running macOS 26+, using the system Liquid Glass material.
- **A floating panel that stays present**: The panel lives at the edge of your screen. When you switch to another app, its glass rim, depth, and shadow stay exactly as they were; the panel does not turn gray.
- **Compact bubble**: Collapse the panel into a bubble that shows the number of remaining tasks. Hover over it to reveal a strip with the next task.
- **Adjustable material**: Change main surface transparency, frost, unfocused content transparency, and group tab opacity in Settings. Changes apply immediately.

**Organizing tasks**
- **Hierarchy**: Up to 5 levels of subtasks. Drag a task or a whole subtree to reorder or change its level, and select several tasks to act on them together.
- **Group tabs**: Groups appear as tabs attached to the panel's left edge, as one body with the panel. Hover to expand a tab and see its name, drag tabs up and down to reorder them, and give each group its own color.
- **Tags**: Write `#tag` directly in a task title. Existing tags are suggested as you type.
- **Date filters**: Today, Tomorrow, This Week, Next Week, Next 7 Days, Overdue, No Date, Completed, and a custom date range.
- **Task views**: List, Calendar, Board, and Gantt, in a separate window for scheduling.

**Fast to use**
- **Keyboard first**: Shortcuts for adding, indenting, completing, multi-selecting, undo, and redo, with up to 100 undo steps per session.
- **Command palette**: `⌘K` searches tasks, groups, and task views.
- **Configurable shortcuts and toolbar**: Each of five actions can have a global shortcut, an in-app shortcut, or none. Toolbar buttons can be always visible, shown on hover, or hidden, in the order you choose.
- **Fonts and languages**: Choose serif and sans-serif fonts separately for Chinese and Latin text. The interface is available in Simplified Chinese, Traditional Chinese, English, French, and German.
- **Accessibility**: Follows the system Reduce Motion, Reduce Transparency, and Increase Contrast settings.

**Your data stays with you**
- **Local-first**: Tasks and preferences live in a SQLite database on your Mac. No account, and no cloud lock-in.
- **Optional local MCP interface**: Off by default, with no bundled AI models. When enabled, local AI tools can read and write tasks through a stdio proxy.

<p align="center">
  <img src="docs/images/dotist-calendar-en.png" width="900" alt="Dotist task views">
</p>

<p align="center"><sub>Task views provide Calendar, Board, and Gantt layouts for scheduled work (fictional English sample data).</sub></p>

## Usage

### Adding tasks
- Type in the bottom input bar and press `Return`. The focused input appears as a glass field.
- The group name on the left of the input bar chooses which group the task goes to. The calendar icon on the right sets a due date.
- When a list is empty, click the plus in the middle to focus the input bar with the current group or date already applied.
- To keep adding after a task: while editing, press `Return` for a new sibling, `Tab` to indent it as a subtask, `Shift-Tab` to outdent, or `Esc` to cancel. Empty tasks are not saved.

### Editing and completing
- Click a task title to edit it inline.
- Press `Space` or `⌘Return` to complete the selected task.
- `⌘Z` undoes and `Shift-⌘Z` redoes.

### Organizing
- **Drag**: Hold and drag a task to change its order or level, or to move it to another group. Dragging a task with subtasks moves the whole subtree.
- **Multi-select**: `Shift`-click selects a range, `⌘`-click adds or removes a task, and `Shift-↑/↓` extends the selection. Press `Tab` to indent the selection together.
- **Groups**: Click a tab on the left to switch groups. "All" is always first. Drag tabs up and down to reorder them. Choose "Manage Groups…" in the input bar's group menu to create, rename, recolor, or delete groups. Deleting a group keeps its tasks and moves them to no group.
- **Collapse**: Groups and completed tasks can be collapsed.

### Finding and filtering
- Press `⌘K` to open the command palette and search tasks, groups, and task views. Press it again to close.
- Use the date filter at the top of the panel to switch between Today, Tomorrow, This Week, and the other ranges.
- Click the task views button in the toolbar to open Calendar, Board, and Gantt.

### Panel and bubble
- Click the rightmost toolbar button to collapse the panel into a bubble. Click the bubble to expand it again.
- Drag any empty area of the panel to move it, and drag an edge to resize it.
- The toolbar also has color, keep-on-top, and lock-window buttons, shown on hover by default. Hold `⌘` and drag to reorder the buttons.

### Settings
Press `⌘,` to open Settings. Options are searchable. Commonly used:
- **Appearance and material**: theme, glass presets, main surface transparency, frost, unfocused content transparency, group tab opacity.
- **Fonts**: serif and sans-serif fonts for Chinese and Latin text.
- **Shortcuts**: set each action to global, in-app only, or off.
- **Toolbar**: button visibility and order.
- **MCP**: turn the local MCP interface on or off.

## Installation & Code Signing

1. Download the latest build from [GitHub Releases](https://github.com/Naastek/Dotist/releases/latest). When available for a release, prefer downloading `Dotist-arm64.dmg`. If a release does not yet include a DMG, download the `.tar.gz` application archive instead.
2. Install the application:
   - **DMG (preferred)**: Open the disk image, drag `Dotist.app` to the `Applications` shortcut, and eject the image.
   - **Archive fallback**: Extract the `.tar.gz` archive and move `Dotist.app` into `/Applications`.
3. Launch the installed app. The panel will open near the top-right corner of your screen.

> **Requirements**: macOS 26 or later on an Apple Silicon Mac (M-series).

### Gatekeeper & Security

- **Ad-hoc signing**: Current packaging scripts produce ad-hoc signed bundles without Developer ID signing or notarization.
- **First launch**: If macOS Gatekeeper blocks execution on first launch, open **System Settings > Privacy & Security** and choose **Open Anyway**.
- **Sparkle updates**: Application update archives are signed independently with Sparkle cryptographic keys, separate from Apple code signing. The release pipeline retains `.tar.gz` archives and the `appcast.xml` feed for Sparkle updates. Automatic update checks are enabled by default; automatic installation is off.

> **Note**: The latest release on GitHub might not reflect the most recent commit on `main`. Local candidate build scripts do not automatically produce an uploaded release.

## Data, Privacy, and MCP

### Local Storage & Privacy

Dotist requires no user accounts or online registration. Application data is stored locally on your machine:
- **Tasks database**: `~/Library/Application Support/com.dotist.app/tasks.sqlite`
- **Preferences**: `~/Library/Application Support/com.dotist.app/settings.json`

- **Sync**: There is no iCloud, CloudKit, or Android synchronization.

Update checks contact GitHub.

### Optional Local MCP (Model Context Protocol)

Dotist provides a local MCP interface that is **disabled by default** and includes **no bundled AI models**. When enabled in **Settings > MCP**, external MCP clients can connect directly to the application executable via stdio:

```bash
/Applications/Dotist.app/Contents/MacOS/dotist --mcp
```

- **Focus & sessions**: Standard task read and write calls operate silently without stealing window focus; only `focus_task` brings the app forward. Each client runs an isolated MCP session against the shared SQLite database.
- **Network disclosure**: While Dotist itself operates locally without user accounts, connected MCP clients can read and modify tasks and may transmit data to their own upstream AI providers. Using MCP is therefore not a zero-network guarantee.

## Development

Dotist is built with SwiftUI, AppKit, GRDB/SQLite, and the official Swift MCP SDK. It does not use Rust, Tauri, or web runtimes.

### Prerequisites

- Apple Silicon Mac running macOS 26 or later
- Xcode with macOS 26 SDK
- Swift
- Python 3

### Build Commands

```bash
# Run Swift core, MCP, and window test suites
bash native/scripts/test-native.sh

# Build isolated QA app
bash native/scripts/build-qa.sh

# Build local release candidate (does not publish a release)
bash native/scripts/build-local.sh
```

## Documentation

- [UI decisions](docs/ui-decisions.md): Interaction guidelines and visual contracts.
- [Native macOS app](docs/native-macos.md): Data layers, window architecture, QA, signing, and updates.
- [Native consolidation](docs/native-consolidation.md): Technical architecture, Swift task service, and MCP contracts.
