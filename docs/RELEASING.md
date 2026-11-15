# Releasing Minutes

Pushing a tag like `v0.1.0` runs [`.github/workflows/release.yml`](../.github/workflows/release.yml). It builds the app, signs it with the Developer ID certificate, notarizes and staples the app and the DMG, writes the Sparkle appcast, publishes the GitHub release with notes from `CHANGELOG.md`, and updates the Homebrew cask.

Each secret below turns on one part. Without any of them, as in a fork, the workflow still publishes an ad-hoc signed DMG, with updates turned off.

| Secret | What it is | Turns on |
| --- | --- | --- |
| `DEVELOPER_ID_CERT_P12` | The Developer ID Application certificate and its private key, as a base64 `.p12` | Signing |
| `DEVELOPER_ID_CERT_PASSWORD` | The password the `.p12` was exported with | Signing |
| `APPLE_TEAM_ID` | The 10-character team ID in the certificate's name | Signing |
| `NOTARY_KEY_P8` | The App Store Connect API key, the whole `.p8` file | Notarization, with signing |
| `NOTARY_KEY_ID` | That key's ID | Notarization |
| `NOTARY_ISSUER_ID` | The issuer ID shown above the keys in App Store Connect | Notarization |
| `SPARKLE_ED_PRIVATE_KEY` | The private EdDSA key that signs updates, base64 | The appcast, and update checks in the app |
| `TAP_GITHUB_TOKEN` | A fine-grained token that can push to `RossLopez/homebrew-tap` | The cask update |

## Setting up, once

These steps make credentials, so the maintainer does them, not a script.

### 1. The Developer ID certificate

1. In [Certificates, Identifiers & Profiles](https://developer.apple.com/account/resources/certificates/list), add a certificate of type **Developer ID Application**, using a certificate signing request from Keychain Access (Keychain Access › Certificate Assistant › Request a Certificate From a Certificate Authority, saved to disk).
2. Download the certificate and open it, so it lands in your login keychain next to its private key.
3. In Keychain Access, select the certificate and its key, choose File › Export Items, and save a `.p12` with a strong password.
4. Add the secrets, then delete the `.p12`:

```bash
base64 -i DeveloperID.p12 | gh secret set DEVELOPER_ID_CERT_P12 --repo RossLopez/minutes
```

```bash
gh secret set DEVELOPER_ID_CERT_PASSWORD --repo RossLopez/minutes
```

```bash
gh secret set APPLE_TEAM_ID --repo RossLopez/minutes
```

`gh secret set` without a value asks for it, so it stays out of your shell history.

### 2. The notarization key

1. In [App Store Connect › Users and Access › Integrations › Team Keys](https://appstoreconnect.apple.com/access/integrations/api), generate a key with the **Developer** role.
2. Download the `.p8`. Apple lets you download it only once.
3. Add the secrets, then delete the `.p8`:

```bash
gh secret set NOTARY_KEY_P8 --repo RossLopez/minutes < AuthKey_XXXXXXXXXX.p8
```

```bash
gh secret set NOTARY_KEY_ID --repo RossLopez/minutes
```

```bash
gh secret set NOTARY_ISSUER_ID --repo RossLopez/minutes
```

### 3. The update signing key

Sparkle only installs an update signed with the private key whose public half is in the app. **Losing the private key means existing copies can never update again,** so keep a backup of it somewhere safe, such as a password manager.

1. Get Sparkle's tools. `scripts/make-appcast.sh` downloads and checks them, or by hand:

```bash
mkdir -p build/sparkle && curl -fsSL https://github.com/sparkle-project/Sparkle/releases/download/2.10.1/Sparkle-2.10.1.tar.xz | tar -xJ -C build/sparkle
```

2. Make the key pair. It's saved in your login keychain, and the public key is printed:

```bash
build/sparkle/bin/generate_keys
```

3. Put the public key in `Config/Release.xcconfig`, as `SPARKLE_PUBLIC_KEY = <key>`, and commit it. It's meant to be public.
4. Export the private key, add it as a secret, then delete the file:

```bash
build/sparkle/bin/generate_keys -x sparkle-private-key.txt
```

```bash
gh secret set SPARKLE_ED_PRIVATE_KEY --repo RossLopez/minutes < sparkle-private-key.txt
```

The workflow stops if this secret is set but `Config/Release.xcconfig` has no public key, because those copies could never check for updates.

### 4. The Homebrew tap

1. Create the public repository `RossLopez/homebrew-tap`, with an empty `Casks` folder and a README saying `brew install --cask rosslopez/tap/minutes`.
2. Make a [fine-grained personal access token](https://github.com/settings/personal-access-tokens/new) with access to **only** `RossLopez/homebrew-tap`, and the **Contents: Read and write** permission. Give it an expiry and a reminder to renew it.
3. Add it:

```bash
gh secret set TAP_GITHUB_TOKEN --repo RossLopez/minutes
```

On each release the workflow fills in [`packaging/homebrew/minutes.rb`](../packaging/homebrew/minutes.rb) with the version and the DMG's SHA-256, and pushes it to `Casks/minutes.rb`. The cask has no `auto_updates`, because Homebrew updates the app: Minutes turns its own update checks off when Homebrew installed it.

### 5. Private security reports

In the repository's **Settings › Code security**, turn on **Private vulnerability reporting**, which [SECURITY.md](../SECURITY.md) relies on.

## Making a release

1. In `CHANGELOG.md`, move what's under **Unreleased** into a new section, `## [0.2.0] - <date>`, and add its link at the bottom. The release notes and the update window show this section.
2. Set `MARKETING_VERSION` in `project.yml` to the same version. The release build takes its version from the tag, so this keeps Debug builds saying the same thing.
3. Merge to `main`, then tag the merge commit and push the tag:

```bash
git tag -a v0.2.0 -m "Minutes 0.2.0"
```

```bash
git push origin v0.2.0
```

4. Watch the run in the Actions tab. Most of the time goes to waiting for notarization.
5. Check the release has the DMG, its `.sha256` file and `appcast.xml`, and that `RossLopez/homebrew-tap` has a new commit.
6. Open the previous version and choose Minutes › Check for Updates… to see the update offered.

The build number is the number of commits on `main`, so it only goes up, which is what Sparkle compares.

### Pre-releases

A tag with a hyphen, like `v0.2.0-rc.1`, publishes a pre-release and leaves the cask alone. Its appcast doesn't reach anyone, because the app reads the appcast from the latest release, and GitHub never counts a pre-release as the latest. It's a safe way to try the signing and notarization steps.

### If a run fails

Nothing is published until the last steps, so fix the problem, delete the tag, and push it again:

```bash
git push --delete origin v0.2.0 && git tag -d v0.2.0
```

If the release was already created, delete it on GitHub first.

## Building a release on a Mac

`scripts/build-release.sh <version>` does what the workflow does, up to the DMG. With no signing variables set, the app is ad-hoc signed and nothing is notarized. The script's header lists its variables. For a signed build, the Developer ID identity has to be in your keychain:

```bash
DEVELOPER_ID_IDENTITY="Developer ID Application: Your Name (TEAMID)" APPLE_TEAM_ID=TEAMID scripts/build-release.sh 0.2.0
```

It needs `xcodegen` and `dmgbuild`. Install `dmgbuild` in a virtual environment, pinned with hashes:

```bash
python3 -m venv build/dmgbuild && build/dmgbuild/bin/pip install --require-hashes -r packaging/dmg/requirements.txt
```

```bash
DMGBUILD=build/dmgbuild/bin/dmgbuild scripts/build-release.sh 0.2.0
```

`packaging/dmg/background.png` and its `@2x` are drawn by `scripts/render-dmg-background.swift`. Run it again after changing the drawing.

### Testing updates without the real key

Never use the real key for tests. Make a throwaway pair in a scratch folder with `generate_keys --account minutes-test`, build two versions with `SPARKLE_PUBLIC_KEY=<test public key>`, sign the newer DMG with `make-appcast.sh` and a `DOWNLOAD_URL` on `localhost`, serve the folder, and point the older copy at that appcast by setting `SUFeedURL` in its defaults. Delete the test key from your keychain afterwards.

## Later: the official Homebrew cask

Once the repository meets Homebrew's [notability requirements](https://docs.brew.sh/Acceptable-Casks#rejected-casks), submit `minutes.rb` to `homebrew/cask`, then point the README there and archive the tap.
