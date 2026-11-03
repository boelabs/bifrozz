#!/usr/bin/env bash
# Asks Coolify to deploy the gateway, the dashboard and the docs, and waits until each deployment
# ends. Exits non-zero unless all three finish. Used by deploy-production.yml, for a release and for
# the return to what was serving.
#
# Reads COOLIFY_URL, COOLIFY_TOKEN (permissions `deploy` and `read`) and RESOURCES, the JSON map of
# app to Coolify resource UUID. Prints deployment ids and statuses, never the token.
set -euo pipefail

api="${COOLIFY_URL%/}/api/v1"
timeout_seconds="${ROLLOUT_TIMEOUT_SECONDS:-1200}"

call() {
	local method=$1 path=$2 status
	status=$(curl -sS -o response.json -w '%{http_code}' -X "$method" \
		--max-time 30 \
		-H "Authorization: Bearer $COOLIFY_TOKEN" \
		-H "Accept: application/json" \
		"$api$path")
	if [ "$status" -lt 200 ] || [ "$status" -ge 300 ]; then
		echo "::error::Coolify answered HTTP $status to $method ${path%%\?*}"
		cat response.json >&2 || true
		return 1
	fi
}

uuids=$(printf '%s' "$RESOURCES" | jq -r '[.gateway, .dashboard, .docs] | unique | join(",")')

# One request for all three. `force=false`: the images are already built, Coolify only pulls.
call POST "/deploy?uuid=${uuids}&force=false"
cat response.json
echo

# Coolify answers a resource that is already deploying with a fresh id it never runs; only the
# message tells the two apart, so that counts as a failure rather than a deployment to wait for.
if jq -e '[.deployments[]? | select((.message // "") | test("already queued"; "i"))] | length > 0' response.json >/dev/null; then
	echo "::error::Coolify already has a deployment queued or running for one of the resources."
	exit 1
fi
mapfile -t deployments < <(jq -r '.deployments[]?.deployment_uuid // empty' response.json)
expected=$(printf '%s' "$uuids" | tr ',' '\n' | wc -l)
if [ "${#deployments[@]}" -ne "$expected" ]; then
	echo "::error::Coolify queued ${#deployments[@]} deployments for $expected resources."
	exit 1
fi

deadline=$((SECONDS + timeout_seconds))
failed=0
for deployment in "${deployments[@]}"; do
	while :; do
		call GET "/deployments/${deployment}"
		status=$(jq -r '.status // "unknown"' response.json)
		case "$status" in
			finished)
				echo "Deployment $deployment finished."
				break
				;;
			queued | in_progress)
				if [ "$SECONDS" -ge "$deadline" ]; then
					echo "::error::Deployment $deployment is still $status after ${timeout_seconds}s; cancelling it."
					call POST "/deployments/${deployment}/cancel" || true
					failed=1
					break
				fi
				sleep 10
				;;
			*)
				echo "::error::Deployment $deployment ended as '$status'. Its log is in Coolify."
				failed=1
				break
				;;
		esac
	done
done

exit "$failed"
