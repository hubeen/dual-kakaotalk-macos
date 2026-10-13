# Dual KakaoTalk for macOS

[한국어](README.md) | [English](README.en.md)

Creates a separate `/Applications/KakaoTalkWork.app` from the official `/Applications/KakaoTalk.app`, allowing personal and Dual KakaoTalk accounts to run side by side. The dual app appears as `Dual KakaoTalk` in the Dock and app switcher, its app icon background is changed locally to green (`#32C67A`), and its menu-bar icons to green (`#5B8A72`).

> [!WARNING]
> This limited beta is intended only for the repository owner and acquaintances who trust the downloaded folder. It uses ad-hoc signing, an administrator prompt, and undocumented private macOS CoreUI APIs. It is not a notarized general-public installer. Verify the ZIP SHA-256 shown on the GitHub Release before running it. Apple or KakaoTalk updates may break it. Intel macOS 13 and Apple M3 macOS 26.5.2 have been physically verified.

## Screenshots

The personal and dual apps running side by side:

![Personal and Dual KakaoTalk running together](Docs/Images/dual-kakaotalk-running.png)

The dual app uses green menu-bar icons:

![Personal and dual menu-bar icons](Docs/Images/menu-bar-icons.png)

The Dock distinguishes the apps by their localized names:

| Personal KakaoTalk | Dual KakaoTalk |
| --- | --- |
| ![KakaoTalk Dock label](Docs/Images/dock-personal.png) | ![Dual KakaoTalk Dock label](Docs/Images/dock-dual.png) |

## Requirements

- macOS Ventura 13 or newer
- Official KakaoTalk at `/Applications/KakaoTalk.app`
- Minimum accepted KakaoTalk: 26.6.1. There is no exact version pin, but compatibility with every future release is not guaranteed.
- End users do not need Xcode.

## Install or update

1. Install or update official KakaoTalk at `/Applications/KakaoTalk.app`.
2. On first install only, download and extract the ZIP from the [latest Release](https://github.com/hubeen/dual-kakaotalk-macos/releases/latest). Later updates reuse the same folder.
3. Quit both personal and Dual KakaoTalk applications.
4. Right-click `Install.command`, then select **Open → Open**.
5. Approve the macOS administrator prompt using your password or Touch ID.
6. After installation, both applications open:
   - Personal KakaoTalk: `/Applications/KakaoTalk.app`
   - Dual KakaoTalk: `/Applications/KakaoTalkWork.app`

After updating official KakaoTalk, quit both applications and run `Install.command` from **the folder you already have**. A version-number change alone does not require a new installer, but internal structural changes may require a new release. The same command handles fresh installs and updates, and the existing Dual KakaoTalk app is backed up before replacement and restored if installation fails.

An unverified `Assets.car` fingerprint skips only the green **menu-bar** icon step; the remaining installation steps continue. Changes to the app's internal structure can still break installation or launch.

This revision was installed and signature-verified on Intel macOS 13 with KakaoTalk 26.8.0 (2000), and both login screens appeared simultaneously. The user confirmed a green Dock icon; the captured `Command-Tab` icons remained yellow. Login, message sending/receiving, and physical Apple Silicon validation of this revision have not been performed. The screenshots above and existing M3 validation records describe earlier revisions.

## Uninstall

1. Quit Dual KakaoTalk.
2. Right-click `Uninstall.command` in the release folder, then select **Open → Open**.
3. Approve the macOS administrator prompt.

The uninstaller removes only `/Applications/KakaoTalkWork.app`. It preserves official `/Applications/KakaoTalk.app`, account/chat data, Keychain, and installer logs under `~/Library/Logs/DualKakaoTalk/`. It succeeds harmlessly when Dual KakaoTalk is already absent, and refuses deletion if the fixed path is a symbolic link or has an unexpected bundle identifier.

## What the installer does

- Validates the official app's fixed path, bundle ID, minimum version, Kakao Team ID, and signature.
- Copies, recolors, ad-hoc signs, and verifies the staged app without administrator privileges.
- Recolors the app icon background using public AppKit without requiring a catalog fingerprint.
- Compares version/build, executable hash, catalog hash, and icon file/declaration before skipping an unchanged installation.
- Recolors the menu-bar icons only when the `Assets.car` fingerprint matches, and skips just that step otherwise.
- Uses administrator privileges only to import a fixed-format, digest-bound request.
- Uses an exclusive lock and write-ahead recovery journal for concurrent or interrupted installations.
- Shows a dedicated macOS progress bar and step description during installation and removal.
- Assigns the fixed Dual KakaoTalk identity:
  - Name and executable: `KakaoTalkWork`
  - Bundle ID: `com.kakao.KakaoTalkWorkMac`
- Opens personal and Dual KakaoTalk after installation.

The installer does not access or modify:

- KakaoTalk account or chat data
- Keychain
- Dock pins or Dock preferences
- Background monitoring services

## Error logs and issue reporting

The five newest logs of each type are retained under:

```text
~/Library/Logs/DualKakaoTalk/
```

The directory uses mode `0700`, and log files use mode `0600`. `install-*.log` records the installer version, helper details, KakaoTalk details, and installation result. `uninstall-*.log` records the uninstaller version, target bundle ID, removal result, and whether user data was preserved. Both contain `diagnostic.*` fields for UTC timestamp, macOS version/build, CPU architecture, result, failure phase, exit code, and failure line, with user-home and temporary paths automatically replaced. On failure, each command reveals its log and asks before opening its dedicated GitHub issue form. Logs are never uploaded automatically. Review the log, then use **Structured installation log** for installation failures or **Structured uninstallation log** for removal failures.

## Build and test from source

Contributors need macOS 13+, Xcode/Swift, and Intel and Apple Silicon SDK support.

```sh
swift test
./Scripts/verify-no-kakao-assets.sh
./Scripts/build-release.sh
```

The release contains a Universal x86_64 and arm64 helper. `Assets.car` mutation is restricted to an exact allowlisted fingerprint and 16 menu-icon renditions. See [Docs/FEASIBILITY.en.md](Docs/FEASIBILITY.en.md) and [Docs/INDEPENDENT-WRITER.en.md](Docs/INDEPENDENT-WRITER.en.md) for private-API risks and the independent-writer migration plan.

## Limitations

- Official app updates are not copied automatically; run `Install.command` again. The same installer folder can be reused while the app's internal structure remains compatible.
- Green menu-bar icons apply only on a verified `Assets.car` fingerprint. The Dock and `Command-Tab` may display different icons.
- Ad-hoc signing may trigger macOS security warnings.
- Installation still fails closed if the bundle identity or the Kakao signature does not check out.
- M1 through M5 use the same arm64 Universal build, so there is no chip-specific implementation. M3/macOS 26.5.2 is physically verified; the remaining chip and macOS combinations require physical-device validation.
- This trusted-circle beta is not a notarized installer for general redistribution.

## Non-affiliation and rights

This project is not affiliated with, endorsed by, or sponsored by Kakao Corp. KakaoTalk names, trademarks, icons, and application assets belong to their respective owners. The MIT license applies only to independently written project source code.

The repository and releases do not contain or redistribute Kakao executables, app bundles, original icons, `Assets.car`, or derived Kakao image pixels. `Docs/Images` contains only privacy-sanitized, tightly cropped runtime screenshots needed to demonstrate behavior. Menu-bar icon transformations are performed locally from the official app installed on the user's Mac.
