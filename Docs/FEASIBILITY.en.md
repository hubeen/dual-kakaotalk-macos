# Feasibility and CoreUI Decision
[한국어](FEASIBILITY.md) | [English](FEASIBILITY.en.md)

Status: **EXPERIMENTAL BETA — PRIVATE API, FINGERPRINT-GATED**

## Verified baseline

The Intel verification machine runs macOS 13.7.8 (22H730). Its official KakaoTalk 26.8.0 (2000) has bundle identifier `com.kakao.KakaoTalkMac`, Team ID `L75WVXX68A`, a valid strict deep signature, and a Universal x86_64/arm64 executable. Exact non-asset compatibility facts are recorded in `compatibility.json`.

The Dock icon is rebuilt locally from the bundle's `.icns` through public AppKit and `/usr/bin/iconutil`, then replaced only in the staged copy. It does not require a catalog fingerprint, but future icon structures are not guaranteed to work. This revision was installed on Intel macOS 13 with KakaoTalk 26.8.0 (2000), and both login screens appeared simultaneously. The user confirmed a green Dock icon; the captured `Command-Tab` icons remained yellow, with the cause undetermined. Login, message sending/receiving, and physical Apple Silicon validation of this revision have not been performed. Green menu-bar states reside in `Contents/Resources/Assets.car`; there is no public writer API, so only verified fingerprints are processed.

## Current implementation

The project owner explicitly accepted the private-API risk. The beta therefore uses a small Objective-C bridge to undocumented CoreUI classes. It:

- accepts only an exact allowlisted source-catalog SHA-256;
- addresses only eight named menu icons at 1x and 2x;
- checks expected dimensions and link structure before mutation;
- patches a staged copy, never the official app;
- validates the resulting catalog and requires its hash to change;
- signs and verifies the completed staged app before replacement;
- rolls back the prior `KakaoTalkWork.app` on failure.

The bridge declarations are independently implemented from observed runtime selectors and MIT-licensed CoreUI header information. No third-party implementation, Kakao executable, or Kakao asset bytes are vendored.

## Residual risk

CoreUI is private and may change in any macOS update. Catalog internals may change in any KakaoTalk update. Ad-hoc signing can trigger security prompts. Earlier Universal releases were physically verified on Intel macOS 13.7.8 and Apple M3 macOS 26.5.2; this revision requires separate physical validation. An unknown catalog skips only menu-icon recoloring; failures in bundle structure, identity, or signature validation still stop installation.

## Follow-up

A separately tracked goal researches an independent writer for only the required `Assets.car` subset. It must preserve non-target records byte-for-byte where possible, provide round-trip and corruption tests, and replace the private bridge only after parity is demonstrated. Until then, the private bridge remains clearly labeled experimental.
