#!/bin/bash
# Check the properties of the vendored compose project that the build cannot
# recover from later.
#
# An appliance that pulls "latest" is not a template: two deployments of the
# same image run different code. An appliance that ships an upstream sample
# password is worse. Both are cheap to check from a checkout, and expensive to
# discover on a customer's network.
#
#     bash Appliances/netbox-diode/tests/test_compose_pinned.sh
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
COMPOSE="${HERE}/../files/diode-appliance/compose/docker-compose.yaml"
ENV_TEMPLATE="${HERE}/../files/diode-appliance/compose/env.template"

failures=0
check() { # check <label> <condition-exit> [detail]
	if [ "${2}" -eq 0 ]; then
		printf 'ok   %s\n' "${1}"
	else
		printf 'FAIL %s%s\n' "${1}" "${3:+ -- $3}"
		failures=$((failures + 1))
	fi
}

# --- no floating tags ---------------------------------------------------
# Upstream's compose defaults its own tag to "latest" (${DIODE_TAG:-latest})
# and pins nginx and redis to :latest outright. All three are removed in the
# vendored copy; this is what keeps them removed across a re-vendor.
offenders="$(grep -nE 'image:.*:latest|:-latest' "${COMPOSE}" || true)"
check "no image in the compose file resolves to latest" \
	"$([ -z "${offenders}" ] && echo 0 || echo 1)" "${offenders}"

offenders="$(grep -nE '^[A-Z0-9_]+_IMAGE=.*:latest$|^DIODE_TAG=.*latest' "${ENV_TEMPLATE}" || true)"
check "no image in env.template resolves to latest" \
	"$([ -z "${offenders}" ] && echo 0 || echo 1)" "${offenders}"

# --- every image tag is explicit ---------------------------------------
untagged="$(grep -oE 'image: [^$][^[:space:]]*' "${COMPOSE}" |
	awk '$2 !~ /:/ { print $2 }' || true)"
check "every literal image reference carries a tag" \
	"$([ -z "${untagged}" ] && echo 0 || echo 1)" "${untagged}"

# --- nothing published off loopback ------------------------------------
# The single assertion the appliance's whole network posture rests on: Docker
# inserts its rules ahead of ufw's chains, so a port published on 0.0.0.0 is
# reachable whatever ufw says.
published="$(grep -nE '^\s+- [^#]*:[0-9]+:[0-9]+' "${COMPOSE}" |
	grep -v '127\.0\.0\.1:' || true)"
check "every published port binds 127.0.0.1" \
	"$([ -z "${published}" ] && echo 0 || echo 1)" "${published}"

# --- no secret in the template ------------------------------------------
# Upstream's sample.env carries <PLACEHOLDER_SECRET> values. The appliance's
# template must carry substitution markers instead, so that first boot -
# not the build, and not upstream - decides every password.
for key in REDIS_PASSWORD POSTGRES_PASSWORD DIODE_POSTGRES_PASSWORD \
	HYDRA_POSTGRES_PASSWORD HYDRA_SECRETS_SYSTEM_0; do
	value="$(grep -E "^${key}=" "${ENV_TEMPLATE}" | cut -d= -f2-)"
	case "${value}" in
	__*__) check "${key} is a first-boot placeholder" 0 ;;
	"") check "${key} is a first-boot placeholder" 1 "not set at all" ;;
	*) check "${key} is a first-boot placeholder" 1 "literal value: ${value}" ;;
	esac
done

# --- telemetry off ------------------------------------------------------
# An appliance at a customer site must not phone home by default.
sentry="$(grep -E '^SENTRY_DSN=.+' "${ENV_TEMPLATE}" || true)"
check "no Sentry DSN is baked in" \
	"$([ -z "${sentry}" ] && echo 0 || echo 1)" "${sentry}"
traces="$(grep -E '^TELEMETRY_TRACES_EXPORTER=none$' "${ENV_TEMPLATE}" || true)"
check "trace export is off" "$([ -n "${traces}" ] && echo 0 || echo 1)"

echo
if [ "${failures}" -eq 0 ]; then
	echo "PASS"
else
	echo "FAIL (${failures})"
fi
exit "$((failures == 0 ? 0 : 1))"
