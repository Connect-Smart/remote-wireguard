#!/usr/bin/with-contenv bashio
# ==============================================================================
# Home Assistant Third Party Add-on: WireGuard Client
# Haalt openstaande update-commando's op bij de Remote Portal en voert ze uit
# via de Supervisor API (hetzelfde mechanisme dat het 'ha' CLI commando gebruikt).
# ==============================================================================

set -o pipefail

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

# Trim whitespace
PORTAL_URL=$(echo "${PORTAL_URL}" | xargs)
ENROLLMENT_TOKEN=$(echo "${ENROLLMENT_TOKEN}" | xargs)

if [[ -z "${ENROLLMENT_TOKEN}" ]]; then
    bashio::log.debug "HA Commands: geen enrollment_token beschikbaar, overslaan"
    exit 0
fi

if [[ "${PORTAL_URL}" != http://* && "${PORTAL_URL}" != https://* ]]; then
    PORTAL_URL="https://${PORTAL_URL}"
fi
PORTAL_URL="${PORTAL_URL%/}"

if [ "${VERIFY_SSL,,}" = "false" ]; then
    CURL_OPTS="-k"
else
    CURL_OPTS=""
fi

report_result() {
    local command_id="${1}"
    local status="${2}"      # done | error
    local message="${3}"

    local payload
    payload=$(jq -n --arg status "${status}" --arg message "${message}" '{status: $status, message: $message}')

    curl -s ${CURL_OPTS} -X POST "${PORTAL_URL}/api/ha-commands/${command_id}/result" \
        -H "Authorization: Bearer ${ENROLLMENT_TOKEN}" \
        -H "Content-Type: application/json" \
        -H "X-Addon-Version: ${ADDON_VERSION}" \
        -d "${payload}" > /dev/null 2>&1
}

# Voer één update-commando uit via de Supervisor API. Retourneert 0 bij succes.
execute_command() {
    local action="${1}"
    local slug="${2}"
    local endpoint=""

    case "${action}" in
        update_core)       endpoint="${SUPERVISOR_API}/core/update" ;;
        update_os)         endpoint="${SUPERVISOR_API}/os/update" ;;
        update_supervisor) endpoint="${SUPERVISOR_API}/supervisor/update" ;;
        update_addon)
            if [[ -z "${slug}" ]]; then
                EXEC_MESSAGE="Geen add-on slug meegegeven"
                return 1
            fi
            endpoint="${SUPERVISOR_API}/addons/${slug}/update"
            ;;
        *)
            EXEC_MESSAGE="Onbekende actie: ${action}"
            return 1
            ;;
    esac

    bashio::log.info "HA Commands: uitvoeren '${action}' via ${endpoint}..."

    # Updates (vooral core/os) kunnen enkele minuten duren; Supervisor API antwoordt
    # pas als de update klaar is. Geef ruim de tijd.
    local response
    response=$(curl -s --max-time 1800 \
        -H "Authorization: Bearer ${SUPERVISOR_TOKEN}" \
        -H "Content-Type: application/json" \
        -X POST "${endpoint}" 2>/dev/null)

    if [[ -z "${response}" ]]; then
        EXEC_MESSAGE="Geen reactie van Supervisor API"
        return 1
    fi

    local result
    result=$(echo "${response}" | jq -r '.result // empty')

    if [[ "${result}" == "ok" ]]; then
        EXEC_MESSAGE="${action} succesvol uitgevoerd"
        return 0
    fi

    EXEC_MESSAGE=$(echo "${response}" | jq -r '.message // "onbekende fout"')
    return 1
}

# Verwerk maximaal 5 openstaande commando's per poll-cyclus
for _ in 1 2 3 4 5; do
    PULL_RESPONSE=$(curl -s ${CURL_OPTS} \
        -H "Authorization: Bearer ${ENROLLMENT_TOKEN}" \
        "${PORTAL_URL}/api/ha-commands/pull" 2>/dev/null)

    if [[ -z "${PULL_RESPONSE}" ]]; then
        bashio::log.warning "HA Commands: geen reactie van portal bij ophalen commando"
        break
    fi

    COMMAND_ID=$(echo "${PULL_RESPONSE}" | jq -r '.command.id // empty')
    if [[ -z "${COMMAND_ID}" ]]; then
        # Geen openstaande commando's meer
        break
    fi

    ACTION=$(echo "${PULL_RESPONSE}" | jq -r '.command.action // empty')
    SLUG=$(echo "${PULL_RESPONSE}" | jq -r '.command.params.slug // empty')

    bashio::log.info "HA Commands: commando ${COMMAND_ID} ontvangen: ${ACTION} ${SLUG}"

    EXEC_MESSAGE=""
    if execute_command "${ACTION}" "${SLUG}"; then
        bashio::log.info "HA Commands: commando ${COMMAND_ID} (${ACTION}) succesvol"
        report_result "${COMMAND_ID}" "done" "${EXEC_MESSAGE}"
    else
        bashio::log.error "HA Commands: commando ${COMMAND_ID} (${ACTION}) mislukt: ${EXEC_MESSAGE}"
        report_result "${COMMAND_ID}" "error" "${EXEC_MESSAGE}"
    fi
done
