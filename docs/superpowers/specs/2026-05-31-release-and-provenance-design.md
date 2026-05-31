# Release pipeline & verifiable build provenance (design)

**Goal:** A tag-triggered GitHub Actions pipeline that builds, signs, notarizes,
and publishes a `.dmg` of Amazon Order Export — and emits **verifiable build
provenance** so anyone can prove a given binary was built from a specific source
commit by *this* workflow. No laptop is ever in the trust path.

**Architecture:** One release script (`scripts/build-amazon-order-export-dmg.sh`,
adapted from Scrapes' proven `build-kindleexporter-dmg.sh`) does
archive → Release-sign → DMG → notarize → staple. One workflow
(`.github/workflows/release.yml`) runs it on `push` of a `v*` tag, then layers on
the three provenance bits Scrapes lacks: a SLSA build-provenance **attestation**,
a published **SHA-256**, and a **commit SHA baked into the binary** and shown in
the About panel.

**Tech stack:** XcodeGen project, `xcodebuild archive` (Release), `codesign`
(Developer ID Application, team `9YKSA5B4FP`, `--options runtime --timestamp`),
`hdiutil` UDZO DMG, `notarytool submit --wait` + `stapler staple`,
`actions/attest-build-provenance`, `gh release`, `shasum`.

---

## Context & decisions

CI already lint+test+unsigned-builds on every push (`.github/workflows/ci.yml`,
`macos-26`, `CODE_SIGNING_ALLOWED=NO`). The release path is **separate** — it only
runs on tags and is the *only* place real certs and notary keys exist. The
sibling app Scrapes already has a working signed/notarized DMG pipeline
(`scripts/build-kindleexporter-dmg.sh` + `kindleexporter-release.yml`); we mirror
its shape and add provenance.

Decisions locked (design to these exactly):

- **Build/sign/notarize ONLY in GitHub Actions.** Tag-triggered (`push` of `v*`).
  A developer can run the script locally for debugging, but releases are
  CI-only — the laptop is never in the published trust path.
- **Release config correctness.** The Debug build carries
  `get-task-allow=true` (debugger attach), which notarization **rejects**. The
  Release archive must build with **hardened runtime enabled** and
  `get-task-allow` **dropped**. Sign with Developer ID Application (`9YKSA5B4FP`),
  `--options runtime --timestamp`, then `notarytool submit --wait` +
  `stapler staple`.
- **SLSA build provenance** via `actions/attest-build-provenance` — a Sigstore-
  signed attestation binding the `.dmg` digest to the exact commit + workflow +
  runner, verifiable with
  `gh attestation verify <dmg> --repo natikgadzhi/amazon-order-export`.
- **Publish the SHA-256** of the `.dmg` as a Release asset and in the notes.
- **Embed the git commit SHA at build time** and show it in the existing About
  panel as `Version X (build N) · abc1234`, where `abc1234` links to the commit.

### Honest reproducibility stance

macOS notarized bundles are **not bit-for-bit reproducible**. Code signing embeds
a secure timestamp, notarization returns a ticket whose contents we don't control,
and `stapler` writes that ticket into the DMG — so the same source produces
different bytes on every run. We therefore do **not** claim byte-reproducibility.
We target **verifiable provenance**: a signed attestation + a published hash + a
human-visible commit SHA, which together let anyone confirm *which commit* a
binary came from and that *this workflow* produced it. This distinction is stated
plainly in the user-facing verification doc.

---

## Components

### 1. `scripts/build-amazon-order-export-dmg.sh` (new — adapted from Scrapes)

A near-verbatim adaptation of `build-kindleexporter-dmg.sh`, retuned for this app.
Same structure, same env-var contract, same CI keychain/notary handling. Changed
knobs:

```
PROJECT_PATH=AmazonOrderExport.xcodeproj
SCHEME=AmazonOrderExport
CONFIGURATION=Release
APP_NAME="Amazon Order Export.app"          # spaced display name
DMG_BASENAME="Amazon Order Export"
```

Pipeline (identical phase order to Scrapes):

1. **`import_signing_certificate_if_needed`** — if `APPLE_DEVELOPER_ID_P12_BASE64`
   is set, decode the `.p12`, create a temp keychain, import the identity, set the
   partition list. Mirror Scrapes verbatim, including
   `install_apple_intermediates_if_needed` (downloads Apple's Developer ID
   intermediates so a fresh CI keychain passes chain validation) and the
   `resolve_app_sign_identity` quirk (skip `-v` / pass the temp keychain when
   running in CI).
2. **`archive_app`** — `xcodebuild archive` with `CODE_SIGNING_ALLOWED=NO`
   (archive unsigned; we sign the extracted `.app` ourselves), then `ditto` the
   `.app` out of the archive. **Must build Release** so the hardened-runtime /
   `get-task-allow` correctness below applies. Calls `xcodegen generate` first
   (or relies on the workflow's generate step) since the `.xcodeproj` is not
   committed.
3. **`sign_and_verify_app`** — `codesign --force --deep --options runtime
   --timestamp --sign "$APP_SIGN_IDENTITY"`, then `codesign --verify --deep
   --strict` and a non-fatal `spctl` check. `--options runtime` is what turns on
   hardened runtime at sign time.
4. **`build_dmg`** — stage the `.app` + an `/Applications` symlink, `hdiutil
   create -format UDZO`.
5. **`notarize_and_staple_dmg`** — `notarytool submit --wait` (API-key path via
   `APPLE_NOTARY_API_KEY_*`, keychain-profile path for local), then `stapler
   staple` + `stapler validate` + `spctl --type open`.

> **Reuse note:** the only material delta from Scrapes is the scheme/app-name
> constants and the explicit Release configuration. Keep the diff minimal so the
> two scripts stay obviously the same lineage and bug fixes port across.

### 2. Release config: hardened runtime ON, `get-task-allow` OFF (modified `project.yml`)

The Debug build sets `get-task-allow=true` to allow the debugger to attach; that
entitlement makes notarization fail. Two things must be true of the Release build:

- **Hardened runtime enabled.** Achieved at sign time by `--options runtime` in
  the script (above). Optionally also set `ENABLE_HARDENED_RUNTIME: YES` for the
  Release config in `project.yml` so an Xcode-driven Release build matches CI.
- **`get-task-allow` dropped.** With `GENERATE_INFOPLIST_FILE: YES` and no custom
  entitlements file, Xcode injects `com.apple.security.get-task-allow` only for
  Debug. Confirm this by archiving Release and inspecting
  `codesign -d --entitlements - "Amazon Order Export.app"` — it must **not** list
  `get-task-allow`. If a future change introduces a checked-in `.entitlements`
  file, it must define `get-task-allow` only in the Debug variant (or omit it),
  never in Release.

`project.yml` change: add a Release-specific `ENABLE_HARDENED_RUNTIME: YES` under
`configs`/`settings`, leaving the existing Manual / Developer ID / `9YKSA5B4FP`
signing settings untouched. (They already match the release identity, which is
why the dev Keychain item survives the upgrade to a notarized build — see
project.yml's signing comment.)

### 3. Build-time commit-SHA injection (new — `BuildInfo.swift`, generated)

The mechanism must work **both** locally (`git rev-parse --short HEAD`) **and** in
CI (`github.sha`), and must not require network or the `.git` dir at runtime.

**Approach: a generated Swift constant via an Xcode build phase.** A pre-build
"Run Script" phase writes `App/Generated/BuildInfo.swift` from the current SHA:

```swift
// Generated — do not edit. Written by the "Embed build info" pre-build phase.
enum BuildInfo {
  static let commitSHA = "abc1234"            // short SHA, 7 chars
  static let commitSHAFull = "abc1234…full…"  // full 40-char, for the URL
}
```

The script resolves the SHA with this precedence so it's correct everywhere:

```
SHA="${GITHUB_SHA:-$(git -C "$SRCROOT" rev-parse HEAD 2>/dev/null || echo unknown)}"
```

- In CI, GitHub sets `GITHUB_SHA` (the exact tagged commit) in the runner env, so
  the build phase picks it up with zero git calls.
- Locally, it falls back to `git rev-parse`. A dirty/unknown tree yields
  `"unknown"`, which the About panel renders as a plain "build from source" label
  with no commit link (so dev builds don't pretend to be provenanced).

Wiring in `project.yml` (XcodeGen) for the `AmazonOrderExport` target:

```yaml
preBuildScripts:
  - name: Embed build info
    script: ${PROJECT_DIR}/scripts/embed-build-info.sh
    outputFiles:
      - $(DERIVED_FILE_DIR)/BuildInfo.swift   # or App/Generated/BuildInfo.swift
    basedOnDependencyAnalysis: false           # always re-run; SHA can change without input changes
```

`App/Generated/BuildInfo.swift` is `.gitignore`d (it's a build product). The
script is a tiny new `scripts/embed-build-info.sh`. This is preferred over an
Info.plist-only key because it's strongly typed, available without `Bundle`
plumbing, and trivially testable. (An Info.plist key, e.g. `GitCommitSHA`, is an
acceptable *additional* surface if some external tool wants to read the SHA from
the bundle without launching it — out of scope unless needed.)

> **Why not derive the SHA from the attestation instead?** The attestation lives
> outside the bundle; we want the SHA *visible in the running app* so a user can
> eyeball it against the release tag without any tooling. The two are
> complementary: About shows it, the attestation proves it.

### 4. About panel: show the commit SHA + link (modified `App/About.swift`)

`App/About.swift` already builds a `credits` `NSAttributedString` and replaces the
stock About item (`AmazonOrderExportApp.swift`, `CommandGroup(replacing: .appInfo)`).
Add **one provenance line** to `credits()`, between the summary and the existing
"View source" / "Open an issue" links:

```
Version 0.1.0 (build 1) · abc1234
```

- **Version / build** come from the bundle:
  `Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString")` and
  `"CFBundleVersion"` (driven by `MARKETING_VERSION` / `CURRENT_PROJECT_VERSION`
  in `project.yml`).
- **`abc1234`** is `BuildInfo.commitSHA`, rendered as a link run (reuse the
  existing `linkRun(_:_:_:)` helper) to
  `https://github.com/natikgadzhi/amazon-order-export/commit/<commitSHAFull>`.
- When `BuildInfo.commitSHA == "unknown"` (local dirty build), render the line
  without a link, e.g. `Version 0.1.0 (build 1) · local build` — provenance is
  only claimed for real builds.

No new window or view — this is a few lines added to the existing `credits()`
function. The telemetry spec does **not** touch About; this line is owned here.

### 5. `.github/workflows/release.yml` (new — adapted from `kindleexporter-release.yml`)

Shape mirrors Scrapes' release workflow, plus the provenance steps. Trigger and
permissions:

```yaml
on:
  push:
    tags: ["v*"]
  workflow_dispatch:

permissions:
  contents: write        # create the GitHub Release + upload assets
  id-token: write        # OIDC token for the SLSA attestation signer
  attestations: write    # store the attestation
```

Job (`runs-on: macos-26` to match CI's Tahoe SDK; `latest-stable` Xcode), steps:

1. `actions/checkout@v4`.
2. `setup-xcode` (`latest-stable`); `brew install xcodegen`; `make generate`
   (the `.xcodeproj` isn't committed).
3. **Build the DMG** — run `scripts/build-amazon-order-export-dmg.sh` with the
   notary + cert secrets in `env` (same set as Scrapes, names below). `GITHUB_SHA`
   is already in the env, so the embed-build-info phase bakes the tagged commit.
4. **Resolve artifact path** — `find build/release -name '*.dmg'` → step output
   (mirror Scrapes' `Capture release artifact path`).
5. **Compute SHA-256** — `shasum -a 256 "$dmg" | tee "$dmg.sha256"` → a sidecar
   asset and a step output.
6. **Attest build provenance** —
   ```yaml
   - uses: actions/attest-build-provenance@v1
     with:
       subject-path: ${{ steps.artifact.outputs.dmg_path }}
   ```
   This produces a Sigstore-signed in-toto attestation binding the DMG digest to
   `github.sha`, the workflow ref, and the runner. Stored in the repo's
   attestations and (optionally) pushed as a `.sigstore` asset.
7. **Create the GitHub Release** — `softprops/action-gh-release` (or `gh release
   create`) attaching `*.dmg`, `*.dmg.sha256`, and the attestation bundle; notes
   include the SHA-256 and the "Verifying the build" pointer (the steps live in
   SECURITY.md — see boundary below).
8. *(Optional, parity with Scrapes)* upload to R2 for a stable download URL. Out
   of scope unless a public download page is wanted.

**Required repository secrets** (same contract as Scrapes' script):

| Secret | Purpose |
| --- | --- |
| `APPLE_DEVELOPER_ID_P12_BASE64` | base64 of the Developer ID Application `.p12` |
| `APPLE_DEVELOPER_ID_P12_PASSWORD` | password for that `.p12` |
| `APPLE_NOTARY_API_KEY_BASE64` | base64 of the App Store Connect notary `AuthKey_*.p8` |
| `APPLE_NOTARY_API_KEY_ID` | the notary key ID |
| `APPLE_NOTARY_ISSUER_ID` | the notary issuer ID |

The SLSA attestation needs **no secret** — it uses the workflow's OIDC identity
(`id-token: write`), which is exactly why it's trustworthy: the signer is GitHub's,
not ours.

---

## Provenance chain (the whole point)

```
source commit  ──tag push v*──▶  release.yml on macos-26 runner
   github.sha ─┐                    │
              ├─ embed-build-info ─▶ BuildInfo.commitSHA  ──▶  About panel
              │                      (baked into the binary)     "… · abc1234" → /commit/<sha>
              │
              └─ archive (Release) ─▶ sign (Dev ID, runtime, ts) ─▶ DMG
                                          │
                          ┌───────────────┴───────────────┐
                          ▼                                ▼
                 notarytool + staple              actions/attest-build-provenance
                 (Apple trusts the binary)        (signed: DMG digest ⇄ github.sha ⇄ workflow)
                          │                                │
                          ▼                                ▼
                 shasum -a 256 ───────────▶  GitHub Release: .dmg + .sha256 + attestation
```

Three independent things a verifier can check, no laptop trust required:

1. **`gh attestation verify <dmg>`** proves the DMG was produced by *this repo's*
   release workflow at *this commit* (cryptographic, via Sigstore + GitHub OIDC).
2. **`shasum -a 256 <dmg>`** matches the published hash (integrity of the exact
   download).
3. **The commit SHA in About** matches the release tag's commit (human-checkable,
   no tooling — the binary itself names its source).

Apple notarization is orthogonal: it proves Apple scanned and trusts the binary,
not *which commit* it came from. Our provenance covers the commit linkage Apple
doesn't.

---

## Data flow (release run)

```
git tag v0.1.0 && git push --tags
  └─ release.yml fires (GITHUB_SHA = tagged commit)
       make generate
       build-amazon-order-export-dmg.sh
         ├─ import cert + notary key (from secrets, temp keychain)
         ├─ embed-build-info.sh → BuildInfo.swift (GITHUB_SHA)
         ├─ xcodebuild archive (Release, unsigned) → ditto out .app
         ├─ codesign --options runtime --timestamp (hardened, no get-task-allow)
         ├─ hdiutil → "Amazon Order Export X.dmg"
         └─ notarytool submit --wait → stapler staple
       shasum -a 256 → .sha256 sidecar
       attest-build-provenance → signed attestation (OIDC)
       gh release create → .dmg + .sha256 + attestation, notes w/ hash
```

---

## Testing & verification

This pipeline can only be fully exercised by cutting a real tag, but de-risk it:

- **Pre-tag dry run** — `workflow_dispatch` on a branch builds + signs + notarizes
  + attests but skips `gh release create` (guard the release step on
  `startsWith(github.ref, 'refs/tags/')`, as Scrapes guards its R2 upload). Lets
  you watch a full signed/notarized/attested run without publishing.
- **Entitlement check (gate in the script)** — after signing, assert the binary
  has **no** `get-task-allow`:
  `codesign -d --entitlements - "$APP" 2>&1 | grep -q get-task-allow && { echo
  "get-task-allow present — Release misconfigured"; exit 1; }`. Fail loud rather
  than at notarization.
- **Notarization is its own gate** — `notarytool --wait` returns non-zero on
  rejection; `stapler validate` + `spctl --type open` confirm the stapled DMG
  passes Gatekeeper.
- **Provenance round-trip** — after a release, the live-verify checkpoint runs
  the three commands from SECURITY.md against the published `.dmg` and confirms
  the About-panel SHA equals the tag's commit.
- **BuildInfo unit-ish check** — a tiny test (or a `#Preview`) asserting the About
  line renders a link when `commitSHA != "unknown"` and a plain label otherwise.
- **Local sanity** — `scripts/build-amazon-order-export-dmg.sh` runs on a dev
  machine with a keychain-profile notary path (no base64 secrets), proving the
  script before trusting CI.

Per the project validation rhythm, capture a real notarization log + a real
`gh attestation verify` transcript during the first live release and keep them as
reference.

---

## Boundary with the telemetry/privacy spec

The **SECURITY.md / "Privacy & Security" doc structure is owned by the telemetry
spec** (`2026-05-31-telemetry-and-privacy-design.md`). This spec does **not**
define that doc. It **provides the "Verifying the build" content** that lands
inside SECURITY.md — the exact user-facing steps:

> **Verifying the build**
> 1. **Checksum.** `shasum -a 256 "Amazon Order Export.dmg"` and confirm it
>    matches the SHA-256 in the release notes / the `.sha256` asset.
> 2. **Provenance.** `gh attestation verify "Amazon Order Export.dmg" --repo
>    natikgadzhi/amazon-order-export` — confirms GitHub Actions built this exact
>    file from this repo. (Add `--source-ref refs/tags/vX.Y.Z` to pin the tag.)
> 3. **Commit.** Open the app → menu → About; the line reads
>    `Version X (build N) · abc1234`. Click `abc1234` (or compare it to the
>    release tag's commit on GitHub) — the running binary names its own source.
>
> Note: notarized macOS builds are **not** byte-reproducible (signing/notarization
> embed timestamps and tickets). We provide verifiable *provenance* — attestation,
> checksum, and a visible commit — not byte-for-byte reproducibility.

The **commit-SHA display in About is owned here** (it's a build-time-injection
provenance feature). The telemetry spec won't modify About.

---

## File structure

**Create**
- `scripts/build-amazon-order-export-dmg.sh` — adapted from Scrapes'
  `build-kindleexporter-dmg.sh` (scheme/app-name retuned, Release-explicit,
  post-sign `get-task-allow` assertion).
- `scripts/embed-build-info.sh` — writes `BuildInfo.swift` from
  `GITHUB_SHA`/`git rev-parse`.
- `.github/workflows/release.yml` — tag-triggered build + notarize + attest +
  release.

**Modify**
- `App/About.swift` — add the `Version X (build N) · <sha>` line (linked when the
  SHA is real) to `credits()`.
- `project.yml` — add the `preBuildScripts` "Embed build info" phase; add
  `ENABLE_HARDENED_RUNTIME: YES` to the Release config; keep existing Manual /
  Developer ID / `9YKSA5B4FP` signing.
- `.gitignore` — ignore `App/Generated/BuildInfo.swift`.
- `README.md` — link to the "Verifying the build" steps (which live in
  SECURITY.md).

**Not created here**
- `SECURITY.md` — owned by the telemetry spec; this spec supplies its "Verifying
  the build" section content only.

---

## Out of scope

- **The CI workflow** (`ci.yml`) — unchanged; release is a separate workflow.
- **R2 / public download page** — Scrapes uploads to R2; optional here, deferred
  until there's a public landing page.
- **Byte-for-byte reproducible builds** — explicitly not a goal (see the
  reproducibility stance); we'd need to strip signing/notarization, which defeats
  Gatekeeper. Provenance instead.
- **Sparkle / auto-update, version bumping automation, changelog generation.**
- **Multi-arch / universal concerns beyond what the default archive yields.**
- **SECURITY.md structure, telemetry, and Sentry** — telemetry spec.

## Resolved decisions

- **Apple secrets: reuse Scrapes'.** Same team `9YKSA5B4FP`, same Developer ID
  cert + notary key. Set the same five secret names on this repo —
  `APPLE_DEVELOPER_ID_P12_BASE64`, `APPLE_DEVELOPER_ID_P12_PASSWORD`,
  `APPLE_NOTARY_API_KEY_BASE64`, `APPLE_NOTARY_API_KEY_ID`, `APPLE_NOTARY_ISSUER_ID`.
- **"build N" = CI run number.** The release workflow passes
  `CURRENT_PROJECT_VERSION=${{ github.run_number }}` to `xcodebuild` (and to the
  embed-build-info phase), so About's "(build N)" auto-increments per release run.
  `project.yml` keeps `"1"` as the local-dev default.
- **R2 / public download: deferred.** GitHub Release assets only for now; R2 is a
  follow-up when there's a public landing page.
- **`.sigstore` asset: skip.** Rely on GitHub's stored attestations (which
  `gh attestation verify` fetches automatically). Less complexity, same guarantee.
