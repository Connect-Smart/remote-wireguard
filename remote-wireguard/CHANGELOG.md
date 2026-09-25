## 1.5.44

- `ha-commands`: minder valse alarmen bij de connectiviteitscheck na een update. `notify.*` en `device_tracker.*` worden nu overgeslagen (hun beschikbaarheid hangt af van of een telefoon/app bereikbaar is, niet van Core's gezondheid), en een gevonden regressie wordt na 90 seconden nog eens herbevestigd zodat apparaten die vlak na de herstart alsnog reconnecten (bv. zigbee/mesh) niet als "niet meer beschikbaar" worden gemeld. De resulterende melding is ook voorzichtiger geformuleerd ("kan los staan van deze update").

## 1.5.43

- `ha-status`: haalt nu ook alle overige `update.*`-entiteiten uit Home Assistant zelf op (HACS, integraties, apparaten zoals ESPHome, enz.) via de Core API en stuurt die mee als `updates.other` — Core/OS/Supervisor/add-on-updates worden uitgesloten om dubbele meldingen te voorkomen.
- `ha-commands`: nieuwe actie `update_entity` — roept `update.install` aan via de Core-service-API voor een losse update-entiteit en wacht (met heartbeats) tot de entiteit niet meer 'update beschikbaar' aangeeft, in plaats van de service-aanroep zelf als bewijs van succes te nemen.
- Portal: HA Status-modal toont deze overige updates nu ook met een "Update nu"-knop.

## 1.5.42

- `ha-commands`: een update (core/os/supervisor/add-on) wordt niet meer als geslaagd beschouwd op basis van alleen Supervisor's initiële "ok" bij de update-aanroep. Na afloop wordt de info van het bijgewerkte onderdeel opnieuw opgehaald (`verify_update_applied`): staat er nog een update open, of draait een bijgewerkte add-on niet gewoon weer ("started"), dan wordt het commando alsnog als mislukt teruggemeld met een duidelijke reden i.p.v. een vals-positieve "succesvol uitgevoerd".

## 1.5.41

- `ha-status`: rapporteert nu ook de eigen `backup_enabled`-configuratie mee in de status-push, zodat de portal automatisch weet of backups voor deze client bewust uitstaan i.p.v. dat een admin dit los moet instellen (en uit sync kan raken).
- `ha-commands`: nieuwe actie `create_backup` — roept het bestaande `ha-backup/create_backup.sh` rechtstreeks aan (backup aanmaken, uploaden naar de portal, oude backups opruimen), zodat een admin vanuit de portal met één klik een handmatige backup kan starten. Inclusief heartbeats en de schijfruimte-check vooraf.
- Portal: uploads worden nu volledig doorgelezen en geweigerd als het tar-archief onvolledig/corrupt is (bv. door een afgebroken netwerkverbinding) — voorkomt dat een kapotte upload een goede oudere backup vervangt vóórdat de retentie-opruiming die alsnog weggooit.

## 1.5.40

- `ha-commands`: stuurt tijdens een lange actie (update of `resolve_suggestion`) elke 20 seconden een heartbeat naar de portal (`POST /api/ha-commands/<id>/heartbeat`), zodat "Bezig" voortgang toont i.p.v. stil te blijven staan.
- Portal: een `running`-commando zonder heartbeat gedurende 5 minuten wordt automatisch als mislukt gemarkeerd (was 50 minuten, alleen gebaseerd op het oppakken van het commando) — dit lost het scenario op waarbij een host-herstart deze container onderbreekt vóórdat hij het eindresultaat kon terugmelden, en de melding daardoor eeuwig op "Bezig" bleef staan.
- Portal: nieuwe knop "Afhandelen" om een vastgelopen commando handmatig als afgehandeld te markeren.

## 1.5.39

- `ha-commands`: schijfruimte-check vooraf via `GET /host/info` — een update wordt geweigerd (en gemeld als mislukt) als er minder dan `advanced.min_disk_free_gb` (standaard 2GB) vrije schijfruimte is.
- `ha-commands`: nieuwe actie `resolve_suggestion` — als Supervisor na een update aangeeft dat een herstart nodig is (resolution center suggestie van het type reboot/restart), meldt het add-on dit als aparte status `restart_required` terug, inclusief de suggestie-uuid. De portal kan die herstart vervolgens met één klik alsnog laten uitvoeren.
- `ha-commands`: connectiviteitscheck na elke update/herstart — devices/entiteiten die vóór de actie beschikbaar waren en dat erna niet meer zijn, worden vergeleken via de Core API (`/core/api/states`) en gemeld in het resultaat.
- `ha-commands`: commando's die te lang op 'running' blijven staan (add-on nooit teruggekomen) worden nu door de portal als mislukt gemarkeerd na een time-out, zodat een stille storing altijd als melding verschijnt.

## 1.5.35

- Nieuwe `ha-commands` service toegevoegd: pollt elke 30 seconden `GET /api/ha-commands/pull` op de portal voor openstaande update-commando's.
- Ondersteunde acties: `update_core`, `update_os`, `update_supervisor`, `update_addon` — uitgevoerd via de Supervisor API (hetzelfde mechanisme als het `ha` CLI commando).
- Resultaat wordt teruggemeld via `POST /api/ha-commands/<id>/result`, zodat een admin in de portal Home Assistant-updates op afstand kan starten en de voortgang kan volgen.

## 1.5.15

- Foutmeldingen bij mislukte backup worden nu als notificatie naar de portal gestuurd via `POST /api/notifications/push` (levels: `error`, `warning`, `info`).
- Succesvolle uploads sturen ook een bevestigingsnotificatie naar de portal.

## 1.5.11

- Backup upload gebruikt nu de ingestelde `portal_url` in plaats van het hardgecodeerde `10.8.0.1`.
- Logregel gecorrigeerd zodat de daadwerkelijke upload-URL wordt getoond.

## 1.5.10

- Automatische HA backup toegevoegd: maakt periodiek een volledige backup aan via de Supervisor API en uploadt deze naar de portal (`POST /api/backup/upload`).
- Portal stuurt de backup door naar Google Storage.
- Nieuwe configuratie-opties: `advanced.backup_enabled`, `advanced.backup_interval_hours`, `advanced.backup_retain`.
- `backup` map gemount zodat het add-on toegang heeft tot backup bestanden.
- Service herstart niet meer elke 5 minuten bij een mislukte backup upload.
- `portal_url` werd niet correct opgepikt uit `advanced.portal_url`; dit is gecorrigeerd in `config.sh`.
- HA status monitor rapporteert nu ook repairs/issues en unhealthy-meldingen vanuit de Supervisor resolution API.

## 1.4.12

- `enrollment_token` is nu verplicht in het schema zodat de UI het veld afdwingt.
- Standaardwaarden teruggezet voor `portal_url` (`https://remote.connect-smart.nl`) en `verify_ssl`.

## 1.4.11

- Vertaalteksten voor `portal_url` gecorrigeerd naar de juiste standaard-URL `https://remote.connect-smart.nl`.
- Standaardwaarden voor `portal_url` en `verify_ssl` verwijderd uit `options` zodat ze optioneel blijven.

## 1.4.1

- Standaard `portal_url` ingesteld op `https://remote.connect-smart.nl`.
- Vertalingen toegevoegd (NL/EN) voor alle configuratievelden.

## 1.4.0

- `log_level` verwijderd uit de standaard `options`, maar blijft beschikbaar als optionele schema-instelling.

## 1.3.9

- `10-log-level.sh` krijgt uitvoerrechten; Dockerfile zet deze permissies zodat log-level configuratie wordt toegepast.

## 1.3.8

- Toegevoegde `log_level`-optie waarmee het add-on logniveau rechtstreeks via de configuratie kan worden ingesteld.
- Statusservice wacht nu net zo lang als `monitor_interval` voordat hij `wg show cswg0` uitvoert, zodat logging gesynchroniseerd blijft met de watchdog.

## 1.3.7

- Statusservice vraagt nu expliciet `wg show cswg0` op zodat de logging alleen de add-oninterface toont en geen andere WireGuard-configuraties uitleest.

## 1.3.6

- WireGuard-interface hernoemd naar `cswg0` met bijbehorend configuratiebestand zodat bestaande `wg0`-configuraties op het systeem niet worden overschreven.
- Documentatie bijgewerkt om de nieuwe bestandsnaam en interface duidelijk te maken.

## 1.3.5

- Watchdog telt nu mislukte pings; na 5 opeenvolgende fouten stopt de add-on zichzelf zodat de Home Assistant Supervisor automatisch een herstart afhandelt.
- Documentatie verduidelijkt dit gedrag.

## 1.3.4

- `monitor_target` en `monitor_interval` zitten nu onder *Ongebruikte optionele configuratieopties tonen* zodat standaardgebruikers ze niet zien, maar ze wel eenvoudig bereikbaar blijven.

## 1.3.3

- `monitor_target` en `monitor_interval` zijn nu verborgen opties zodat de standaardwaarden intact blijven terwijl geavanceerde gebruikers ze nog via `options.json` kunnen tweaken.
- Documentatie verduidelijkt hoe deze instellingen nu worden beheerd.

## 1.3.2

- Watchdog staat nu altijd aan; de optie `monitor_enabled` is verwijderd om onbedoeld uitschakelen te voorkomen.
- Configuratie bevat alleen nog het doel en interval, documentatie bijgewerkt om dit te weerspiegelen.

## 1.3.1

- Beschrijving en metadata geüpdatet zodat de add-on duidelijk als Connect-Smart Remote Portal-client wordt aangeduid.
- Nieuwe Connect-Smart logo- en icoonbestanden opgenomen voor de Home Assistant store.

## 1.3.0

- Watchdog haalt nu bij connectiviteitsverlies de WireGuard-configuratie opnieuw op bij de portal en past wijzigingen live toe via `wg syncconf`, zonder de interface te herstarten.
- Documentatie uitgewerkt voor de benodigde `trusted_proxies`-instelling in Home Assistant.

## 1.2.3

- Watchdog stuurt nu pings via de WireGuard-interface, voert direct na een herstart meerdere probes uit en wacht kort voordat de volgende controle plaatsvindt zodat de tunnel opnieuw verkeer kan verzenden.

## 1.2.2

- Watchdog herstart nu eerst de `wireguard_client` s6-service; alleen wanneer dat faalt wordt teruggevallen op `wg-quick` zodat een volledige tunnel-reset wordt afgedwongen.

## 1.2.1

- WireGuard-watchdog gebruikt nu dezelfde userspace-implementatie als de hoofdservice, zodat een herstart ook daadwerkelijk de tunnel opnieuw kan opbouwen.

## 1.2.0

- WireGuard-watchdog toegevoegd die standaard `10.8.0.1` elke 30 seconden pingt en de tunnel automatisch herstart wanneer het doel onbereikbaar is.
- Nieuwe configuratie-opties (`monitor_enabled`, `monitor_target`, `monitor_interval`) om de watchdog te sturen.

## 1.1.3

- Voegt automatisch `PersistentKeepalive = 25` toe aan de WireGuard-peerconfiguratie zodat de client na een serverherstart vanzelf opnieuw verbindt.

## 1.1.0

- Ondersteuning voor Remote Portal installatietokens toegevoegd.
- WireGuard-configuratie wordt nu automatisch opgehaald via het publieke enrollment-endpoint.
- Nieuwe configuratie-opties: `portal_url`, `enrollment_token` en `verify_ssl`.
