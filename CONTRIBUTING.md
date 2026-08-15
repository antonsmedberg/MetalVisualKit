# Contributing to MetalVisualKit

Thanks for considering a contribution. MetalVisualKit is a small, pre-release
Swift package, so focused issues and pull requests are easier to review than broad
redesigns.

## Before you start

- Search the existing issues and pull requests before opening a duplicate.
- Bug fixes, tests and documentation corrections can go directly to a pull
  request. Discuss larger API or rendering changes in an issue first.
- Do not report security vulnerabilities in a public issue. Follow
  [SECURITY.md](SECURITY.md) instead.
- Participation is governed by the
  [Code of Conduct](CODE_OF_CONDUCT.md).

## Development setup

The tested setup is macOS with Xcode 26.6 and an installed iOS simulator. Older
compatible Xcode versions are not part of the current test matrix. SwiftLint and
XcodeGen are also needed for linting and project regeneration:

```sh
brew install swiftlint xcodegen
```

Clone your fork and open the committed workspace:

```sh
git clone <your-fork-url>
cd MetalVisualKit
xed Examples/MetalVisualKit.xcworkspace
```

Use the **MetalVisualKitDemo** scheme for the example app and SwiftUI previews.
The app consumes the package from the repository root; do not copy package
sources into the app target.

## Make a change

1. Create a focused branch from the latest `main`.
2. Keep public API changes source-compatible unless an issue explicitly agrees on
   a breaking change.
3. Add or update tests for behaviour changes.
4. Update documentation and `CHANGELOG.md` when user-visible behaviour changes.
5. Regenerate the Xcode project with `make project` after editing
   `Examples/MetalVisualKitDemo/project.yml`, and commit both the source and
   generated project changes.

When working on rendering code:

- keep mirrored Swift and Metal struct layouts in the same change;
- preserve exact progress endpoint and Reduce Motion behaviour;
- do not claim physical LiDAR, camera, orientation or performance validation
  without reproducible hardware evidence;
- keep procedural orbit opt-in so package gestures do not compete with host
  views;
- treat Swift 6 language mode as ongoing migration work. The package deliberately
  defaults to Swift 5 language mode under the Swift 6 toolchain.

## Verify locally

Run the checks relevant to your change. Before requesting review, the complete
local gate is:

```sh
make parity
make build
make test
make demo
make lint
make docs
make swift6
```

`make swift6` is advisory and operates on a disposable copy; it must not rewrite
the working `Package.swift`. GitHub Actions repeats the required checks on every
pull request.

Before committing, also confirm that `git status` contains no DerivedData,
`.xcresult`, `xcuserdata`, numbered conflict copies, generated media experiments
or credentials.

## Pull requests

A useful pull request:

- explains the problem and why the proposed change solves it;
- stays limited to one coherent concern;
- lists the exact commands and destinations used for verification;
- includes screenshots only when the visible UI changed;
- distinguishes simulator evidence from physical-device evidence;
- uses clear English and conventional commit subjects such as `fix:`, `feat:`,
  `test:`, `docs:` or `ci:`.

By submitting a contribution, you agree that it may be distributed under this
repository's [MIT License](LICENSE).
