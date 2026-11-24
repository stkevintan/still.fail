#!/bin/bash
# Waits for a pull request's checks: exit 0 when all passed, 1 at the first failure (printing the check and its link),
# 3 when the PR got a new commit, 4 when a PR from a fork has no run yet (it needs approval), 2 when GitHub cannot be read.
# Usage: bash ci-wait.sh <PR number> [owner/name, default the current directory's GitHub repository]
# Run it in the background; when it ends, look at the checks yourself before merging.
#
# - Each look is one GraphQL query (a point of GraphQL's own 5000 an hour): the REST calls it made before (gh pr view,
#   gh pr checks' pages, gh run list), every 30 s from every session on a machine sharing one token, spent REST's 5000
#   an hour in twenty minutes for every tool of theirs. Where GraphQL fails, or a commit has more check runs or suites
#   than one query reads, that look is made as before by REST.
# - Checks are judged by the buckets of `gh pr checks` (pass/fail/pending/skipping/cancel), not by grepping text (a
#   repository or link with "fail" in it matches every line).
# - Done means this commit's workflow runs appeared and all completed. Runs of one push are created together: one that
#   has not appeared was not triggered, so no names are waited for.
# - The first failure exits at once, without waiting for the rest, with what the failed check said of it (its failure
#   annotations: scripts/check.sh puts the failing tests there). A running job is now and then reported failed and then
#   in progress again: look at that job before concluding.
set -u
pr=${1:?usage: ci-wait.sh <PR number> [owner/name]}
repo=${2:-}
if [ -z "$repo" ]; then
  repo=$(git remote get-url origin 2>/dev/null | sed -nE 's#.*github\.com[:/]([^/]+/[^/]+)$#\1#p' | sed 's/\.git$//')
  [ -n "$repo" ] || repo=$(gh repo view --json nameWithOwner -q .nameWithOwner) || exit 2
fi
every=${CI_WAIT_EVERY:-30}

# A look, as one JSON: {sha, cross, more, checks: [{name, bucket, link, id}], runs: [{name, status, conclusion, url}]},
# status and conclusion as REST says them (lower case).
query='query($owner: String!, $name: String!, $pr: Int!) {
  repository(owner: $owner, name: $name) { pullRequest(number: $pr) { isCrossRepository headRefOid
    commits(last: 1) { nodes { commit { oid
      status { contexts { context state targetUrl } }
      checkSuites(first: 30) { pageInfo { hasNextPage } nodes { status conclusion
        workflowRun { databaseId url workflow { name } }
        checkRuns(first: 100, filterBy: { checkType: LATEST }) { pageInfo { hasNextPage }
          nodes { id name status conclusion detailsUrl } } } } } } } } } }'
shape='.data.repository.pullRequest as $p | ($p.commits.nodes[0].commit) as $c | {
  sha: $p.headRefOid, cross: $p.isCrossRepository,
  more: ($c.checkSuites.pageInfo.hasNextPage or ([$c.checkSuites.nodes[].checkRuns.pageInfo.hasNextPage] | any)),
  checks: ([$c.checkSuites.nodes[].checkRuns.nodes[] | {name, link: .detailsUrl, id, bucket: (
      if .status != "COMPLETED" then "pending"
      elif .conclusion == "SUCCESS" then "pass"
      elif .conclusion == "SKIPPED" or .conclusion == "NEUTRAL" then "skipping"
      elif .conclusion == "CANCELLED" then "cancel"
      else "fail" end)}]
    + [($c.status.contexts // [])[] | {name: .context, link: .targetUrl, id: null, bucket: (
      if .state == "PENDING" or .state == "EXPECTED" then "pending"
      elif .state == "SUCCESS" then "pass"
      else "fail" end)}]),
  runs: [$c.checkSuites.nodes[] | select(.workflowRun != null) | {name: .workflowRun.workflow.name,
    status: (.status | ascii_downcase), conclusion: ((.conclusion // "") | ascii_downcase), url: .workflowRun.url}]}'
by_graphql() {
  gh api graphql -f query="$query" -f owner="${repo%%/*}" -f name="${repo#*/}" -F pr="$pr" 2>/dev/null |
    jq -ce "$shape" 2>/dev/null
}
by_rest() {
  local sha cross c runs
  sha=$(gh pr view "$pr" -R "$repo" --json headRefOid -q .headRefOid 2>/dev/null) && [ -n "$sha" ] || return 1
  cross=$(gh pr view "$pr" -R "$repo" --json isCrossRepository -q .isCrossRepository 2>/dev/null)
  c=$(gh pr checks "$pr" -R "$repo" --json name,bucket,link 2>/dev/null) || c='[]'
  [ -z "$c" ] && c='[]'
  runs=$(gh run list -R "$repo" --commit "$sha" --limit 50 --json name,status,conclusion,url 2>/dev/null) || runs='[]'
  [ -z "$runs" ] && runs='[]'
  jq -cn --arg sha "$sha" --arg cross "$cross" --argjson c "$c" --argjson runs "$runs" \
    '{sha: $sha, cross: ($cross == "true"), more: false, checks: [$c[] | . + {id: null}], runs: $runs}'
}
look() {
  local l
  l=$(by_graphql)
  if [ -n "$l" ] && [ "$(printf '%s' "$l" | jq -r .more)" = false ]; then printf '%s' "$l"; return 0; fi
  by_rest
}
# What the failed check runs said of their failure (their annotations at level failure), indented under each.
notes() {
  local ids
  ids=$(jq -c '[.[] | select(.id != null) | .id]' <<< "$1")
  [ "$ids" = '[]' ] && return 0
  jq -cn --argjson ids "$ids" '{variables: {ids: $ids}, query: "query($ids: [ID!]!) { nodes(ids: $ids) { ... on CheckRun { id annotations(first: 5) { nodes { annotationLevel title message } } } } }"}' |
    gh api graphql --input - 2>/dev/null |
    jq -r '.data.nodes[] | select(. != null) | .id as $id
      | [.annotations.nodes[] | select(.annotationLevel == "FAILURE" and (.message // "") != ""
          and .message != "Process completed with exit code 1.")][:3][]
      | ((if (.title // "") != "" then "\(.title): " else "" end) + .message) as $m
      | "\($id)\t\((if ($m | length) > 600 then $m[:600] + " …" else $m end) | gsub("\n"; "\n      "))"' 2>/dev/null
}

l=$(look) || exit 2
sha=$(jq -r .sha <<< "$l")
echo "PR #$pr $repo at $sha"

# A PR from a fork has no run at all until the repository approves it: waiting would last until a timeout.
if [ "$(jq -r .cross <<< "$l")" = true ] && [ "$(jq '.runs | length' <<< "$l")" = 0 ]; then
  echo "This PR comes from a fork and its commit has no run yet: approve its runs (gh api -X POST repos/$repo/actions/runs/<id>/approve) or as the project does, then run this again"
  exit 4
fi

while :; do
  now=$(jq -r .sha <<< "$l")
  if [ -n "$now" ] && [ "$now" != "$sha" ]; then
    echo "The PR got a new commit $now (was $sha): run this again"
    exit 3
  fi
  bad=$(jq -c '[.checks[] | select(.bucket == "fail" or .bucket == "cancel")]' <<< "$l")
  if [ "$bad" != '[]' ]; then
    echo "Failed:"
    said=$(notes "$bad")
    # (fields apart by US, not a tab: read joins empty tab-separated fields, and REST's checks have no id)
    jq -r '.[] | "\(.id // "")\u001f\(.name)\u001f\(.link)"' <<< "$bad" | while IFS=$'\x1f' read -r id name link; do
      printf '%s\t%s\n' "$name" "$link"
      [ -n "$id" ] && [ -n "$said" ] && awk -F'\t' -v id="$id" '$1 == id { sub(/^[^\t]*\t/, ""); print "    " $0 }' <<< "$said"
    done
    exit 1
  fi
  # A run dispatched by hand is not always among the PR's checks; completed can still be failed or cancelled.
  bad_runs=$(jq -r '.runs[] | select(.status == "completed" and .conclusion != "success" and .conclusion != "skipped" and .conclusion != "neutral") | "\(.name)\t\(.conclusion)\t\(.url)"' <<< "$l")
  if [ -n "$bad_runs" ]; then
    echo "Runs failed:"
    printf '%s\n' "$bad_runs"
    exit 1
  fi
  if [ "$(jq '(.runs | length) > 0 and ([.runs[] | select(.status != "completed")] | length) == 0 and ([.checks[] | select(.bucket == "pending")] | length) == 0 and (.checks | length) > 0' <<< "$l")" = true ]; then
    echo "All passed: $(jq -r '[.checks[] | .bucket] | group_by(.) | map("\(.[0]) \(length)") | join(", ")' <<< "$l"); runs: $(jq -r '[.runs[].name] | join(" ")' <<< "$l")"
    exit 0
  fi
  sleep "$every"
  # (a look that fails is tried again at the next, as before: only the first must succeed)
  l=$(look) || l=$(jq -c '.checks = [.checks[] | .bucket = "pending"]' <<< "$l")
done
