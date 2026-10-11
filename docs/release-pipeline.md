# Release pipeline

Every tag `v*` builds Conductore once and ships it to the closed channels:
Google Play internal testing, TestFlight internal testers and a GitHub
prerelease with the sideload APKs. Wider audiences are a manual click
(Promote workflow); production and App Store review wait for your approval.

## Workflows

| Workflow | Trigger | What it does |
|---|---|---|
| `ci.yml` | push to `main`, every PR, manual | `flutter analyze`, `flutter test --concurrency=2`, host companion `node --test`, `tools/bundle-companion.sh --check`, a debug APK (play flavor), an unsigned iOS release build on macOS, and Linux / Windows / macOS desktop bundles (docs/desktop.md). |
| `release.yml` | tag `v*`, or manual | Runs the CI checks, then **Android**: signed AAB (play flavor) to Play `internal`; signed split APKs (full flavor) + `SHA256SUMS` on a GitHub prerelease; both checked by `tools/verify-release-build.py` against stale app code. **iOS**: signed IPA uploaded to TestFlight. **Desktop**: Linux, Windows and unsigned macOS bundles attached to the same prerelease (docs/desktop.md). |
| `promote.yml` | manual only | Play: internal → alpha (closed) → beta (open) → production, with staged rollout. iOS: TestFlight external group, or submit for App Store review. |

A platform whose secrets are missing is skipped with a notice (`Android
release skipped`, `iOS release skipped`, `Play upload skipped`) instead of
failing, so the pipeline runs before everything is set up. The AAB and IPA
are always kept as run artifacts for 30 days.

Store traffic goes through fastlane (`fastlane/Fastfile`, pinned by
`Gemfile.lock`). Upload alone would work with marketplace actions, but
promotion would not: fastlane moves builds between Play tracks, changes
rollouts, hands builds to TestFlight groups and submits for review, with one
tool on both stores. Flutter still does the building.

## Version numbers

- **Version name** comes from the tag: `v0.1.0-conductore.9` gives
  `0.1.0-conductore.9` on Android and `0.1.0` on iOS. The App Store only
  accepts `X.Y.Z`. Once a `0.1.0` is live on the App Store, raise the base
  version (`v0.1.1-conductore.10`) for the next build.
- **Build number** is `BUILD_NUMBER_OFFSET` (repository variable, default
  100) plus the workflow run number, so it always grows. It is the Play
  versionCode, the iOS build number, and the number the Promote workflow
  asks for. Each run's summary shows it.
- The sideload APKs keep the `build × 10 + ABI` versionCode scheme, so
  `1012` and up install over the hand-built previews (`462`).
- The manual run accepts a version and a build number override. It refuses
  build numbers at or below the one in `pubspec.yaml`.

## Smoke test before tagging

Before pushing a tag, run the phone smoke test on development-central:

```sh
tools/smoke-test.sh            # about 3 to 4 minutes; exit 0 means pass
```

It boots a headless Android emulator (Pixel 7 profile, 411 dp wide like a
phone), starts a throwaway machine in Docker and drives the debug app
through the main flows with `integration_test/smoke_test.dart`:

1. add the machine (password login, trust its host key);
2. home in Open mode, then Projects mode;
3. search (no match, then a match);
4. open an agent: its Herdr workspace in a terminal tab;
5. Chat View with the transcript and the waiting permission;
6. approve the permission;
7. switch to the other Herdr workspace (both are labelled "shop");
8. answer the question its agent asks;
9. Settings › Security.

Each step saves a screenshot (`01-home-empty.png` … `15-settings-security.png`)
to `build/smoke/<time>/` and to
`/root/conductore-inbox/out/smoke/<time>/`; attach them to the release
message. A broken flow, any Flutter error and any RenderFlex overflow fail
the run, with a `NN-FAILED.png` of the screen it stopped on and the logs
(`drive.log`, `logcat.txt`, `hostd.log`, `machine.log`) in the same folder.

The throwaway machine (`tools/smoke/machine`) is an Alpine container on a
private Docker network with no host mounts: sshd (user and password
`smoke`), the Herdr binary of this host, and the companion from this
checkout's `host/`. Two fake Claude Code agents (`fake-claude.sh`) send
real hook events through `conductore-hook`: one waits for approval of
`npm test`, the other asks "Which database?". The emulator reaches it
only through `10.0.2.2` and a port bound to `127.0.0.1`; it never sees
this server's own sshd or anyone's sessions.

On exit, whatever the result, the script removes the emulator, the
container, its network and image, the AVD's disk images and the debug
APK. What stays: the emulator package and the Android 34 system image in
the SDK (about 5 GB), and the AVD definition in
`~/.cache/conductore-smoke` (kilobytes). The first run installs and
creates both under the build lock.

Notes:

- The app runs on Skia (`--no-enable-impeller`): this emulator's software
  renderer crashes the whole emulator under Impeller's GLES backend.
- The emulator has no screen lock, so the test takes the app lock's
  "Continue without auth".
- `SMOKE_DEVICE=emulator-5554` reuses a running emulator, and
  `SMOKE_SHARE_DIR=` skips the copy, for working on the test itself.
- CI: GitHub's hosted Linux runners have no KVM by default, so this is
  not a CI job. It could become one on a larger runner with KVM enabled,
  or on a self-hosted runner.

## Cutting a release

```sh
tools/smoke-test.sh            # see "Smoke test before tagging"
# optional: release notes for the GitHub prerelease
$EDITOR docs/release-notes/v0.1.0-conductore.9.md
git add docs/release-notes && git commit -m "docs: notes for preview 9"
git tag v0.1.0-conductore.9
git push origin main v0.1.0-conductore.9
```

Without a notes file the prerelease gets GitHub's generated notes. Push the
single tag rather than `git push --tags`, which also pushes any stale local
tag. TestFlight shows the build after Apple processes it, usually 10 to 30
minutes. Internal testers get it automatically.

## Promoting

Actions → **Promote** → Run workflow. `build_number` is the one from the
Release run summary.

| Goal | Inputs |
|---|---|
| Play closed testing | platform `android`, from `internal`, to `alpha` |
| Play open testing | from `alpha`, to `beta` |
| Play production, 20% | from `beta`, to `production`, rollout `0.2` |
| Finish the rollout | from `production`, to `production`, rollout `1` |
| TestFlight external | platform `ios`, action `testflight-external`, ios_version `0.1.0`, ios_group `Beta` |
| App Store review | platform `ios`, action `app-store-review`, ios_version `0.1.0` |

Production and App Store review run in the `production` environment and wait
until a required reviewer approves them in the run page. After Apple
approves a version it stays unreleased until you press Release in App Store
Connect.

## One-time setup

### GitHub

1. Add the secrets below under Settings → Secrets and variables → Actions.
2. Settings → Environments → New environment `production`. Add yourself as
   required reviewer and turn off "Allow administrators to bypass".
3. Optional repository variables:

| Variable | Default | Use |
|---|---|---|
| `BUILD_NUMBER_OFFSET` | `100` | Added to the run number. Raise it to jump ahead. |
| `PLAY_RELEASE_STATUS` | `completed` | Set `draft` until the Play app has had its first rollout. |
| `PLAY_PACKAGE_NAME` | `com.outsmartis.conductore` | Play package. |
| `IOS_BUNDLE_ID` | `com.outsmartis.conductore` | iOS bundle id. Also the default in `ios/Flutter/AppIdentity.xcconfig`. |

### Secrets

| Secret | Value | How to produce it |
|---|---|---|
| `ANDROID_KEYSTORE_BASE64` | The keystore that signs the current previews | `base64 -w0 android-release.jks \| gh secret set ANDROID_KEYSTORE_BASE64` |
| `ANDROID_KEYSTORE_PASSWORD` | Its store password | `gh secret set ANDROID_KEYSTORE_PASSWORD` (prompts) |
| `ANDROID_KEY_ALIAS` | Its key alias | `gh secret set ANDROID_KEY_ALIAS` |
| `ANDROID_KEY_PASSWORD` | Its key password | `gh secret set ANDROID_KEY_PASSWORD` |
| `PLAY_SERVICE_ACCOUNT_JSON` | The service account JSON key file, whole | `gh secret set PLAY_SERVICE_ACCOUNT_JSON < play-key.json` |
| `ASC_KEY_ID` | App Store Connect API key ID | Shown next to the key |
| `ASC_ISSUER_ID` | Issuer ID | Shown above the key list |
| `ASC_KEY_P8_BASE64` | The `.p8` file | `base64 -w0 AuthKey_ABC123.p8 \| gh secret set ASC_KEY_P8_BASE64` |
| `APPLE_TEAM_ID` | 10-character team ID | developer.apple.com → Membership details |
| `IOS_DIST_CERT_P12_BASE64` | Optional: Apple Distribution certificate + key | See "iOS signing" below |
| `IOS_DIST_CERT_PASSWORD` | Optional: the `.p12` password | |

Use the same Android keystore as the previews. Sideloaded copies only update
from APKs signed with the key that installed them.

### Google Play Console

1. **Create app**: name Conductore, app, free. The package name is fixed by
   the first upload: `com.outsmartis.conductore`.
2. **App signing**: on the first release Play asks for the app signing key.
   Recommended: "Use existing app signing key" and upload the preview
   keystore with Google's PEPK tool (the Console shows the exact command).
   Play-installed and sideloaded copies then share one signature and can
   update each other. The same keystore stays the upload key. If you let
   Google generate the key instead, uninstall the sideloaded copy before
   installing from Play.
3. **First upload by hand**: Play's API cannot create the first release.
   Run Release (manual run, publish on, or a tag) before
   `PLAY_SERVICE_ACCOUNT_JSON` exists, download the `android-…` artifact,
   and in Testing → Internal testing → Create new release upload
   `conductore-v…-play.aab`. Add testers (email list) and roll it out. While
   the app has never been rolled out, set `PLAY_RELEASE_STATUS=draft`.
4. **Service account**: in Google Cloud Console (any project) enable the
   *Google Play Android Developer API*, create a service account and a JSON
   key. In Play Console → Users and permissions → Invite new user, enter the
   service account email, grant the Conductore app "Release apps to testing
   tracks", "Manage testing tracks and edit tester lists" and "Release to
   production, exclude devices, and use Play App Signing". Invite.
5. **App content**: privacy policy URL (below), ads: none, Data safety: no
   data collected or shared, content rating questionnaire, target audience
   18+, and the foreground service declaration (`dataSync`: keeps the
   user's SSH sessions connected in the background).
6. **Closed and open testing**: create the tester lists for the `alpha`
   (closed) and `beta` (open) tracks before promoting to them. A personal
   (not organization) developer account needs 12 closed testers for 14
   days before production access.

### Apple

1. **App ID**: developer.apple.com → Identifiers → + → App IDs → explicit
   bundle id `com.outsmartis.conductore`. Enable **NFC Tag Reading** (the
   app signs SSH logins with hardware keys over NFC and ships that
   entitlement).
2. **App record**: App Store Connect → Apps → + → New App, iOS, name
   Conductore (pick another if the name is taken), the bundle id above, SKU
   `conductore`.
3. **API key**: Users and Access → Integrations → App Store Connect API →
   Team Keys → +. Use **Admin** access if you rely on automatic (cloud)
   signing, which needs it to use Apple's cloud distribution certificate.
   **App Manager** is enough with the distribution certificate secret; if
   profile creation then fails with a permission error, switch to Admin.
   Download the `.p8` (only once) and note the key ID and issuer ID.
4. **TestFlight internal group**: TestFlight → Internal Testing → +, e.g.
   "Outsmartis", add the testers (they must be App Store Connect users) and
   enable automatic distribution, so each processed build reaches them.
5. **Export compliance**: Conductore encrypts traffic (SSH), so each new
   build shows "Missing Compliance" until you answer the encryption
   questions in App Store Connect. After answering once, you can add the
   matching `ITSAppUsesNonExemptEncryption` key to `ios/Runner/Info.plist`
   to skip the question for later builds. The answer is a legal call, so
   the pipeline does not make it for you.
6. **Before external testing**: fill TestFlight → Test Information (beta
   description, feedback email, contact). The first build per version goes
   through Beta App Review.
7. **Before App Store review**: fill the listing (description, keywords,
   screenshots, support URL), the privacy policy URL, App Privacy ("Data
   Not Collected") and the age rating. No lane uploads metadata.

### iOS signing

The `ios beta` lane signs in one of two ways:

- **Distribution certificate (recommended, predictable)**: set
  `IOS_DIST_CERT_P12_BASE64` and `IOS_DIST_CERT_PASSWORD`. The lane imports
  the certificate into a temporary keychain, creates or reuses an App Store
  profile through the API key, and signs manually. Create the certificate
  without a Mac:

  ```sh
  openssl genrsa -out dist.key 2048
  openssl req -new -key dist.key -out dist.csr -subj "/CN=Outsmartis Distribution/emailAddress=<apple-id-email>"
  # developer.apple.com → Certificates → + → Apple Distribution → upload dist.csr → download distribution.cer
  openssl x509 -inform der -in distribution.cer -out dist.pem
  openssl pkcs12 -export -legacy -inkey dist.key -in dist.pem -out dist.p12   # sets the password
  base64 -w0 dist.p12 | gh secret set IOS_DIST_CERT_P12_BASE64
  gh secret set IOS_DIST_CERT_PASSWORD
  ```

  Keep `dist.key` and `dist.p12` in the team vault and delete the loose
  copies. `-legacy` matters: the macOS keychain cannot import OpenSSL 3's
  default `.p12` encryption.
- **Automatic (cloud) signing**: leave both unset. `xcodebuild
  -allowProvisioningUpdates` with the API key registers what is missing
  and signs with Apple's cloud-managed certificate. It needs an Admin key.

### No scripts in the app bundle

App Store Connect rejects an IPA that contains any script, meaning a file
that starts with `#!`, with "Invalid Signature. Code object is not signed at
all". It does so even when the file is not executable, because it checks the
content. The host companion is full of such scripts, so it ships as one
archive, `assets/companion/companion.tar.gz`, next to `manifest.json`.
`tools/bundle-companion.sh` builds both from `host/`, and its `--check` mode
in CI fails on any loose script or executable under `assets/companion/`. A
widget test also fails when any bundled asset starts with `#!`. Ship any new
script asset the same way, inside an archive.

## Privacy policy URL

Both stores need a public privacy policy. `docs/privacy-policy.md` is
written for that. Two ways to publish it:

- **Now, no setup**: link the file on GitHub,
  `https://github.com/andreconde21/conductore-mobile/blob/main/docs/privacy-policy.md`.
- **Cleaner page**: Settings → Pages → Source "Deploy from a branch",
  branch `main`, folder `/docs`. The policy is then at
  `https://andreconde21.github.io/conductore-mobile/privacy-policy`. Pages
  has one source per repository: `website.yml` deploys upstream's website
  through Actions and only runs on pushes to `master`, so switching the source to
  `/docs` loses nothing today.

## Check on the first runs

- **CI iOS job**: the first macOS build has never run for this fork. If
  Flutter generates an `ios/Podfile` for plugins without Swift Package
  Manager support (for example `flutter_pty`), that is expected; the file
  is gitignored.
- **Release, Android**: the `Refuse stale app code` step, the prerelease
  asset names, and the Play upload (the first one may need
  `PLAY_RELEASE_STATUS=draft`).
- **Release, iOS**: signing. Most first-run failures are App ID
  capabilities (NFC), the API key role, or an expired certificate. The
  upload step prints Apple's exact error.
- **TestFlight**: the build appears under Missing Compliance until the
  encryption questions are answered.
