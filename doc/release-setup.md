# Official desktop releases

The public `foxwisefz/bowser` repository owns **Build desktop release**.
Website and API deployment is maintained separately in the private services
repository. Community source builds do not require the official release secrets.

## Release environment

Configure the `release` environment to allow only branch `main`. It contains:

- `APPLE_CERTIFICATE_BASE64`: exported Developer ID certificate and private key as a base64-encoded password-protected `.p12`.
- `APPLE_CERTIFICATE_PASSWORD`: that export's password.
- `APPLE_SIGN_IDENTITY`: Developer ID Application identity.
- `APPLE_ID`, `APPLE_TEAM_ID`, `APPLE_APP_SPECIFIC_PASSWORD`: notarization account details.
- `BOWSER_UPDATE_PRIVATE_KEY_BASE64`: the existing 32-byte Ed25519 update-signing key, base64 encoded.
- `R2_ACCOUNT_ID`, `R2_ACCESS_KEY_ID`, `R2_SECRET_ACCESS_KEY`: credentials for the existing download bucket.

The optional `R2_BUCKET` environment variable defaults to `bowser`. Keep the
existing signing key: installed browsers trust its public key. Do not regenerate
it as part of repository changes. Tailscale and server-deployment credentials
belong only in the private services repository.

## Publish

In Actions, select **Build desktop release**, then **Run workflow** on `main`.
The workflow derives a version and build identity from the current UTC date and
source commit, verifies release contracts, builds the application and runtime,
signs and notarizes the app and DMG, and signs the update manifest.

The publish job uploads to the existing `assets.bowser.app` R2 feed, verifying
artifact integrity and promoting the signed manifest last. This publishes a
customer update even though the separate GitHub Release record is a draft.
Run it when the current browser code is ready to ship. No private API source is
required for the build.

See [distribution](distribution.md) for updater verification and packaging.

To validate signing, notarization and packaging without publishing a customer
update, uncheck **publish** when running the workflow. The signed artifacts are
still retained in the workflow run; no GitHub release or R2 upload is created.
