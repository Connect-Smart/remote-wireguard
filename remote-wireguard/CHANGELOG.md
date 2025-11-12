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
