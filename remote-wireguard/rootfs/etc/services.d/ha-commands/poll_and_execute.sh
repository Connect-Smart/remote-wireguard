#!/usr/bin/with-contenv bashio
# ==============================================================================
# Home Assistant Third Party Add-on: WireGuard Client
# Haalt openstaande update-commando's op bij de Remote Portal en voert ze uit
# via de Supervisor API (hetzelfde mechanisme dat het 'ha' CLI commando gebruikt).
#
# Extra's t.o.v. een kale update-aanroep:
#  - Schijfruimte-check vooraf (weigert de update bij te weinig vrije ruimte)
#  - Detectie van "herstart vereist" (Supervisor resolution center) -> apart
#    gemeld aan de portal zodat een admin de herstart met één klik kan starten
#  - Connectiviteitscontrole na de update: welke devices/entiteiten die vóór
#    de update beschikbaar waren, zijn dat na de update niet meer?
#  - Heartbeats tijdens een lange actie: de portal ziet zo tussentijds voortgang
#    i.p.v. alleen "Bezig" zonder updates, en beschouwt het commando als
#    vastgelopen (i.p.v. eeuwig 'Bezig') zodra de heartbeats stoppen — bv. omdat
#    een host-herstart deze container zelf onderbreekt vóórdat hij het
#    eindresultaat kon terugmelden.
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
MIN_DISK_FREE_GB=$(get_config_value "min_disk_free_gb" "2")
ADDON_VERSION=$(bashio::addon.version 2>/dev/null || echo "")

if ! [[ "${MIN_DISK_FREE_GB}" =~ ^[0-9]+([.][0-9]+)?$ ]]; then
    MIN_DISK_FREE_GB="2"
fi

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

HEARTBEAT_INTERVAL=20

report_result() {
    local command_id="${1}"
    local status="${2}"        # done | error | restart_required
    local message="${3}"
    local data_json="${4:-null}"

    local payload
    payload=$(jq -n --arg status "${status}" --arg message "${message}" --argjson data "${data_json}" \
        '{status: $status, message: $message, data: $data}')

    curl -s ${CURL_OPTS} -X POST "${PORTAL_URL}/api/ha-commands/${command_id}/result" \
        -H "Authorization: Bearer ${ENROLLMENT_TOKEN}" \
        -H "Content-Type: application/json" \
        -H "X-Addon-Version: ${ADDON_VERSION}" \
        -d "${payload}" > /dev/null 2>&1
}

# Meldt tussentijds dat een commando nog bezig is, zodat de portal het niet als
# vastgelopen beschouwt en de voortgang zichtbaar is i.p.v. alleen "Bezig".
report_heartbeat() {
    local command_id="${1}" message="${2}"
    local payload
    payload=$(jq -n --arg message "${message}" '{message: $message}')
    curl -s ${CURL_OPTS} -X POST "${PORTAL_URL}/api/ha-commands/${command_id}/heartbeat" \
        -H "Authorization: Bearer ${ENROLLMENT_TOKEN}" \
        -H "Content-Type: application/json" \
        -H "X-Addon-Version: ${ADDON_VERSION}" \
        -d "${payload}" > /dev/null 2>&1
}

# Controleer vrije schijfruimte op de host via de Supervisor API.
# Zet EXEC_MESSAGE en retourneert 1 als er te weinig ruimte is.
check_disk_space() {
    local host_info free
    host_info=$(curl -s -H "Authorization: Bearer ${SUPERVISOR_TOKEN}" "${SUPERVISOR_API}/host/info" 2>/dev/null)
    free=$(echo "${host_info}" | jq -r '.data.disk_free // empty')

    if [[ -z "${free}" ]]; then
        bashio::log.warning "HA Commands: kon vrije schijfruimte niet bepalen, update gaat toch door"
        return 0
    fi

    if awk -v f="${free}" -v m="${MIN_DISK_FREE_GB}" 'BEGIN{exit !(f < m)}'; then
        EXEC_MESSAGE="Onvoldoende schijfruimte: ${free}GB vrij (minimaal ${MIN_DISK_FREE_GB}GB vereist)"
        return 1
    fi
    return 0
}

# Haalt entity_id's op die momenteel 'unavailable' of 'unknown' zijn (gesorteerd,
# één per regel) via de door Supervisor geproxyde Home Assistant Core API.
fetch_unavailable_entities() {
    curl -s -H "Authorization: Bearer ${SUPERVISOR_TOKEN}" "${SUPERVISOR_API}/core/api/states" 2>/dev/null \
        | jq -r '[.[]? | select(.state == "unavailable" or .state == "unknown") | .entity_id] | sort | .[]' 2>/dev/null
}

# Wacht tot Home Assistant Core weer 'running' is (na een restart door de update).
# Stuurt onderweg heartbeats zodat "Bezig" niet stil blijft staan.
wait_for_core_running() {
    local command_id="${1}" timeout="${2:-300}" waited=0 state
    while (( waited < timeout )); do
        state=$(curl -s -H "Authorization: Bearer ${SUPERVISOR_TOKEN}" "${SUPERVISOR_API}/core/info" 2>/dev/null \
            | jq -r '.data.state // empty')
        if [[ "${state}" == "running" ]]; then
            return 0
        fi
        report_heartbeat "${command_id}" "Wachten tot Home Assistant weer online is... (${waited}s)"
        sleep "${HEARTBEAT_INTERVAL}"
        waited=$(( waited + HEARTBEAT_INTERVAL ))
    done
    return 1
}

# Kijkt of Supervisor's resolution center een herstart/restart-actie voorstelt
# (bv. na een OS/Supervisor update). Print de suggestie als compacte JSON, of niets.
find_restart_suggestion() {
    curl -s -H "Authorization: Bearer ${SUPERVISOR_TOKEN}" "${SUPERVISOR_API}/resolution/info" 2>/dev/null \
        | jq -c '[.data.suggestions[]? | select(.type | test("reboot|restart"; "i"))][0] // empty' 2>/dev/null
}

# Voer één commando uit via de Supervisor API. Retourneert 0 bij succes.
# Zet EXEC_MESSAGE met een omschrijving. Draait de aanroep op de achtergrond en
# stuurt onderweg heartbeats, zodat een langdurige actie (bv. een update) niet
# stil op "Bezig" blijft staan zonder voortgang.
execute_command() {
    local command_id="${1}" action="${2}" slug="${3}" uuid="${4}" endpoint=""

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
        resolve_suggestion)
            if [[ -z "${uuid}" ]]; then
                EXEC_MESSAGE="Geen suggestie-uuid meegegeven"
                return 1
            fi
            endpoint="${SUPERVISOR_API}/resolution/suggestion/${uuid}"
            ;;
        *)
            EXEC_MESSAGE="Onbekende actie: ${action}"
            return 1
            ;;
    esac

    bashio::log.info "HA Commands: uitvoeren '${action}' via ${endpoint}..."

    # Updates (vooral core/os) kunnen enkele minuten duren; Supervisor API antwoordt
    # pas als de actie klaar is. Draai de aanroep op de achtergrond zodat we
    # ondertussen heartbeats kunnen sturen i.p.v. blind te wachten.
    local tmp_response result elapsed=0
    tmp_response=$(mktemp)
    curl -s --max-time 1800 \
        -H "Authorization: Bearer ${SUPERVISOR_TOKEN}" \
        -H "Content-Type: application/json" \
        -X POST "${endpoint}" -o "${tmp_response}" 2>/dev/null &
    local curl_pid=$!

    while kill -0 "${curl_pid}" 2>/dev/null; do
        sleep "${HEARTBEAT_INTERVAL}"
        elapsed=$(( elapsed + HEARTBEAT_INTERVAL ))
        if kill -0 "${curl_pid}" 2>/dev/null; then
            report_heartbeat "${command_id}" "Bezig met ${action}... (${elapsed}s)"
        fi
    done
    wait "${curl_pid}" 2>/dev/null

    local response
    response=$(cat "${tmp_response}" 2>/dev/null)
    rm -f "${tmp_response}"

    if [[ -z "${response}" ]]; then
        EXEC_MESSAGE="Geen reactie van Supervisor API"
        return 1
    fi

    result=$(echo "${response}" | jq -r '.result // empty')

    if [[ "${result}" == "ok" ]]; then
        EXEC_MESSAGE="${action} succesvol uitgevoerd"
        return 0
    fi

    EXEC_MESSAGE=$(echo "${response}" | jq -r '.message // "onbekende fout"')
    return 1
}

# Deze acties raken Core (rechtstreeks of via een herstart) en verdienen dus
# zowel een schijfruimte-check vooraf als een connectiviteitscheck achteraf.
needs_disk_check() {
    [[ "${1}" == update_* ]]
}
needs_connectivity_check() {
    [[ "${1}" == update_* || "${1}" == "resolve_suggestion" ]]
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
    SUGGESTION_UUID=$(echo "${PULL_RESPONSE}" | jq -r '.command.params.uuid // empty')

    bashio::log.info "HA Commands: commando ${COMMAND_ID} ontvangen: ${ACTION} ${SLUG}${SUGGESTION_UUID}"

    EXEC_MESSAGE=""

    # 1) Schijfruimte-check vooraf
    if needs_disk_check "${ACTION}" && ! check_disk_space; then
        bashio::log.error "HA Commands: commando ${COMMAND_ID} geweigerd: ${EXEC_MESSAGE}"
        report_result "${COMMAND_ID}" "error" "${EXEC_MESSAGE}"
        continue
    fi

    # 2) Snapshot van niet-beschikbare devices/entiteiten vóór de actie
    BEFORE_UNAVAILABLE=""
    if needs_connectivity_check "${ACTION}"; then
        BEFORE_UNAVAILABLE=$(fetch_unavailable_entities)
    fi

    # 3) Actie uitvoeren
    if execute_command "${COMMAND_ID}" "${ACTION}" "${SLUG}" "${SUGGESTION_UUID}"; then
        EXEC_SUCCESS=true
        bashio::log.info "HA Commands: commando ${COMMAND_ID} (${ACTION}) succesvol"
    else
        EXEC_SUCCESS=false
        bashio::log.error "HA Commands: commando ${COMMAND_ID} (${ACTION}) mislukt: ${EXEC_MESSAGE}"
    fi

    # 4) Connectiviteit herchecken (wacht tot Core weer up is, vergelijk dan)
    EXEC_DATA="null"
    if needs_connectivity_check "${ACTION}"; then
        if ! wait_for_core_running "${COMMAND_ID}" 300; then
            bashio::log.warning "HA Commands: Core kwam niet binnen 5 minuten terug na commando ${COMMAND_ID}"
        fi
        AFTER_UNAVAILABLE=$(fetch_unavailable_entities)
        MISSING=$(comm -13 <(echo "${BEFORE_UNAVAILABLE}") <(echo "${AFTER_UNAVAILABLE}") | sed '/^$/d')
        if [[ -n "${MISSING}" ]]; then
            MISSING_COUNT=$(echo "${MISSING}" | grep -c .)
            EXEC_MESSAGE="${EXEC_MESSAGE} — LET OP: ${MISSING_COUNT} device(s)/entiteit(en) niet meer beschikbaar"
            EXEC_DATA=$(echo "${MISSING}" | jq -R . | jq -s '{missing_entities: .}')
        else
            EXEC_MESSAGE="${EXEC_MESSAGE} — alle devices/entiteiten weer online"
        fi
    fi

    # 5) Kijken of Supervisor een herstart adviseert (bv. na OS/Supervisor update)
    SUGGESTION=""
    if [[ "${ACTION}" == update_os || "${ACTION}" == update_supervisor || "${ACTION}" == "resolve_suggestion" ]]; then
        SUGGESTION=$(find_restart_suggestion)
    fi

    if [[ -n "${SUGGESTION}" && "${SUGGESTION}" != "null" ]]; then
        S_UUID=$(echo "${SUGGESTION}" | jq -r '.uuid')
        S_CONTEXT=$(echo "${SUGGESTION}" | jq -r '.context // "system"')
        RESTART_DATA=$(echo "${SUGGESTION}" | jq -c --argjson missing "$(echo "${EXEC_DATA}" | jq -c '.missing_entities // []')" \
            '{suggestion_uuid: .uuid, suggestion_type: .type, suggestion_context: .context, missing_entities: $missing}')
        report_result "${COMMAND_ID}" "restart_required" "Herstart (${S_CONTEXT}) nodig om door te gaan.${EXEC_MESSAGE}" "${RESTART_DATA}"
    elif [[ "${EXEC_SUCCESS}" == "true" ]]; then
        report_result "${COMMAND_ID}" "done" "${EXEC_MESSAGE}" "${EXEC_DATA}"
    else
        report_result "${COMMAND_ID}" "error" "${EXEC_MESSAGE}" "${EXEC_DATA}"
    fi
done
