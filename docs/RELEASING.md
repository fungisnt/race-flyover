# Releasing the installer

The installer is built by `.github/workflows/installer.yml`. To cut a release:

```bash
git tag v1.0.0
git push --tags
```

Or trigger the workflow manually from the Actions tab ("Build installer" → Run workflow);
that build only uploads the `.pkg` as a workflow artifact, without creating a release.

The workflow runs on `macos-latest`: it builds the screensaver with `./build.sh`,
packages it with `tools/build_installer.sh`, and attaches `build/RaceFlyover-<version>.pkg`
to the GitHub release for the tag.

## The installer is unsigned by default

Users who download it must **right-click the .pkg and choose Open** once to get past
Gatekeeper. To sign it instead, add these repository secrets and the workflow will
import the certificate and sign the pkg automatically:

- `MACOS_CERTIFICATE` — base64-encoded `.p12` of your *Developer ID Installer*
  certificate (`base64 -i cert.p12 | pbcopy`)
- `MACOS_CERTIFICATE_PASSWORD` — the `.p12` export password
- `MACOS_INSTALLER_IDENTITY` — e.g. `Developer ID Installer: Your Name (TEAMID)`

Note: pkg installers can't be notarized without a signing identity, so without a paid
Apple Developer ID the right-click step stays.

## Install location

The pkg installs system-wide into `/Library/Screen Savers`, so macOS asks for the
user's password during install. Per-user installs (`~/Library/Screen Savers`) aren't
something a `.pkg` does cleanly — for that, the zip produced by `./build.sh release`
remains the alternative (users double-click the `.saver` to install it).
