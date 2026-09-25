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
#    de update beschikbaar waren, zijn dat na de update niet meer? notify.* en
#    device_tracker.* worden overgeslagen (telefoon/netwerk-afhankelijk, geen
#    signaal over Core's gezondheid) en een gevonden regressie wordt na 90s nog
#    een keer herbevestigd, zodat apparaten die vlak na de herstart reconnecten
#    (bv. zigbee) niet als vals-positief worden gemeld.
#  - Verificatie dat een update ook echt is toegepast: Supervisor's "ok" bij
#    de update-aanroep betekent alleen dat die aanroep gelukt is, niet dat de
#    update ook echt is doorgevoerd. Na afloop wordt de info van het bijgewerkte
#    onderdeel opnieuw opgehaald; staat er nog een update open, of (bij een
#    add-on) draait die niet gewoon weer, dan wordt de actie alsnog als
#    mislukt teruggemeld i.p.v. blind op het eerste "ok" te vertrouwen.
#  - Heartbeats tijdens een lange actie: de portal ziet zo tussentijds voortgang
#    i.p.v. alleen "Bezig" zonder updates, en beschouwt het commando als
#    vastgelopen (i.p.v. eeuwig 'Bezig') zodra de heartbeats stoppen — bv. omdat
#    een host-herstart deze container zelf onderbreekt vóórdat hij het
#    eindresultaat kon terugmelden.
#  - Zelfupdate-detectie: is de update_addon-slug die van dit add-on zelf, dan
#    vervangt Supervisor deze container als onderdeel van de update — die kan dus
#    per definitie nooit meer normaal terugmelden. Een marker in /data (overleeft
#    een add-on-update) zorgt dat de nieuwe container dit commando bij zijn eerste
#    poll alsnog als voltooid meldt, i.p.v. dat de portal na 5 minuten een
#    vals-negatieve time-out toont voor een update die feitelijk gewoon lukte.
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
SELF_UPDATE_MARKER="/data/ha_commands_self_update.json"

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

# Geen bashio::addon.slug beschikbaar; 'self' is Supervisor's eigen conventie om naar
# de aanroepende add-on te verwijzen (zie ook bashio::addon.update, dat intern hetzelfde
# doet), dus haal de eigen info rechtstreeks op via /addons/self/info.
SELF_ADDON_INFO=$(curl -s -H "Authorization: Bearer ${SUPERVISOR_TOKEN}" "${SUPERVISOR_API}/addons/self/info" 2>/dev/null)
ADDON_SLUG=$(echo "${SELF_ADDON_INFO}" | jq -r '.data.slug // empty')

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
# notify.* en device_tracker.* worden bewust overgeslagen: die weerspiegelen of een
# telefoon/app bereikbaar is (netwerk/GPS-afhankelijk), niet of Home Assistant Core
# zelf gezond is — anders leidt elke offline telefoon tot een vals-positieve melding.
fetch_unavailable_entities() {
    curl -s -H "Authorization: Bearer ${SUPERVISOR_TOKEN}" "${SUPERVISOR_API}/core/api/states" 2>/dev/null \
        | jq -r '[
            .[]?
            | select(.state == "unavailable" or .state == "unknown")
            | select(((.entity_id | startswith("notify.")) or (.entity_id | startswith("device_tracker."))) | not)
            | .entity_id
          ] | sort | .[]' 2>/dev/null
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

# Voert een backup uit door het bestaande ha-backup script rechtstreeks aan te
# roepen — dezelfde logica als de geplande backup (aanmaken, uploaden naar de
# portal, oude backups opruimen), nu op verzoek vanuit de portal. Draait op de
# achtergrond zodat we ondertussen heartbeats kunnen sturen.
execute_backup_now() {
    local command_id="${1}"
    local script="/etc/services.d/ha-backup/create_backup.sh"

    if [[ ! -x "${script}" ]]; then
        EXEC_MESSAGE="Backup-script niet gevonden of niet uitvoerbaar (${script})"
        return 1
    fi

    "${script}" &
    local backup_pid=$! elapsed=0
    while kill -0 "${backup_pid}" 2>/dev/null; do
        sleep "${HEARTBEAT_INTERVAL}"
        elapsed=$(( elapsed + HEARTBEAT_INTERVAL ))
        if kill -0 "${backup_pid}" 2>/dev/null; then
            report_heartbeat "${command_id}" "Bezig met backup aanmaken en uploaden... (${elapsed}s)"
        fi
    done
    wait "${backup_pid}"
    local exit_code=$?

    if [[ ${exit_code} -eq 0 ]]; then
        EXEC_MESSAGE="Backup aangemaakt en geüpload naar de portal"
        return 0
    fi

    EXEC_MESSAGE="Backup-script eindigde met foutcode ${exit_code} — zie add-on log en meldingen voor details"
    return 1
}

# Werkt een losse Home Assistant update-entiteit bij (HACS, een integratie, een apparaat
# zoals ESPHome, enz.) via de Core-service update.install. Die service-aanroep keert vaak
# snel terug terwijl de daadwerkelijke download/installatie op de achtergrond in Core
# doorloopt, dus wordt hier gewacht (met heartbeats) tot de entiteit zelf niet meer 'on'
# (= update beschikbaar) aangeeft, in plaats van de service-aanroep zelf als bewijs van
# succes te nemen.
execute_entity_update() {
    local command_id="${1}" entity_id="${2}"

    if [[ -z "${entity_id}" ]]; then
        EXEC_MESSAGE="Geen entity_id meegegeven"
        return 1
    fi

    bashio::log.info "HA Commands: update.install aanroepen voor ${entity_id}..."

    local call_response
    call_response=$(curl -s --max-time 60 \
        -H "Authorization: Bearer ${SUPERVISOR_TOKEN}" \
        -H "Content-Type: application/json" \
        -X POST "${SUPERVISOR_API}/core/api/services/update/install" \
        -d "$(jq -n --arg entity_id "${entity_id}" '{entity_id: $entity_id}')" 2>/dev/null)

    if [[ -z "${call_response}" ]]; then
        EXEC_MESSAGE="Geen reactie van Home Assistant Core bij het starten van de update"
        return 1
    fi

    local waited=0 timeout=1800 state installed latest
    while (( waited < timeout )); do
        local entity_info
        entity_info=$(curl -s -H "Authorization: Bearer ${SUPERVISOR_TOKEN}" \
            "${SUPERVISOR_API}/core/api/states/${entity_id}" 2>/dev/null)
        state=$(echo "${entity_info}" | jq -r '.state // "unknown"')
        installed=$(echo "${entity_info}" | jq -r '.attributes.installed_version // "onbekend"')
        latest=$(echo "${entity_info}" | jq -r '.attributes.latest_version // "onbekend"')

        if [[ "${state}" != "on" ]]; then
            EXEC_MESSAGE="${entity_id} bijgewerkt naar versie ${installed}"
            return 0
        fi

        report_heartbeat "${command_id}" "Bezig met bijwerken van ${entity_id}... (${waited}s)"
        sleep "${HEARTBEAT_INTERVAL}"
        waited=$(( waited + HEARTBEAT_INTERVAL ))
    done

    EXEC_MESSAGE="Time-out bij wachten op update van ${entity_id} (nog op versie ${installed}, nieuwste is ${latest})"
    return 1
}

# Voer één commando uit via de Supervisor API. Retourneert 0 bij succes.
# Zet EXEC_MESSAGE met een omschrijving. Draait de aanroep op de achtergrond en
# stuurt onderweg heartbeats, zodat een langdurige actie (bv. een update) niet
# stil op "Bezig" blijft staan zonder voortgang.
execute_command() {
    local command_id="${1}" action="${2}" slug="${3}" uuid="${4}" entity_id="${5}" endpoint=""

    if [[ "${action}" == "create_backup" ]]; then
        execute_backup_now "${command_id}"
        return $?
    fi

    if [[ "${action}" == "update_entity" ]]; then
        execute_entity_update "${command_id}" "${entity_id}"
        return $?
    fi

    case "${action}" in
        update_core)       endpoint="${SUPERVISOR_API}/core/update" ;;
        update_os)         endpoint="${SUPERVISOR_API}/os/update" ;;
        update_supervisor) endpoint="${SUPERVISOR_API}/supervisor/update" ;;
        update_addon)
            if [[ -z "${slug}" ]]; then
                EXEC_MESSAGE="Geen add-on slug meegegeven"
                return 1
            fi
            if [[ -n "${ADDON_SLUG}" && "${slug}" == "${ADDON_SLUG}" ]]; then
                bashio::log.info "HA Commands: dit is een update van dit add-on zelf — marker wegschrijven, deze container wordt vervangen"
                jq -n --arg id "${command_id}" '{command_id: $id}' > "${SELF_UPDATE_MARKER}"
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
    # We zijn nog in leven na de aanroep, dus dit was geen zelfupdate die de
    # container verving (of de aanroep sneuvelde al vóór die vervanging) —
    # de marker is dan niet nodig, dit commando krijgt gewoon een normaal
    # resultaat via de rest van deze functie.
    rm -f "${SELF_UPDATE_MARKER}"

    if [[ -z "${response}" ]]; then
        EXEC_MESSAGE="Geen reactie van Supervisor API"
        return 1
    fi

    result=$(echo "${response}" | jq -r '.result // empty')

    if [[ "${result}" == "ok" ]]; then
        if [[ "${action}" == update_* ]]; then
            # Supervisor's "ok" betekent alleen dat de aanroep zelf gelukt is, niet dat de
            # update ook echt is toegepast. Vraag daarom de info opnieuw op en bevestig dat
            # er geen update meer openstaat (en dat een add-on ook echt weer draait) vóórdat
            # we dit als geslaagd terugmelden.
            sleep 5
            verify_update_applied "${action}" "${slug}"
            return $?
        fi
        EXEC_MESSAGE="${action} succesvol uitgevoerd"
        return 0
    fi

    EXEC_MESSAGE=$(echo "${response}" | jq -r '.message // "onbekende fout"')
    return 1
}

# Controleert na een gemelde geslaagde update of die ook echt is toegepast:
# vraagt de info van het bijgewerkte onderdeel opnieuw op bij Supervisor en
# faalt de actie alsnog als er nog steeds een update openstaat, of — bij een
# add-on — als deze niet gewoon weer draait. Zet EXEC_MESSAGE met de bevinding.
verify_update_applied() {
    local action="${1}" slug="${2}" info_endpoint=""

    case "${action}" in
        update_core)       info_endpoint="${SUPERVISOR_API}/core/info" ;;
        update_os)         info_endpoint="${SUPERVISOR_API}/os/info" ;;
        update_supervisor) info_endpoint="${SUPERVISOR_API}/supervisor/info" ;;
        update_addon)      info_endpoint="${SUPERVISOR_API}/addons/${slug}/info" ;;
        *)
            EXEC_MESSAGE="${action} succesvol uitgevoerd"
            return 0
            ;;
    esac

    local info version update_available state
    info=$(curl -s -H "Authorization: Bearer ${SUPERVISOR_TOKEN}" "${info_endpoint}" 2>/dev/null)
    version=$(echo "${info}" | jq -r '.data.version // "onbekend"')
    update_available=$(echo "${info}" | jq -r '.data.update_available // false')

    if [[ "${update_available}" == "true" ]]; then
        EXEC_MESSAGE="Update gemeld als geslaagd, maar Supervisor geeft nog steeds een update aan (huidige versie: ${version}) — controleer handmatig"
        return 1
    fi

    if [[ "${action}" == "update_addon" ]]; then
        state=$(echo "${info}" | jq -r '.data.state // "onbekend"')
        if [[ "${state}" != "started" ]]; then
            EXEC_MESSAGE="Bijgewerkt naar versie ${version}, maar add-on ${slug} staat niet actief (status: ${state}) — controleer handmatig"
            return 1
        fi
        EXEC_MESSAGE="Add-on ${slug} bijgewerkt naar versie ${version} en actief geverifieerd"
        return 0
    fi

    EXEC_MESSAGE="Bijgewerkt naar versie ${version} en geverifieerd (geen update meer openstaand)"
    return 0
}

# Deze acties raken Core (rechtstreeks of via een herstart) en verdienen dus
# zowel een schijfruimte-check vooraf als een connectiviteitscheck achteraf.
# create_backup heeft alleen de schijfruimte-check nodig (geen Core-restart).
needs_disk_check() {
    [[ "${1}" == update_* || "${1}" == "create_backup" ]]
}
needs_connectivity_check() {
    [[ "${1}" == update_* || "${1}" == "resolve_suggestion" ]]
}

# Update dit add-on zichzelf (update_addon op de eigen slug), dan wordt de container
# die het commando uitvoert door Supervisor vervangen vóórdat hij kan terugmelden —
# dat is inherent aan hoe een zelfupdate werkt, geen mislukking. /data overleeft een
# add-on-update (het is de persistente opslag van het add-on zelf), dus een marker
# die we vlak vóór de update-aanroep wegschrijven is er nog als deze nieuwe container
# opstart. Is die er, dan weten we zeker dat de nieuwe (dus bijgewerkte) container
# gezond is gestart en melden we het commando alsnog als voltooid.
if [[ -f "${SELF_UPDATE_MARKER}" ]]; then
    PENDING_SELF_UPDATE_ID=$(jq -r '.command_id // empty' "${SELF_UPDATE_MARKER}" 2>/dev/null)
    rm -f "${SELF_UPDATE_MARKER}"
    if [[ -n "${PENDING_SELF_UPDATE_ID}" ]]; then
        SELF_STILL_UPDATE=$(echo "${SELF_ADDON_INFO}" | jq -r '.data.update_available // false')
        if [[ "${SELF_STILL_UPDATE}" == "true" ]]; then
            bashio::log.warning "HA Commands: terug na update van dit add-on zelf, maar Supervisor geeft nog een update aan (versie ${ADDON_VERSION})"
            report_result "${PENDING_SELF_UPDATE_ID}" "error" "Add-on herstart met versie ${ADDON_VERSION}, maar Supervisor geeft nog steeds een update aan — controleer handmatig"
        else
            bashio::log.info "HA Commands: terug na update van dit add-on zelf, meld commando ${PENDING_SELF_UPDATE_ID} als voltooid (versie ${ADDON_VERSION})"
            report_result "${PENDING_SELF_UPDATE_ID}" "done" "Add-on bijgewerkt naar versie ${ADDON_VERSION} en succesvol herstart"
        fi
    fi
fi

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
    ENTITY_ID=$(echo "${PULL_RESPONSE}" | jq -r '.command.params.entity_id // empty')

    bashio::log.info "HA Commands: commando ${COMMAND_ID} ontvangen: ${ACTION} ${SLUG}${SUGGESTION_UUID}${ENTITY_ID}"

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
    if execute_command "${COMMAND_ID}" "${ACTION}" "${SLUG}" "${SUGGESTION_UUID}" "${ENTITY_ID}"; then
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
            # Herbevestigen na een korte afkoelperiode: apparaten die vlak na de
            # herstart nog aan het reconnecten zijn (bv. zigbee/mesh) willen we niet
            # als 'niet meer beschikbaar' melden als ze binnen deze marge terugkomen.
            sleep 90
            AFTER_UNAVAILABLE_RECHECK=$(fetch_unavailable_entities)
            MISSING=$(comm -12 <(echo "${MISSING}") <(echo "${AFTER_UNAVAILABLE_RECHECK}") | sed '/^$/d')
        fi

        if [[ -n "${MISSING}" ]]; then
            MISSING_COUNT=$(echo "${MISSING}" | grep -c .)
            EXEC_MESSAGE="${EXEC_MESSAGE} — LET OP: ${MISSING_COUNT} device(s)/entiteit(en) niet meer beschikbaar (kan los staan van deze update, bv. bij batterij-/zigbee-apparaten)"
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
