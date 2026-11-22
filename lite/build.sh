#!/usr/bin/env bash
#
# Builds OpenSearch Lite from the sources in this repository:
#
#   lite/build/opensearch-lite/                               the distribution, Java runtime inside
#   lite/build/opensearch-lite-<version>-linux-<arch>.tar.gz  the same, as one file
#
# lite/Dockerfile runs this script in its build stage, so `docker build -f lite/Dockerfile .`
# is all a pipeline needs. Run it directly to get the tarball without Docker.
#
# Steps:
#   1. compile the OpenSearch minimal distribution (core + modules, no plugins, so no
#      security plugin) and publish the core libraries to a private Maven folder;
#   2. compile the plugins kept in Lite from lite/plugins against those libraries:
#      common-utils (a library), job-scheduler, index-management and sql;
#   3. unpack the distribution and install the plugins into it;
#   4. link a trimmed Java runtime with jlink into the distribution's jdk/ folder;
#   5. add lite/config/opensearch.yml, create the keystore, pack the tarball.
#
# Needs: a JDK 21 or newer in JAVA_HOME (25 recommended, the version upstream bundles),
# and network access to Maven Central, the Gradle plugin portal and services.gradle.org
# (one Gradle download), or your mirrors of them. Nothing is downloaded from GitHub,
# jitpack.io or opensearch.org.
#
# Environment:
#   LITE_GRADLE_RETRIES   attempts per Gradle step (default 1); raise it on flaky networks
#   LITE_SKIP_CORE=1      reuse step 1 from an earlier run
#   LITE_SKIP_PLUGINS=1   reuse step 2 from an earlier run
#
# Usage: lite/build.sh

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LITE="$ROOT/lite"
OUT="$LITE/build"
M2="$OUT/m2"
DIST="$OUT/opensearch-lite"
RETRIES="${LITE_GRADLE_RETRIES:-1}"

case "${1:-}" in
  -h|--help) sed -n '2,30p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
  "") ;;
  *) echo "unknown option: $1" >&2; exit 2 ;;
esac

: "${JAVA_HOME:?set JAVA_HOME to a JDK 21 or newer}"
export JAVA_HOME
export RUNTIME_JAVA_HOME="${RUNTIME_JAVA_HOME:-$JAVA_HOME}"
# Gradle and the JDK tools must not pick up options meant for a running OpenSearch.
unset OPENSEARCH_JAVA_HOME OPENSEARCH_JAVA_OPTS OPENSEARCH_PATH_CONF

VERSION="$(sed -n 's/^opensearch *= *//p' "$ROOT/buildSrc/version.properties")"
PLUGIN_VERSION="$VERSION.0"
case "$(uname -m)" in
  x86_64|amd64) ARCH=x64; CORE_ARCHIVE=no-jdk-linux-tar ;;
  aarch64|arm64) ARCH=arm64; CORE_ARCHIVE=no-jdk-linux-arm64-tar ;;
  *) echo "unsupported architecture: $(uname -m)" >&2; exit 1 ;;
esac

# Every Gradle build: release versions, no tests, Maven Central only (see the init
# script), and the private Maven folder instead of ~/.m2. One Gradle version, the
# core's, builds everything, so only one Gradle distribution is downloaded; some
# plugins turn Gradle's deprecation warnings into errors for the older Gradle they
# pin, hence --warning-mode.
GRADLE_ARGS=(
  --no-daemon
  --warning-mode=summary
  -I "$LITE/gradle/maven_central_only.init.gradle"
  -Dbuild.snapshot=false
  -Dopensearch.version="$VERSION"
  -Dmaven.repo.local="$M2"
  -Djapicmp.compare.version=3.8.0
  -x test -x javadoc
)

gradle_in() {
  local dir="$1"; shift
  local attempt=1
  until "$ROOT/gradlew" -p "$dir" "${GRADLE_ARGS[@]}" "$@"; do
    if (( attempt >= RETRIES )); then return 1; fi
    attempt=$((attempt + 1))
    echo "    retrying ($attempt of $RETRIES)"
    sleep 20
  done
}

echo "==> OpenSearch Lite $VERSION ($ARCH)"
mkdir -p "$OUT"

if [[ "${LITE_SKIP_CORE:-}" != 1 ]]; then
  echo "==> 1. core: minimal distribution and core libraries"
  core_tasks=(
    ":distribution:archives:$CORE_ARCHIVE:assemble"
    :build-tools:publishToMavenLocal
    :server:publishToMavenLocal
    :test:framework:publishToMavenLocal
    :client:rest:publishToMavenLocal
    :client:sniffer:publishToMavenLocal
    :client:rest-high-level:publishToMavenLocal
    :rest-api-spec:publishToMavenLocal
    :modules:lang-painless:spi:publishToMavenLocal
  )
  for lib in "$ROOT"/libs/*/build.gradle; do
    core_tasks+=(":libs:opensearch-$(basename "$(dirname "$lib")"):publishToMavenLocal")
  done
  gradle_in "$ROOT" "${core_tasks[@]}"

  # Two libraries the SQL plugin needs that upstream publishes only to repositories
  # Lite does not use; each folder's build.gradle says why.
  gradle_in "$LITE/analytics-api" publishToMavenLocal
  gradle_in "$LITE/okhttp-aws-signer" publishToMavenLocal
fi

P="$LITE/plugins"
if [[ "${LITE_SKIP_PLUGINS:-}" != 1 ]]; then
  echo "==> 2. plugins"
  gradle_in "$P/common-utils" publishToMavenLocal
  gradle_in "$P/job-scheduler" assemble publishToMavenLocal
  gradle_in "$P/index-management" assemble
  gradle_in "$P/sql" :opensearch-sql-plugin:assemble
fi

# Installed in this order: the other two extend job-scheduler.
PLUGIN_ZIPS=(
  "$P/job-scheduler/build/distributions/opensearch-job-scheduler-$PLUGIN_VERSION.zip"
  "$P/index-management/build/distributions/opensearch-index-management-$PLUGIN_VERSION.zip"
  "$P/sql/plugin/build/distributions/opensearch-sql-$PLUGIN_VERSION.zip"
)

echo "==> 3. assembling the distribution"
TARBALL="$ROOT/distribution/archives/$CORE_ARCHIVE/build/distributions/opensearch-min-$VERSION-no-jdk-linux-$ARCH.tar.gz"
rm -rf "$DIST" "$OUT/opensearch-$VERSION"
tar -xzf "$TARBALL" -C "$OUT"
mv "$OUT/opensearch-$VERSION" "$DIST"
# The distribution gets its own Java runtime in step 4; say so, as upstream's bundled-JDK
# archives do (otherwise every start warns that no JDK is bundled).
sed -i 's/^OPENSEARCH_BUNDLED_JDK=false$/OPENSEARCH_BUNDLED_JDK=true/' "$DIST/bin/opensearch-env"
for zip in "${PLUGIN_ZIPS[@]}"; do
  echo "    installing $(basename "$zip")"
  OPENSEARCH_JAVA_HOME="$JAVA_HOME" "$DIST/bin/opensearch-plugin" install --batch "file://$zip" >/dev/null
done
if compgen -G "$DIST/plugins/*security*" >/dev/null; then
  echo "the security plugin must not be in Lite" >&2
  exit 1
fi
ls "$DIST/plugins" | sed 's/^/    plugin: /'

echo "==> 4. linking the Java runtime"
# jdeps reads the classes of every jar and names the JDK modules they use. The jars are
# unpacked first and their module descriptors dropped: given a modular jar, jdeps tries
# to resolve that jar's own dependencies instead, and fails. lite/jdk-modules.txt adds
# the modules jdeps cannot see. Do not trim jdeps' list by hand: it names only the top
# of each dependency chain (jdk.jconsole stands in for java.desktop, whose java.beans
# classes Log4j needs to start).
FEATURE="$("$JAVA_HOME/bin/java" -XshowSettings:properties -version 2>&1 | awk '/java.specification.version/ {print $3}')"
SCAN="$OUT/jdeps-scan"
rm -rf "$SCAN" && mkdir -p "$SCAN"
count=0
while IFS= read -r -d '' jar; do
  count=$((count + 1))
  mkdir "$SCAN/$count"
  if command -v unzip >/dev/null; then
    unzip -qo "$jar" -d "$SCAN/$count"
  else
    (cd "$SCAN/$count" && "$JAVA_HOME/bin/jar" xf "$jar")
  fi
done < <(find "$DIST/lib" "$DIST/modules" "$DIST/plugins" -name '*.jar' -print0)
find "$SCAN" -name module-info.class -delete
# Classes for a newer Java than the one linking cannot be read, and would not be used.
for versioned in "$SCAN"/*/META-INF/versions/*; do
  [[ -d "$versioned" ]] || continue
  if (( $(basename "$versioned") > FEATURE )); then rm -rf "$versioned"; fi
done
FOUND="$("$JAVA_HOME/bin/jdeps" --ignore-missing-deps --print-module-deps "$SCAN"/* \
  | grep -E '^[a-z][a-z0-9.]*(,[a-z][a-z0-9.]*)*$')"
rm -rf "$SCAN"
echo "    jdeps over $count jars: $FOUND"
MODULES="$( { grep -v '^#' "$LITE/jdk-modules.txt"; echo "$FOUND"; } \
  | tr ',' '\n' | tr -d ' \r' | grep -v '^$' | sort -u | paste -sd, -)"
echo "    linking: $MODULES"
"$JAVA_HOME/bin/jlink" \
  --add-modules "$MODULES" \
  --strip-debug --no-header-files --no-man-pages --compress zip-6 \
  --output "$DIST/jdk"
"$DIST/jdk/bin/java" -version 2>&1 | grep -v '^Picked up' | sed 's/^/    /'

echo "==> 5. configuration, keystore and tarball"
cp "$LITE/config/opensearch.yml" "$DIST/config/opensearch.yml"
cp "$LITE/README.md" "$DIST/LITE.md"
mkdir -p "$DIST/data" "$DIST/logs"
# OpenSearch creates its keystore on first start if there is none, which needs a
# writable config folder. Creating it here lets the image run with a read-only root
# filesystem. It holds no secrets, only the seed OpenSearch generates for itself.
OPENSEARCH_JAVA_HOME="$DIST/jdk" "$DIST/bin/opensearch-keystore" create >/dev/null
# Group gets what the owner has: OpenShift runs the container as a random UID in group 0.
chmod -R g=u "$DIST"

NAME="opensearch-lite-$VERSION"
rm -rf "${OUT:?}/$NAME" && cp -a "$DIST" "$OUT/$NAME"
tar -C "$OUT" -czf "$OUT/$NAME-linux-$ARCH.tar.gz" "$NAME"
rm -rf "${OUT:?}/$NAME"
echo "    $OUT/$NAME-linux-$ARCH.tar.gz ($(du -h "$OUT/$NAME-linux-$ARCH.tar.gz" | cut -f1))"
echo "==> done"
