#!/usr/bin/env bash
# Waits for given workflow runs (a release, a deploy): exit 1 as soon as a job fails, 0 when all succeeded, 2 when a
# run cannot be read.
# Usage: bash run-wait.sh <owner/name> <run id> [run id ...]
#
# Each run's commit is read once by REST; after that a look at a run is one GraphQL query of its commit's check suites
# (a point of GraphQL's own quota, not REST's 5000 an hour that every session sharing a token spends: ci-wait.sh says
# why). A run its commit's suites do not show, one with more jobs than a query reads, or GraphQL failing is read by
# REST as before (`gh run view`). RUN_WAIT_EVERY: seconds between looks, 20.
set -eu

repo=${1:?usage: run-wait.sh <owner/name> <run id> [run id ...]}
shift
if [ "$#" -eq 0 ]; then
  echo 'at least one run id is needed' >&2
  exit 2
fi
every=${RUN_WAIT_EVERY:-20}

# (each run's commit by its place among the arguments: macOS's bash 3.2 has no associative array)
shas=()
for id in "$@"; do
  shas+=("$(gh api "repos/$repo/actions/runs/$id" --jq .head_sha 2>/dev/null ||
    gh run view "$id" -R "$repo" --json headSha -q .headSha 2>/dev/null || true)")
done

query='query($owner: String!, $name: String!, $sha: GitObjectID!) {
  repository(owner: $owner, name: $name) { object(oid: $sha) { ... on Commit {
    checkSuites(first: 30) { nodes { status conclusion workflowRun { databaseId url }
      checkRuns(first: 100, filterBy: { checkType: LATEST }) { pageInfo { hasNextPage }
        nodes { id name status conclusion detailsUrl } } } } } } } }'
# A run as `gh run view --json status,conclusion,jobs` gives it (lower case, jobs with name, status, conclusion, url),
# from its commit's suites; nothing where GraphQL cannot say it whole.
by_graphql() {
  local sha=${shas[$2]:-}
  [ -n "$sha" ] || return 1
  gh api graphql -f query="$query" -f owner="${repo%%/*}" -f name="${repo#*/}" -f sha="$sha" 2>/dev/null |
    jq -ce --argjson id "$1" '[.data.repository.object.checkSuites.nodes[] | select(.workflowRun.databaseId == $id)]
      | select(length == 1 and (.[0].checkRuns.pageInfo.hasNextPage | not)) | .[0]
      | {status: (.status | ascii_downcase), conclusion: ((.conclusion // "") | ascii_downcase),
         jobs: [.checkRuns.nodes[] | {id, name, url: .detailsUrl, status: (.status | ascii_downcase),
           conclusion: ((.conclusion // "") | ascii_downcase)}]}' 2>/dev/null
}
# What the failed jobs said of their failure (their annotations at level failure: scripts/check.sh puts the failing
# tests there), indented under each.
notes() {
  local ids
  ids=$(jq -c '[.[] | .id // empty]' <<< "$1")
  [ "$ids" = '[]' ] && return 0
  jq -cn --argjson ids "$ids" '{variables: {ids: $ids}, query: "query($ids: [ID!]!) { nodes(ids: $ids) { ... on CheckRun { name annotations(first: 5) { nodes { annotationLevel title message } } } } }"}' |
    gh api graphql --input - 2>/dev/null |
    jq -r '.data.nodes[] | select(. != null) | .name as $name
      | [.annotations.nodes[] | select(.annotationLevel == "FAILURE" and (.message // "") != ""
          and .message != "Process completed with exit code 1.")][:3][]
      | ((if (.title // "") != "" then "\(.title): " else "" end) + .message) as $m
      | "  \($name): \((if ($m | length) > 600 then $m[:600] + " …" else $m end) | gsub("\n"; "\n      "))"' 2>/dev/null || true
}

while :; do
  pending=0
  k=0
  for id in "$@"; do
    k=$((k + 1))
    if ! run=$(by_graphql "$id" $((k - 1))) && ! run=$(gh run view "$id" -R "$repo" --json status,conclusion,jobs); then
      echo "cannot read run $id" >&2
      exit 2
    fi
    failed=$(printf '%s' "$run" | jq -c '[.jobs[] | select(.status == "completed" and (.conclusion == "failure" or .conclusion == "timed_out" or .conclusion == "cancelled" or .conclusion == "action_required"))]')
    if [ "$failed" != '[]' ]; then
      printf 'run %s failed:\n%s\n' "$id" "$(jq -r '.[] | "\(.name)\t\(.url)"' <<< "$failed")" >&2
      notes "$failed" >&2
      exit 1
    fi
    status=$(printf '%s' "$run" | jq -r .status)
    if [ "$status" = completed ]; then
      conclusion=$(printf '%s' "$run" | jq -r .conclusion)
      if [ "$conclusion" != success ]; then
        printf 'run %s ended: %s\n' "$id" "$conclusion" >&2
        exit 1
      fi
    else
      pending=1
    fi
  done
  if [ "$pending" -eq 0 ]; then
    printf 'all runs succeeded: %s\n' "$*"
    exit 0
  fi
  sleep "$every"
done
