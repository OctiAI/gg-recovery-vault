#!/usr/bin/env bash
set -Eeuo pipefail

title='GoalsGraph backup collector failure'
existing="$(gh issue list --state open --search "is:issue in:title ${title}" --json number --jq '.[0].number // empty')"
if [ -n "${existing}" ]; then
  gh issue close "${existing}" --comment "A verified encrypted backup collection succeeded: ${GITHUB_SERVER_URL}/${GITHUB_REPOSITORY}/actions/runs/${GITHUB_RUN_ID}"
fi
