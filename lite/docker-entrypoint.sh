#!/usr/bin/env bash
#
# Entry point of the OpenSearch Lite image.
#
#   settings as arguments:    docker run opensearch-lite:3.9.0 -Ecluster.name=logs
#   settings as environment:  docker run -e cluster.name=logs opensearch-lite:3.9.0
#   another command:          docker run opensearch-lite:3.9.0 opensearch-plugin list
#
# Environment variables that look like settings (lowercase, with a dot) are turned
# into settings by bin/opensearch-env, as in the official image.

set -e

# Files OpenSearch creates stay group-writable, so a pod that comes back under a
# different UID in group 0 can still use its volume.
umask 0002

# The official image's default command; accepted so charts written for it still work.
if [[ "${1:-}" == "opensearchwrapper" ]]; then
  shift
fi

# Anything that is not an option is a command to run instead of OpenSearch.
if [[ $# -gt 0 && "${1:0:1}" != "-" ]]; then
  exec "$@"
fi

# A setting given as an argument wins over the same setting in the environment
# (OpenSearch refuses to start when a setting is given twice).
drop=()
for arg in "$@"; do
  if [[ "$arg" == -E*=* ]]; then
    key="${arg#-E}"
    drop+=(-u "${key%%=*}")
  fi
done

exec env "${drop[@]}" /usr/share/opensearch/bin/opensearch "$@"
