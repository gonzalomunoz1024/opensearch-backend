# OpenSearch Lite

OpenSearch 3.9.0 cut down to what InfraDashboard
([opensearch-frontend](https://github.com/gonzalomunoz1024/opensearch-frontend)) needs,
compiled from the sources in this repository into **one container image**:

```bash
docker build -f lite/Dockerfile -t opensearch-lite:3.9.0 .
```

Everything outside `lite/`, `.dockerignore` and `.github/workflows/lite.yml` is upstream
OpenSearch at tag `3.9.0` (commit `4ee42a94e87f66fbf1e62a9871b1b87f91e02472`), unchanged.
Upstream's own GitHub workflows are removed, since they are for upstream's project.

## What is in it

| Part | What it gives you |
| --- | --- |
| OpenSearch core and its 24 built-in modules | Indexing, search, aggregations, ingest pipelines, scripting (Painless), reindex, snapshots |
| Job Scheduler plugin | Runs the Index Management jobs |
| Index Management plugin | Index policies (ISM), rollups, transforms, snapshot management |
| SQL plugin | SQL and PPL queries (`/_plugins/_sql`, `/_plugins/_ppl`) |
| A Java runtime linked for exactly this set | Nothing to install; 80 MB instead of the full JDK's 250 MB |

The image is about 320 MB to pull and 460 MB unpacked, of which 110 MB is the base image.

**Not in it:** the security plugin, and the other plugins of the upstream release:
alerting, anomaly detection, asynchronous search, cross-cluster replication, custom
codecs, flow framework, geospatial, k-NN, learning to rank, ML Commons, neural search,
notifications (and its core), observability, performance analyzer, query insights,
reports, search relevance, security analytics, skills, system templates, user behavior
insights. Index Management can send a notification when a policy step fails; without
the notifications plugin its policy editor says it could not load notification channels,
and everything else works.

A native single executable (GraalVM native-image) is not possible for OpenSearch: it loads
modules and plugins through their own class loaders at start, uses reflection throughout
and a Java agent, and upstream does not support it. One image that carries its own Java
runtime is the closest practical thing.

## No security

Nothing in Lite checks who is calling.

- **No login.** Any client that reaches port 9200 can read, change and delete every index
  and every cluster setting.
- **No TLS.** Port 9200 (REST) and port 9300 (node to node) are plain text.
- **No roles, tenants, document- or field-level security, no audit log.**

The network is the only boundary. The Helm chart creates a NetworkPolicy that admits only
InfraDashboard's pods to port 9200 and only OpenSearch Lite's own pods to port 9300. Do
not give port 9200 a Route or an Ingress.

## Build

```bash
docker build -f lite/Dockerfile -t opensearch-lite:3.9.0 .
```

The build compiles the core and the three plugins with Gradle, so it needs, besides the
two base images, **Maven Central**, the **Gradle plugin portal** and
**services.gradle.org** (one Gradle download). Nothing comes from GitHub, jitpack.io or
opensearch.org. Allow 8 GB of memory, 15 GB of disk and 30 to 60 minutes.

| Build argument | Default | For |
| --- | --- | --- |
| `BUILDER_IMAGE` | `eclipse-temurin:25-jdk` | Any JDK 21 or newer; 25 is what upstream ships |
| `BASE_IMAGE` | `redhat/ubi9-minimal:latest` | The runtime base; use your registry's copy |
| `GRADLE_RETRIES` | `2` | Attempts per Gradle step, for a network that drops downloads |
| `DIST` | `build` | `prebuilt` takes `lite/build/opensearch-lite` made by `lite/build.sh` beforehand |

`lite/build.sh` is what the Dockerfile runs. Run it yourself (with `JAVA_HOME` set) to get
`lite/build/opensearch-lite-3.9.0-linux-x64.tar.gz`: the same distribution as one file,
for a machine without containers. Unpack it and run `bin/opensearch`.

What the build does differently from upstream's, and why:

- **Plugins come from `lite/plugins/`**, copies of the upstream plugin sources at their
  3.9.0.0 tags, so the build needs this repository only. `lite/plugins/README.md` lists
  the sources and the few build-file changes.
- **`lite/gradle/maven_central_only.init.gradle`** removes `ci.opensearch.org` and
  `jitpack.io` from every repository list. Upstream lists them first, and Gradle fails on
  a blocked host instead of trying the next one.
- **`lite/analytics-api` and `lite/okhttp-aws-signer`** build two small libraries the SQL
  plugin needs and that upstream fetches from those two hosts.
- **The Java runtime is linked with `jlink`** from the builder's JDK instead of being
  downloaded: `jdeps` finds the modules the jars use, `lite/jdk-modules.txt` adds the ones
  it cannot see.

## Run

```bash
docker run -p 9200:9200 -e OPENSEARCH_JAVA_OPTS="-Xms1g -Xmx1g" opensearch-lite:3.9.0
curl http://localhost:9200/
```

One node, no login. The image behaves like the official one where it matters:

- **Settings are environment variables** with their dotted names, for example
  `-e cluster.name=logs -e indices.query.bool.max_clause_count=4096`. A setting can also
  follow the image name as `-E name=value`, or mount your own
  `/usr/share/opensearch/config/opensearch.yml`.
- **Logs go to the console** as JSON lines.
- **Any user ID works** as long as it is in group 0, which is how OpenShift runs
  containers. No root, no capabilities, no `sysctl`.
- **Only three places are written to:** `/usr/share/opensearch/data` (the indexes; mount
  a volume), `/usr/share/opensearch/logs` (the JVM's garbage collection log) and `/tmp`.
  The rest can be read-only.

The defaults in `lite/config/opensearch.yml` are for one node: `discovery.type:
single-node` and no replicas for new indexes (one node has nowhere to put them).

## Helm chart

`lite/helm/opensearch-lite` installs it on Kubernetes or OpenShift without any elevated
rights: it fits OpenShift's `restricted-v2` policy and the Kubernetes "restricted" pod
security standard.

```bash
helm install opensearch-lite lite/helm/opensearch-lite \
  --set image.repository=<your registry>/opensearch-lite
```

It creates a StatefulSet with a 20 GiB volume per node, the Service `opensearch-lite`
(port 9200; InfraDashboard's chart points at `http://opensearch-lite:9200` by default), a
headless Service for the nodes, and the NetworkPolicy. `values.yaml` explains every value;
the ones you are most likely to set:

| Value | Default | |
| --- | --- | --- |
| `replicas` | `1` | 3 or more makes a cluster that survives the loss of a node |
| `heap` | `1g` | Keep it at half of `resources.limits.memory` (default 2 GiB) |
| `persistence.size` | `20Gi` | Per node |
| `settings` | `{}` | Any OpenSearch setting, as `name: value` |
| `networkPolicy.allowFrom` | InfraDashboard's pods | Who else may reach port 9200 |

**Several nodes without an administrator.** OpenSearch normally memory-maps its index
files and then refuses to form a cluster unless the worker nodes have
`vm.max_map_count` raised, which takes cluster-admin rights. With more than one replica
the chart turns memory-mapping off (`node.store.allow_mmap: false`) so that nothing has to
be changed on the workers; searches on large indexes are somewhat slower for it. If your
administrators confirm the limit is 262144 or more, set `allowMmap: true`. A cluster also
needs 65535 open files per container, which OpenShift gives by default.

## Tests

| Script | What it checks |
| --- | --- |
| `lite/smoke_test.sh [image]` | One node, run as OpenShift would (random UID, no capabilities, read-only root): the calls InfraDashboard, Index Management and SQL rely on |
| `lite/smoke_test.sh --cluster [image]` | Three nodes with the chart's cluster settings: they join, replicate, and carry on when one stops |
| `lite/helm_test.sh [image]` | The chart on the cluster `kubectl` points at, under the restricted policy: start, queries, the NetworkPolicy, a deleted pod coming back. `REPLICAS=3` for a cluster |

`.github/workflows/lite.yml` builds the image and runs all of them on every push and pull
request (the chart test on a throwaway `kind` cluster). On the default branch and on
`lite-*` tags it also pushes the image, and the chart if you name a Helm repository, to
Artifactory, once these are set under Settings > Secrets and variables > Actions:

| | Name | Example |
| --- | --- | --- |
| Variable | `ARTIFACTORY_REGISTRY` | `artifactory.example.com` |
| Variable | `ARTIFACTORY_IMAGE` | `docker-local/opensearch-lite` |
| Variable | `ARTIFACTORY_HELM_REPO` (optional) | `helm-local` |
| Variable | `BASE_IMAGE` (optional) | `artifactory.example.com/docker-remote/redhat/ubi9-minimal:latest` |
| Variable | `RUNNER` (optional) | `self-hosted` |
| Secret | `ARTIFACTORY_USER`, `ARTIFACTORY_TOKEN` | |

Without them the workflow builds and tests, and pushes nothing.

## Moving to a new OpenSearch version

1. Merge the new upstream tag into this repository.
2. Replace each folder under `lite/plugins/` with the plugin's source at the matching tag
   and apply the changes listed in `lite/plugins/README.md` again.
3. Build, and run the three tests. If a class turns out to be missing at run time, the
   Java runtime lacks a module: add it to `lite/jdk-modules.txt`.
