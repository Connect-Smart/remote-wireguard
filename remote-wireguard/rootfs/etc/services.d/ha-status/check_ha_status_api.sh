#!/usr/bin/with-contenv bashio
# ==============================================================================
# Home Assistant Third Party Add-on: WireGuard Client
# Haalt Home Assistant status op via Supervisor API en stuurt naar Remote Portal
# Alternatief voor ha CLI command als die niet beschikbaar is
# ==============================================================================

set -o pipefail

# Supervisor API endpoint
SUPERVISOR_API="http://supervisor"
SUPERVISOR_TOKEN="${SUPERVISOR_TOKEN}"

# Configuratie ophalen
get_config_value() {
    local key="${1}"
    local default="${2}"
    local value="${default}"

    if bashio::config.has_value "advanced.${key}"; then
        value=$(bashio::config "advanced.${key}")
    elif bashio::config.has_value "${key}"; then
        value=$(bashio::config "${key}")
    fi

    echo "${value}"
}

PORTAL_URL=$(get_config_value "portal_url" "https://remote.connect-smart.nl")
ENROLLMENT_TOKEN=$(bashio::config "enrollment_token")
VERIFY_SSL=$(get_config_value "verify_ssl" "true")
ADDON_VERSION=$(bashio::addon.version 2>/dev/null || echo "")

# Staat backup (ha-backup service) aan of uit? Zo weet de portal dit zonder dat
# een admin het los moet instellen — dezelfde config die create_backup.sh gebruikt.
BACKUP_ENABLED_RAW=$(get_config_value "backup_enabled" "true")
BACKUP_ENABLED="true"
if [[ "${BACKUP_ENABLED_RAW,,}" == "false" ]]; then
    BACKUP_ENABLED="false"
fi

# Trim whitespace
PORTAL_URL=$(echo "${PORTAL_URL}" | xargs)
ENROLLMENT_TOKEN=$(echo "${ENROLLMENT_TOKEN}" | xargs)

# SSL verificatie instelling
if [ "${VERIFY_SSL,,}" = "false" ]; then
    CURL_OPTS="-k"
else
    CURL_OPTS=""
fi

# Controleer enrollment token
if [[ -z "${ENROLLMENT_TOKEN}" ]]; then
    bashio::log.warning "HA Status: geen enrollment_token beschikbaar"
    exit 0
fi

# Portal URL normaliseren
if [[ "${PORTAL_URL}" != http://* && "${PORTAL_URL}" != https://* ]]; then
    PORTAL_URL="https://${PORTAL_URL}"
fi
PORTAL_URL="${PORTAL_URL%/}"

bashio::log.info "HA Status: ophalen via Supervisor API..."

# Haal status op via Supervisor API
CORE_INFO=$(curl -s -H "Authorization: Bearer ${SUPERVISOR_TOKEN}" "${SUPERVISOR_API}/core/info" 2>/dev/null || echo '{"data":{}}')
OS_INFO=$(curl -s -H "Authorization: Bearer ${SUPERVISOR_TOKEN}" "${SUPERVISOR_API}/os/info" 2>/dev/null || echo '{"data":{}}')
SUPERVISOR_INFO=$(curl -s -H "Authorization: Bearer ${SUPERVISOR_TOKEN}" "${SUPERVISOR_API}/supervisor/info" 2>/dev/null || echo '{"data":{}}')
ADDONS_INFO=$(curl -s -H "Authorization: Bearer ${SUPERVISOR_TOKEN}" "${SUPERVISOR_API}/addons" 2>/dev/null || echo '{"data":{"addons":[]}}')
RESOLUTION_INFO=$(curl -s -H "Authorization: Bearer ${SUPERVISOR_TOKEN}" "${SUPERVISOR_API}/resolution/info" 2>/dev/null || echo '{"data":{"issues":[],"suggestions":[]}}')

# Debug logging
bashio::log.debug "Core info: ${CORE_INFO}"
bashio::log.debug "OS info: ${OS_INFO}"
bashio::log.debug "Supervisor info: ${SUPERVISOR_INFO}"
bashio::log.debug "Addons info: ${ADDONS_INFO}"
bashio::log.debug "Resolution info: ${RESOLUTION_INFO}"

# Parse updates (zonder -r voor booleans)
CORE_UPDATE=$(echo "${CORE_INFO}" | jq '.data.update_available // false')
CORE_VERSION=$(echo "${CORE_INFO}" | jq -r '.data.version // "unknown"')
CORE_LATEST=$(echo "${CORE_INFO}" | jq -r '.data.version_latest // "unknown"')

OS_UPDATE=$(echo "${OS_INFO}" | jq '.data.update_available // false')
OS_VERSION=$(echo "${OS_INFO}" | jq -r '.data.version // "unknown"')
OS_LATEST=$(echo "${OS_INFO}" | jq -r '.data.version_latest // "unknown"')

SUPERVISOR_UPDATE=$(echo "${SUPERVISOR_INFO}" | jq '.data.update_available // false')
SUPERVISOR_VERSION=$(echo "${SUPERVISOR_INFO}" | jq -r '.data.version // "unknown"')
SUPERVISOR_LATEST=$(echo "${SUPERVISOR_INFO}" | jq -r '.data.version_latest // "unknown"')

# Parse add-on updates
ADDON_UPDATES=$(echo "${ADDONS_INFO}" | jq '[
    .data.addons[]?
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

# Overige update-entiteiten in Home Assistant zelf: HACS, integraties, apparaten (bv.
# ESPHome) en al het andere dat het standaard 'update'-domein gebruikt. Dit komt via de
# door Supervisor geproxyde Core API (mogelijk dankzij homeassistant_api: true), niet via
# de Supervisor API zelf. Core/OS/Supervisor/add-on-updates staan hierboven al via de
# Supervisor API; die entity_id's sluiten we hier uit zodat ze niet dubbel verschijnen.
STATES_INFO=$(curl -s -H "Authorization: Bearer ${SUPERVISOR_TOKEN}" "${SUPERVISOR_API}/core/api/states" 2>/dev/null || echo '[]')
bashio::log.debug "States info: ${STATES_INFO}"

EXCLUDE_ENTITY_IDS=$(echo "${ADDONS_INFO}" | jq '
    ["update.home_assistant_core_update", "update.home_assistant_supervisor_update", "update.home_assistant_operating_system_update"]
    + [(.data.apps // .data.addons // [])[]? | "update." + (.slug | gsub("-"; "_")) + "_update"]
')

OTHER_UPDATES=$(echo "${STATES_INFO}" | jq --argjson exclude "${EXCLUDE_ENTITY_IDS}" '[
    .[]?
    | select(.entity_id | startswith("update."))
    | select(.state == "on")
    | select(.entity_id as $id | ($exclude | index($id)) == null)
    | {
        entity_id: .entity_id,
        name: (.attributes.friendly_name // .attributes.title // .entity_id),
        current: (.attributes.installed_version // "onbekend"),
        latest: (.attributes.latest_version // "onbekend")
      }
] // []')

# Parse repairs/issues
ISSUES=$(echo "${RESOLUTION_INFO}" | jq '[
    .data.issues[]?
    | {
        uuid: .uuid,
        type: .type,
        context: .context,
        reference: .reference
      }
]')

SUGGESTIONS=$(echo "${RESOLUTION_INFO}" | jq '[
    .data.suggestions[]?
    | {
        uuid: .uuid,
        type: .type,
        context: .context,
        reference: .reference
      }
]')

UNHEALTHY=$(echo "${RESOLUTION_INFO}" | jq '.data.unhealthy // []')

# Home Assistant Core "Reparaties" (Instellingen > Systeem > Reparaties) zijn een apart
# systeem van Supervisor's resolution center hierboven, en alleen via de WebSocket API
# beschikbaar (geen REST endpoint). We halen ze op via websocat en voegen ze toe aan
# dezelfde ISSUES-lijst. Zonder de vertaalcatalogus van elke integratie erbij te halen
# is er geen exacte, vertaalde tekst zoals in de HA-interface; domain + translation_key
# + severity geven al genoeg context om te weten om welke reparatie het gaat.
fetch_core_repair_issues() {
    if ! command -v websocat >/dev/null 2>&1; then
        echo '[]'
        return
    fi
    local auth_msg cmd_msg raw_output
    auth_msg=$(jq -nc --arg token "${SUPERVISOR_TOKEN}" '{type: "auth", access_token: $token}')
    cmd_msg='{"id":1,"type":"repairs/list_issues"}'
    raw_output=$(
        { printf '%s\n%s\n' "${auth_msg}" "${cmd_msg}"; sleep 2; } \
            | timeout 10 websocat "ws://supervisor/core/websocket" 2>/dev/null
    )
    echo "${raw_output}" | jq -c 'select(.id == 1 and .type == "result") | .result.issues // []' 2>/dev/null | tail -n1
}

CORE_REPAIR_ISSUES_RAW=$(fetch_core_repair_issues)
if [[ -z "${CORE_REPAIR_ISSUES_RAW}" ]]; then
    CORE_REPAIR_ISSUES_RAW='[]'
fi
bashio::log.debug "Core repair issues: ${CORE_REPAIR_ISSUES_RAW}"

CORE_ISSUES=$(echo "${CORE_REPAIR_ISSUES_RAW}" | jq '[
    .[]?
    | select(.ignored != true)
    | {
        uuid: ("core:" + .domain + ":" + .issue_id),
        type: (.domain + "." + .translation_key),
        context: .severity,
        reference: null
      }
] // []')

ISSUES=$(echo "${ISSUES}" | jq --argjson core_issues "${CORE_ISSUES}" '. + $core_issues')

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
  --argjson other_updates "${OTHER_UPDATES}" \
  --argjson issues "${ISSUES}" \
  --argjson suggestions "${SUGGESTIONS}" \
  --argjson unhealthy "${UNHEALTHY}" \
  --argjson backup_enabled "${BACKUP_ENABLED}" \
  '{
    updates: {
      core: (if $core_update then {current: $core_version, latest: $core_latest} else null end),
      os: (if $os_update then {current: $os_version, latest: $os_latest} else null end),
      supervisor: (if $supervisor_update then {current: $supervisor_version, latest: $supervisor_latest} else null end),
      addons: $addon_updates,
      other: $other_updates
    },
    repairs: {
      issues: $issues,
      suggestions: $suggestions,
      unhealthy: $unhealthy
    },
    backup_enabled: $backup_enabled,
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
    RESPONSE=$(curl -s -w "\n%{http_code}" -k -X POST "${PORTAL_URL}/api/ha-status/push" -H "Authorization: Bearer ${ENROLLMENT_TOKEN}" -H "Content-Type: application/json" -H "X-Addon-Version: ${ADDON_VERSION}" -d "${PAYLOAD}")
else
    RESPONSE=$(curl -s -w "\n%{http_code}" -X POST "${PORTAL_URL}/api/ha-status/push" -H "Authorization: Bearer ${ENROLLMENT_TOKEN}" -H "Content-Type: application/json" -H "X-Addon-Version: ${ADDON_VERSION}" -d "${PAYLOAD}")
fi

HTTP_CODE=$(echo "${RESPONSE}" | tail -n1)
RESPONSE_BODY=$(echo "${RESPONSE}" | head -n-1)

if [ "${HTTP_CODE}" = "200" ] || [ "${HTTP_CODE}" = "201" ]; then
    bashio::log.info "HA Status: succesvol verstuurd naar portal"
else
    bashio::log.warning "HA Status: fout bij versturen: HTTP ${HTTP_CODE}"
    bashio::log.debug "HA Status response: ${RESPONSE_BODY}"
fi
