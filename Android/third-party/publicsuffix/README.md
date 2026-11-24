# Public Suffix List source

OkHttp 4.12.0 contains `okhttp3/internal/publicsuffix/publicsuffixes.gz`. Its own NOTICE identifies the data as Mozilla Public License 2.0, independently of the OkHttp Apache 2.0 code license.

`rules.txt` is the preferred editable UTF-8 rule source reconstructed from the exact binary resource used in this release. Rules beginning with `!` are exceptions. Comments identify the origin and license. Rule bytes and exception bytes reconstruct the resource payload without changes, verified by `python3 scripts/check-public-suffix-source.py`. `source.json` records both compressed and decoded checksums and counts. The upstream current list may change, so this release uses its exact bundled data.

The MPL text and original NOTICE are included in the APK license page. This source directory is included in the full project source export available from settings.
