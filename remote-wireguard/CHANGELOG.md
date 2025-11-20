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

- Watchdog stuurt nu pings via `wg0`, voert direct na een herstart meerdere probes uit en wacht kort voordat de volgende controle plaatsvindt zodat de tunnel opnieuw verkeer kan verzenden.

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
