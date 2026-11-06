# Historical preview styles

These four CSS files were moved byte for byte from the retired React client's
`src/` directory on 2026-11-06. The twelve HTML snapshots in the parent directory
load them via `styles/`, followed by `../evolution-v3.1.css` (both paths are
relative to each HTML file in `design-system/previews/`). No JavaScript build or
Node dependency is needed. Keep these styles with the snapshots; they document
the earlier web design rather than the current Swift application's UI.

The original `tokens.css` header refers to the web client's generated tokens.
It is preserved as part of that snapshot; the design sources elsewhere in
`design-system/` remain independent.
