---
name: mgread-discovery-composition
description: Develop or revise MgRead source-driven discovery components, recursive Plugin API contracts, semantic icons, responsive layouts, or Alice/Shudugu discovery composition. Use for changes spanning Runtime, Flutter Facade/UI, the official plugin template, or real source output; do not use for unrelated reader or library work.
---

# MgRead Discovery Composition

Build discovery as a validated source-owned component tree rendered by host-owned UI. Work from the MgRead repository root containing this skill unless the user names another checkout.

## Start safely

1. Read the repository `AGENTS.md`, inspect the current branch, `git status --short`, and only task-related diffs. Preserve unrelated dirty work.
2. Read target file headers, nearest nested instructions, public types, and direct tests. Use `docs/development/README.md` to route to only the relevant `docs/core.md` sections.
3. Treat this skill as decision guidance, not proof of current code. Verify names, versions, selectors, and tests in the checkout before editing.

## Load only the relevant detail

- For wire types, validators, Runtime/Facade changes, nullable fields, or semantic icons, read [references/contract.md](references/contract.md).
- For component selection, responsive composition, or Alice/速读谷 output, read [references/source-composition.md](references/source-composition.md).
- Before testing, packaging, versioning, or claiming acceptance, read [references/verification.md](references/verification.md).

Cross-layer feature work normally needs all three. A local visual adjustment should not load contract details unless the public shape changes.

## Preserve these decisions

- The source declares content semantics and composition; MgRead owns widgets, theme, breakpoints, sizes, accessibility, navigation, and interaction.
- Plugins return only allowlisted component layouts and semantic icon names. Never accept Flutter code, `IconData`, font codepoints, arbitrary styles, colors, or source-controlled widget dimensions.
- Keep stable opaque source IDs, explicit nullable values, bounded arrays, and real source-derived content. Do not fabricate missing fields or host-owned hot terms.
- Full-width sections use vertical composition. Use a two-column group only for genuinely parallel compact panels, not for ranking/category sections that need horizontal room.
- `coverGrid` is host-responsive: compact phones show three covers per row and wider app layouts show four before denser desktop breakpoints. Sources do not choose column counts.
- Reuse the one semantic icon contract across tabs, sections, and category/ranking entries. Missing icons use a stable host fallback; unknown names fail validation.

When a public boundary changes, deliver the complete chain: TypeScript contract and validator, exports, Flutter enum/decoder, host renderer, official template, affected real sources, focused tests, and the single relevant core specification section.

## Protected-source browser modes

- `transport: "webview"` runs the host-fixed same-origin `fetch` inside the visible or hidden WebView;
  browser Cookie, UA, redirect, and same-origin behavior remain host-owned.
- `transport: "html"` navigates the real WebView to the requested page and returns bounded current DOM HTML;
  it is for sources whose parser needs the rendered page rather than an HTTP response.
- `transport: "http"` lets the user complete any required real browser verification first, then the host reads
  its own Cookie/UA and performs the bounded request. Never extract, replay, or synthesize Cloudflare tokens.
- Windows and Android must implement all three transports with the same limits, origin checks, cancellation,
  challenge state, and manual-verification behavior. WebView controls may use only reviewed host input paths;
  no DOM click/value setter, arbitrary plugin script, CDP, global mouse/keyboard, or device control.
