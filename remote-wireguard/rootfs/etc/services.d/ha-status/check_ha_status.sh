#!/usr/bin/with-contenv bashio
# ==============================================================================
# Home Assistant Third Party Add-on: WireGuard Client
# Haalt Home Assistant status op en stuurt deze naar de Remote Portal
# ==============================================================================

set -o pipefail

# Configuratie ophalen met ondersteuning voor advanced sectie
get_config_value() {
    local key="${1}"
    local default="${2}"
    local value="${default}"

    # Probeer eerst de advanced sectie
    if bashio::config.has_value "advanced.${key}"; then
        value=$(bashio::config "advanced.${key}")
    # Anders probeer gewoon de key
    elif bashio::config.has_value "${key}"; then
        value=$(bashio::config "${key}")
    fi

    echo "${value}"
}

PORTAL_URL=$(get_config_value "portal_url" "https://remote.connect-smart.nl")
ENROLLMENT_TOKEN=$(bashio::config "enrollment_token")
VERIFY_SSL=$(get_config_value "verify_ssl" "true")

# Trim whitespace
PORTAL_URL=$(echo "${PORTAL_URL}" | xargs)
ENROLLMENT_TOKEN=$(echo "${ENROLLMENT_TOKEN}" | xargs)

# SSL verificatie instelling
if [ "${VERIFY_SSL,,}" = "false" ]; then
    CURL_OPTS="-k"
else
    CURL_OPTS=""
fi

# Controleer of we een enrollment token hebben
if [[ -z "${ENROLLMENT_TOKEN}" ]]; then
    bashio::log.warning "HA Status: geen enrollment_token beschikbaar, kan status niet versturen."
    exit 0
fi

# Zorg dat portal URL juist is
if [[ "${PORTAL_URL}" != http://* && "${PORTAL_URL}" != https://* ]]; then
    PORTAL_URL="https://${PORTAL_URL}"
fi
PORTAL_URL="${PORTAL_URL%/}"

bashio::log.info "HA Status: ophalen Home Assistant status..."

# Haal alle status informatie op
CORE_INFO=$(ha core info --raw-json 2>/dev/null || echo '{}')
OS_INFO=$(ha os info --raw-json 2>/dev/null || echo '{}')
SUPERVISOR_INFO=$(ha supervisor info --raw-json 2>/dev/null || echo '{}')

# Gebruik 'ha apps' (nieuwere versie) of fallback naar 'ha addons' (oudere versie)
ADDONS_INFO=$(ha apps --raw-json 2>/dev/null || ha addons --raw-json 2>/dev/null || echo '{"data":{"addons":[],"apps":[]}}')

# Debug logging (alleen als log level debug of lager)
bashio::log.debug "Core info: ${CORE_INFO}"
bashio::log.debug "OS info: ${OS_INFO}"
bashio::log.debug "Supervisor info: ${SUPERVISOR_INFO}"
bashio::log.debug "Addons/Apps info: ${ADDONS_INFO}"

# Parse updates (zonder -r voor booleans om JSON te behouden)
CORE_UPDATE=$(echo "${CORE_INFO}" | jq '.data.update_available // false')
CORE_VERSION=$(echo "${CORE_INFO}" | jq -r '.data.version // "unknown"')
CORE_LATEST=$(echo "${CORE_INFO}" | jq -r '.data.version_latest // "unknown"')

OS_UPDATE=$(echo "${OS_INFO}" | jq '.data.update_available // false')
OS_VERSION=$(echo "${OS_INFO}" | jq -r '.data.version // "unknown"')
OS_LATEST=$(echo "${OS_INFO}" | jq -r '.data.version_latest // "unknown"')

SUPERVISOR_UPDATE=$(echo "${SUPERVISOR_INFO}" | jq '.data.update_available // false')
SUPERVISOR_VERSION=$(echo "${SUPERVISOR_INFO}" | jq -r '.data.version // "unknown"')
SUPERVISOR_LATEST=$(echo "${SUPERVISOR_INFO}" | jq -r '.data.version_latest // "unknown"')

# Parse add-on updates (support both 'apps' and 'addons' for compatibility)
ADDON_UPDATES=$(echo "${ADDONS_INFO}" | jq '[
    (.data.apps // .data.addons // [])[]
    | select(.update_available == true)
    | {
        name: .name,
        slug: .slug,
        current: .version,
        latest: .version_latest,
        installed: .installed,
        icon: .icon
      }
]')

# Bouw JSON payload
PAYLOAD=$(jq -n \
  --argjson core_update "${CORE_UPDATE}" \
  --arg core_version "${CORE_VERSION}" \
  --arg core_latest "${CORE_LATEST}" \
  --argjson os_update "${OS_UPDATE}" \
  --arg os_version "${OS_VERSION}" \
  --arg os_latest "${OS_LATEST}" \
  --argjson supervisor_update "${SUPERVISOR_UPDATE}" \
  --arg supervisor_version "${SUPERVISOR_VERSION}" \
  --arg supervisor_latest "${SUPERVISOR_LATEST}" \
  --argjson addon_updates "${ADDON_UPDATES}" \
  '{
    updates: {
      core: (if $core_update then {current: $core_version, latest: $core_latest} else null end),
      os: (if $os_update then {current: $os_version, latest: $os_latest} else null end),
      supervisor: (if $supervisor_update then {current: $supervisor_version, latest: $supervisor_latest} else null end),
      addons: $addon_updates
    },
    timestamp: now
  }')

# Valideer payload
if [[ -z "${PAYLOAD}" || "${PAYLOAD}" == "null" ]]; then
    bashio::log.error "HA Status: payload is leeg, skip verzenden"
    exit 1
fi

# Valideer JSON
if ! echo "${PAYLOAD}" | jq empty 2>/dev/null; then
    bashio::log.error "HA Status: payload is geen geldige JSON"
    bashio::log.debug "Invalid payload: ${PAYLOAD}"
    exit 1
fi

bashio::log.debug "HA Status payload: ${PAYLOAD}"
bashio::log.info "HA Status: versturen naar portal..."

# Stuur naar portal met correcte curl opties
if [ "${VERIFY_SSL,,}" = "false" ]; then
    RESPONSE=$(curl -s -w "\n%{http_code}" -k -X POST \
      "${PORTAL_URL}/api/ha-status/push" \
      -H "Authorization: Bearer ${ENROLLMENT_TOKEN}" \
      -H "Content-Type: application/json" \
      -d "${PAYLOAD}")
else
    RESPONSE=$(curl -s -w "\n%{http_code}" -X POST \
      "${PORTAL_URL}/api/ha-status/push" \
      -H "Authorization: Bearer ${ENROLLMENT_TOKEN}" \
      -H "Content-Type: application/json" \
      -d "${PAYLOAD}")
fi

HTTP_CODE=$(echo "${RESPONSE}" | tail -n1)
RESPONSE_BODY=$(echo "${RESPONSE}" | head -n-1)

if [ "${HTTP_CODE}" = "200" ] || [ "${HTTP_CODE}" = "201" ]; then
    bashio::log.info "HA Status: succesvol verstuurd naar portal"
else
    bashio::log.warning "HA Status: fout bij versturen: HTTP ${HTTP_CODE}"
    bashio::log.debug "HA Status response: ${RESPONSE_BODY}"
fi
