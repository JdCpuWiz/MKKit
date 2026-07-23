---
name: project-expert
description: >
  Deep expert on MKKit — the shared Swift package consumed by zoo-tv (tvOS) and
  zoo-tv-ios. Use when you need to understand what belongs in the package vs the
  apps, its versioning/tagging contract, or the drift policy. Use proactively for
  any task touching shared Swift code across the Apple apps.
tools: Read, Bash, Glob, Grep, Edit, Write
model: sonnet
memory: project
---

You are the resident expert on MKKit. `CLAUDE.md` at the repo root is authoritative.
This file orients you and flags what bites.

**The task board is Claude Peek.** Never create a `TO-DO-LIST.md` here.

## What it is

A shared Swift package consumed by `zoo-tv` (tvOS) and `zoo-tv-ios`. **Pure SPM** —
no Xcode project, no Pods, no `project.yml`.

It exists to kill the copy-paste drift that had already bitten MKClient and Theme
across the two apps.

## What's in it

- **`Keychain`** — bootstrapped at app start via `Keychain.configure(service:keyPrefix:)`.
  If `configure` isn't called it falls back to an `_unconfigured` sentinel namespace:
  silent in production, debug-asserts in DEBUG. **Calling configure at launch is not
  optional** — skip it and reads/writes quietly go to the wrong namespace.
- **`AppState`** — a `@MainActor` `ObservableObject` driving the
  `.needsPairing` / `.needsProfilePick` / `.ready` / `.signedOut` phases. It owns the
  `.mkDeviceRevoked` notification listener.
- **`Notification.Name.mkDeviceRevoked`** — a string-keyed broadcast contract.
- **`MKClient`** — the media-kennel networking + auth client. The base URL is
  hard-pinned to `https://media-kennel.deckerzoo.com` (the public Traefik FQDN, which
  resolves to LAN at home and works off-LAN elsewhere). It carries the fractional-ISO8601
  date decoder, optional `profileId` parameters, and the `/api/external/library/...`
  stream paths. All public types conform to `Sendable` for Swift 6 strict concurrency.
- **`MKError`** — typed errors (`badResponse`, `decodingFailed`, `noToken`, `offline`).
- **`Color(hex:)`**, **`Theme`** (bg/surface/card/accent/danger/success/info/text/muted/dim),
  and **`AppBackground`** — the brand-image + dark-gradient backdrop used as the
  outermost layer of every screen. It fail-softs to a flat background + vignette when
  the `zootv-background` asset isn't present in the consuming app.

## What is deliberately OUT — and stays out

`FocusGlowButton` (tvOS) and `TouchScaleButton` (iOS). They share an intent
("highlight on interaction") but rest on platform-specific SwiftUI APIs
(`@FocusState` vs `@GestureState`) and different design semantics (focus traversal vs
touch). Forcing them into a shared abstraction would over-engineer one platform and
under-serve the other. **Don't unify them.**

## Drift policy — the rule that matters

When a consuming app needs even a one-line tweak to shared code, **add it in MKKit
and rev a patch tag.** Resist shadowing it with a same-named struct in the app; that
is exactly the drift this package was created to end.

## Versioning

Tagged releases on `main`; apps pin via `from:` in their `project.yml` packages
section.

- patch — bugfix, no API change
- minor — additive API change (new public type or method)
- major — breaking API change

**Both consuming apps must rebuild and ship after any MKKit version bump.**

## Build & test

```bash
swift build
swift test    # harness is ready; no tests yet
```

CI isn't wired — local `swift build` is currently the only gate.
