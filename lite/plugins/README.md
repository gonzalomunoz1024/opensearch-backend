# Plugin sources

The plugins OpenSearch Lite keeps, copied from their upstream repositories at the tags
the OpenSearch 3.9.0 release uses (opensearch-build `manifests/3.9.0/opensearch-3.9.0.yml`).
They are here so the image builds from this repository alone, without GitHub.

| Folder | Upstream | Tag | Commit |
| --- | --- | --- | --- |
| common-utils | https://github.com/opensearch-project/common-utils | 3.9.0.0 | 70f1d37a577d5cc462efc54ca8c929e8c4b052c1 |
| job-scheduler | https://github.com/opensearch-project/job-scheduler | 3.9.0.0 | f69a7050f3010ff55e9bc9c344310a76bc746b97 |
| index-management | https://github.com/opensearch-project/index-management | 3.9.0.0 | 2b735eecc454377f4da3bc21aa73bfa80667d1da |
| sql | https://github.com/opensearch-project/sql | 3.9.0.0 | 6bada7629b20aa21b56b08454a7edbc375cd4029 |

## Changes from upstream

Only what the build needs to run without ci.opensearch.org and jitpack.io; no code changes.

- `job-scheduler`: the `sample-extension-plugin` folder is removed, and its `include` in
  `settings.gradle`. It is an example plugin, and its build script downloads from
  ci.opensearch.org while Gradle configures the build.
- `sql`: the `integ-test` and `doctest` folders are removed, and their `include` in
  `settings.gradle`; they download test clusters from ci.opensearch.org.
- `sql/core/build.gradle`: compiles against `analytics-api` 3.9.0-SNAPSHOT (built by
  `lite/analytics-api`) instead of 3.8.0-SNAPSHOT, the version the plugin itself bundles.

Editor and assistant settings the upstream repositories carry (`.idea/`, `.claude/`,
`CLAUDE.md`) are not copied: this repository's `.gitignore` leaves them out, and the build
does not read them.

To update to a new release, replace each folder with `git archive` of the new tag and
apply the changes above again.
