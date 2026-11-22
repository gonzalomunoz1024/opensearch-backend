# OpenSearch Lite image, compiled from the sources in this repository.
#
#   docker build -f lite/Dockerfile -t opensearch-lite:3.9.0 .
#
# Run it from the repository root. The build stage needs Maven Central, the Gradle
# plugin portal and services.gradle.org, or mirrors of them; nothing comes from GitHub,
# jitpack.io or opensearch.org. Allow about 8 GB of memory and 15 GB of disk.
#
# Build arguments:
#   BUILDER_IMAGE   a JDK 21+ image to compile with (default Temurin 25, as upstream bundles)
#   BASE_IMAGE      the runtime base (default Red Hat UBI 9 minimal); use your registry's copy
#   GRADLE_RETRIES  attempts per Gradle step, for flaky networks (default 2)
#   DIST            "build" (default) compiles here; "prebuilt" takes lite/build/opensearch-lite
#                   from the context, already made by lite/build.sh
#
# The image runs as UID 1000 in group 0 and works under any other UID in group 0, so
# OpenShift's restricted policy needs nothing extra: no root, no added capabilities, no
# sysctl. Only data/, logs/ and /tmp are written to; the rest can be read-only.

ARG BUILDER_IMAGE=eclipse-temurin:25-jdk
ARG BASE_IMAGE=redhat/ubi9-minimal:latest
ARG DIST=build

# --- compile everything -------------------------------------------------------------
FROM ${BUILDER_IMAGE} AS build
WORKDIR /src
COPY . .
ARG GRADLE_RETRIES=2
RUN LITE_GRADLE_RETRIES=${GRADLE_RETRIES} lite/build.sh

# --- or take a distribution lite/build.sh already made --------------------------------
FROM scratch AS prebuilt
COPY lite/build/opensearch-lite /src/lite/build/opensearch-lite

FROM ${DIST} AS dist

# --- the image ------------------------------------------------------------------------
FROM ${BASE_IMAGE}

ENV OPENSEARCH_HOME=/usr/share/opensearch \
    OPENSEARCH_JAVA_HOME=/usr/share/opensearch/jdk \
    OPENSEARCH_CONTAINER=true \
    PATH=/usr/share/opensearch/bin:$PATH
# Listen on every interface of the container (the tarball's default is localhost).
ENV network.host=0.0.0.0

COPY --from=dist --chown=1000:0 /src/lite/build/opensearch-lite /usr/share/opensearch
# Log to the console, as upstream's image does, instead of to files.
COPY --chown=1000:0 distribution/docker/src/docker/config/log4j2.properties /usr/share/opensearch/config/log4j2.properties
COPY lite/docker-entrypoint.sh /usr/local/bin/docker-entrypoint.sh

# As upstream's image: read settings from the environment (distribution type "docker"),
# trust the operating system's certificate authorities, and leave no setuid binaries.
RUN sed -i 's/^OPENSEARCH_DISTRIBUTION_TYPE=tar$/OPENSEARCH_DISTRIBUTION_TYPE=docker/' /usr/share/opensearch/bin/opensearch-env \
 && grep -q '^OPENSEARCH_DISTRIBUTION_TYPE=docker$' /usr/share/opensearch/bin/opensearch-env \
 && if [ -f /etc/pki/ca-trust/extracted/java/cacerts ]; then \
      ln -sf /etc/pki/ca-trust/extracted/java/cacerts /usr/share/opensearch/jdk/lib/security/cacerts; \
    fi \
 && find / -xdev -perm -4000 -exec chmod ug-s {} + \
 && chmod 0755 /usr/local/bin/docker-entrypoint.sh

WORKDIR /usr/share/opensearch
USER 1000:0
EXPOSE 9200 9300
VOLUME ["/usr/share/opensearch/data"]

LABEL org.opencontainers.image.title="opensearch-lite" \
      org.opencontainers.image.description="OpenSearch minimal distribution with Index Management and SQL, without the security plugin" \
      org.opencontainers.image.licenses="Apache-2.0"

ENTRYPOINT ["/usr/local/bin/docker-entrypoint.sh"]
