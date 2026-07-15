#!/usr/bin/env bash
set -Eeuo pipefail

title='GoalsGraph backup collector failure'
existing="$(gh issue list --state open --search "is:issue in:title ${title}" --json number --jq '.[0].number // empty')"
if [ -z "${existing}" ]; then
  gh issue create --title "${title}" --body "The independent encrypted-backup collector failed. No current off-host receipt is available until a successful collector run closes this issue. Run: ${GITHUB_SERVER_URL}/${GITHUB_REPOSITORY}/actions/runs/${GITHUB_RUN_ID}"
fi
