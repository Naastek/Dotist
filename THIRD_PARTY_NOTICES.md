# Third-Party Notices

Dotist includes third-party software and font assets. The full license texts
are distributed with the native app in `Contents/Resources/Licenses/`.

## Adapted source code

### Tic

- Upstream: https://github.com/kasvith/tic
- License: MIT
- Copyright: Copyright (c) 2026 Kasun Vithanage
- Full license: `third_party/Tic-LICENSE.txt` in the source tree and
  `Tic-LICENSE.txt` in the app bundle

Dotist's local MCP proxy and service are adapted from Tic's MCP integration.

## Swift Package dependencies

| Component | License | Bundled license or notice |
| --- | --- | --- |
| GRDB.swift | MIT | `GRDB.swift-LICENSE` |
| Model Context Protocol Swift SDK | MIT and Apache-2.0 | `swift-sdk-LICENSE` |
| EventSource | MIT | `eventsource-LICENSE.md` |
| Swift Atomics | Apache-2.0 | `swift-atomics-LICENSE.txt` |
| Swift Collections | Apache-2.0 | `swift-collections-LICENSE.txt` |
| Swift Log | Apache-2.0 | `swift-log-LICENSE.txt`, `swift-log-NOTICE.txt` |
| SwiftNIO | Apache-2.0 | `swift-nio-LICENSE.txt`, `swift-nio-NOTICE.txt` |
| Swift System | Apache-2.0 | `swift-system-LICENSE.txt` |
| Sparkle | MIT and external component licenses | `Sparkle-LICENSE.txt` |

The bundled license files contain the complete copyright, permission, notice,
and warranty terms supplied by each upstream project.

## Fonts

The following fonts are distributed under the SIL Open Font License 1.1:

- Noto Sans SC, TC, and JP
- Noto Serif SC, TC, and JP
- Source Sans 3
- Source Serif 4
- Newsreader
- Atkinson Hyperlegible Next
- Chiron Sung HK

Each font's complete license is bundled under its corresponding
`<font-name>-OFL.txt` file.

## Apple frameworks

The native app links to Apple system frameworks provided by macOS. Those
frameworks are governed by Apple's SDK and operating-system terms and are not
redistributed as part of this repository.

## Legacy source

The retained web, Rust, and Tauri source is not part of the current native
build or release and its dependencies are not included in this notice.
