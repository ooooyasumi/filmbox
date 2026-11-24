# Filmbox Cloud Engine

This helper is an independent AGPL-3.0-only program derived from selected
OpenList cloud drivers. The native Filmbox application's licensing is not changed
by this file. Distribution and any combined-work licensing must be reviewed
against the actual integration; process separation is not a blanket exemption.

Upstream: https://github.com/OpenListTeam/OpenList

Exact revision: `e72822f5390f4272c9fe9da8cabba3c1a270182f`

Copyright: OpenList contributors and the respective upstream contributors.
The complete AGPL-3.0 license is included as `LICENSE`.

## Exact source retained

`upstream/OpenList/drivers/baidu_netdisk/{driver,meta,types,util}.go` and
`upstream/OpenList/drivers/quark_uc/{driver,meta,types,util}.go` are unmodified
copies at the revision above. The nested reference module prevents these original
files from being compiled as part of the extracted program.

## Filmbox modifications — 2026-10-31

* Extracted Baidu directory pagination, OAuth refresh, official download metadata,
  official dlink handling, and thumbnail response mapping into `providers/baidu.go`.
* Extracted Quark directory pagination, download link generation, authenticated
  request parameters, Cookie renewal and thumbnail mapping into `providers/quark.go`.
* Replaced OpenList model/database/Resty/retry dependencies with a small,
  standard-library-only transport. This helper needs Go 1.23+, not the full
  upstream module's later toolchain or unrelated storage drivers.
* Removed upload, delete, rename, transfer, transcoding/crack-download branches,
  Web management, account databases and credential files. Remote originals are
  read-only in this edition.
* Added authenticated loopback IPC, range-preserving media proxy, WebDAV support,
  session validation, error redaction, cancellation and bounded pagination.
* Credentials exist only in memory; updated credentials are returned over
  authenticated IPC for the native app to persist in macOS Keychain.

## Corresponding source

### Filmbox modifications — 2026-11-01 / helper 0.2.0

* Thumbnail resolution now fails explicitly with `thumbnail_unavailable` if the
  provider has no cover; it never resolves or streams the original as a fallback.
* Added authenticated media traffic sampling at `/v1/traffic`. It counts bytes
  actually read from provider response bodies, including Range/cancelled reads,
  once at the upstream hop. Repeated polling and loopback delivery add no bytes.
* Added regression checks for missing thumbnails and exact Range accounting.

### Filmbox modifications — 2026-11-01 / app 0.6.5

* Merge API, asset and redirect Set-Cookie responses within their valid API
  domain/path scope. Reject empty/deletion cookies and stale concurrent updates;
  cached links use the current session. Retry explicit authentication failure
  only once when that response actually renewed the credential.
* Limit account-expired classification to explicit authentication evidence;
  generic permission, capacity and individual-file failures remain separate.
* Add per-account credential revisions that increase across reconnects, and
  connection generations that reject superseded connect/error replies.
* Keep credentials in authenticated control JSON only. Asset error bodies never
  carry credentials, because the native client writes media bodies to temporary
  files. Added concurrent session, revision, cancellation and privacy checks.

`scripts/build-cloud-engine.sh` produces `filmbox-cloud-engine-source.tar.gz`
next to the helper. This contains all helper source, exact source originals,
license, tests and build script. There are no external Go module dependencies;
the Go standard library is the only runtime/build dependency. Distribute that
archive together with the binary and provide access from the app's About page.

Build from a complete source tree using `sh scripts/build-cloud-engine.sh`.

The helper is provided without warranty, as described in the included license.

### Filmbox packaging and recovery updates — 2026-11-16

The current source snapshot also includes typed recovery states for authentication,
permission, rate limits and provider failures, bounded automatic recovery, indexed
cloud preview metadata, and corresponding session/privacy regression tests added
through app 0.6.25 / Android 0.4.0. Client distribution now includes the whole
Filmbox source snapshot as well as this independent helper archive. Build receipts
record exact source commit, source tree and binary SHA-256. The original driver
files under `upstream/OpenList/` remain unmodified.
