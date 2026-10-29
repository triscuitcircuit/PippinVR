# Sparkle releases

Sparkle is linked and embedded. Configured GUI builds start it automatically; builds without a feed/key leave it inactive.

## One-time setup

1. Choose a permanent HTTPS URL for `appcast.xml` and public hosting for release downloads. A GitHub release alone is not an appcast.
2. From `pippinVR-Server`, run `.build/artifacts/sparkle/Sparkle/bin/generate_keys`. Keep the private key in Keychain with a secure backup; copy only the printed public key into build configuration.
3. Set `SPARKLE_FEED_URL` and `SPARKLE_PUBLIC_ED_KEY`. `build-app.sh` validates both and writes `SUFeedURL` / `SUPublicEDKey` before signing.
4. For distribution, use a Developer ID Application certificate and Apple notarization credentials. Sparkle's update-signing key is separate from Apple code signing.

See [Sparkle setup](https://sparkle-project.org/documentation/) for key management and hosting requirements.

## Each release

Run from `pippinVR-Server`, with the configuration above exported:

```sh
export VERSION=1.1.0 BUILD_NUMBER=101  # examples; always increase the build number
export CODESIGN_IDENTITY='Developer ID Application: YOUR NAME (TEAM ID)'
bash build_scripts/build-app.sh release
bash build_scripts/package-dmg.sh
.build/artifacts/sparkle/Sparkle/bin/generate_appcast \
  --download-url-prefix 'https://YOUR-HOST/updates/' dist
```

Configure notarization before packaging (`APPLE_API_KEY_PATH`, `APPLE_API_KEY_ID`, `APPLE_API_ISSUER_ID`, or the alternative credentials supported by `package-dmg.sh`). Keep only intended update archives in `dist`; generate the appcast **after** signing, notarization and stapling. Upload the final archives, generated feed, referenced release notes and any delta files to the matching URLs.

The signing script handles Sparkle's helpers inside out and preserves the downloader's entitlements, following [Sparkle's signing guidance](https://sparkle-project.org/documentation/sandboxing/). It does not generate or export private keys.

## GitHub Actions

- Repository variables: `SPARKLE_FEED_URL`, `SPARKLE_PUBLIC_ED_KEY` (applied only to `v*` tags).
- Existing Apple secrets: `MACOS_CERTIFICATE_P12`, `MACOS_CERTIFICATE_PASSWORD`, optional `MACOS_KEYCHAIN_PASSWORD`; `APPLE_API_KEY_P8`, `APPLE_API_KEY_ID`, `APPLE_API_ISSUER_ID`.
- Secret: `SPARKLE_PRIVATE_ED_KEY`, containing the exported Sparkle private key. It is passed through standard input only to `generate_appcast` on the Mac runner.
- Set `SPARKLE_FEED_URL` to `https://raw.githubusercontent.com/triscuitcircuit/PippinVR/main/updates/appcast.xml`.
- On `v*` tags, CI generates the appcast after notarization, uploads the DMG, then commits `updates/appcast.xml` to `main`. Only the generated feed goes into Git. Existing releases are retained, highest build first; delta updates are disabled.
- Tagged assets are not overwritten; CI verifies the uploaded archive matches the signed input before publishing the feed. Use a new version tag for a changed release.
- Push the workflow and helper scripts to `main` before tagging. Actions needs `contents: write`; branch rules must permit its feed commit. A rejected push leaves the previous feed in place; download the appcast artifact and publish it through a PR if direct bot pushes are prohibited.
- Tagged releases require the Apple signing and notarization secrets; branch builds may remain ad-hoc signed. Bundle verification derives the minimum macOS version from every packaged binary.

Before public use, install an older signed build in `/Applications` and update to a newer signed build through the test feed. Check download, signature verification, replacement and relaunch. Ad-hoc build checks cannot establish production notarization or end-to-end update success.
