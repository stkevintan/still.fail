#!/bin/sh
# Puts this machine's iroh-relay on a cloud's list of relays (src/relay-registry.ts), with a token the cloud's operator
# made for it (the console's 中继 page, or POST /v1/admin/relays/token with ADMIN_TOKEN): a relay deployed without one
# is on no cloud's list, and serves only the workspaces that add it themselves (the `relays` tool). Run here as root,
# once the relay answers on its URL:
#   sh relay-enroll.sh <cloud> <token> [<this relay's URL>]     (the URL where the token names none)
#   ssh root@<relay-host> sh -s <cloud> <token> [<url>] < cloud/relay-enroll.sh
# The relay is on the list at once, every station and device told; the secret it is given goes into
# /etc/iroh-relay/load.env, where relay-load.sh sends its counters with it. Enrolling again (a new token) gives it a new one.
set -eu
cloud=${1:?the cloud, https://app.still.fail}
token=${2:?the token the operator made}
url=${3:-}
env=/etc/iroh-relay/load.env
# (JSON by hand: a token and a URL hold nothing that needs escaping but these)
esc() { printf '%s' "$1" | sed 's/\\/\\\\/g; s/"/\\"/g'; }
body="{\"token\":\"$(esc "$token")\"${url:+,\"url\":\"$(esc "$url")\"}}"
answer=$(curl -fsS --max-time 20 -H "content-type: application/json" --data "$body" "$cloud/v1/relays/enroll") || {
  echo "not enrolled: the cloud refused (a token used, past its day, or another relay's URL)" >&2
  exit 1
}
field() { printf '%s' "$answer" | sed -n "s/.*\"$1\":\"\\([^\"]*\\)\".*/\\1/p"; }
secret=$(field secret)
url=$(field url)
[ -n "$secret" ] && [ -n "$url" ] || { echo "not enrolled: the cloud answered $answer" >&2; exit 1; }
mkdir -p "$(dirname "$env")"
touch "$env" && chmod 600 "$env"
kept=$(grep -v '^RELAY_URL=\|^RELAY_SECRET=\|^CLOUD=' "$env" || true)
printf '%s\nRELAY_URL=%s\nRELAY_SECRET=%s\nCLOUD=%s\n' "$kept" "$url" "$secret" "$cloud" | sed '/^$/d' > "$env"
echo "on $cloud's list as $url ($(field name)); its counters go with the secret in $env (relay-load.sh)"
