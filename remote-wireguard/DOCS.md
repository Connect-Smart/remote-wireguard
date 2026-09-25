# Home Assistant Add-on: Connect-Smart WireGuard Client

[WireGuard®][wireguard] is an extremely simple yet fast and modern VPN that
utilizes state-of-the-art cryptography. It aims to be faster, simpler, leaner,
and more useful than IPsec, while avoiding the massive headache.

It intends to be considerably more performant than OpenVPN. WireGuard is
designed as a general-purpose VPN for running on embedded interfaces and
supercomputers alike, fit for many different circumstances.

Initially released for the Linux kernel, it is now cross-platform and the Connect-Smart build wraps it in a branded add-on that talks directly to the Connect-Smart Remote Portal.

## Configuratie

Deze add-on is gebouwd rondom [Remote Portal](https://github.com/Connect-Smart/remote_portal), maar kan door elke dienst worden gebruikt die hetzelfde installatietoken-eindpunt aanbiedt.

1. Maak in Remote Portal een client aan en kopieer het **installatietoken**.
2. Open de add-on configuratie in Home Assistant en vul de velden in:
   - `portal_url`: Basis-URL van de portal (bijv. `https://vpn.remote.connect-smart.nl`).
   - `enrollment_token`: Het installatietoken dat je uit de portal kopieerde.
   - `verify_ssl`: Laat standaard op `true`. Zet op `false` wanneer je (tijdelijk) met een zelfondertekend certificaat test.
   - `log_level`: Stel het gewenste logniveau in (`trace`, `debug`, `info`, `notice`, `warning`, `error`, `critical`).
3. Start of herstart de add-on. Bij elke start wordt de WireGuard-configuratie opgehaald via:

   ```
   GET <portal_url>/api/public/clients/<enrollment_token>/wireguard-config
   ```

   De configuratie wordt opgeslagen als `/etc/wireguard/cswg0.conf`. Bij wijzigingen in de portal wordt het bestand automatisch bijgewerkt.

### Home Assistant `configuration.yaml`

Voeg het WireGuard-gatewayadres toe aan de trusted proxies zodat Home Assistant verkeer via de tunnel vertrouwt:

```yaml
http:
  use_x_forwarded_for: true
  trusted_proxies:
    - 10.8.0.1
```

### Automatische backup

De add-on kan periodiek een volledige Home Assistant backup aanmaken en uploaden naar de Remote Portal, die de backup doorstuurt naar Google Storage.

Standaard is de backup ingeschakeld met een interval van 24 uur. Dit is instelbaar via de geavanceerde configuratie:

| Optie | Standaard | Beschrijving |
|---|---|---|
| `advanced.backup_enabled` | `true` | Backup aan/uit zetten |
| `advanced.backup_interval_hours` | `24` | Interval tussen backups in uren |
| `advanced.backup_retain` | `3` | Aantal lokale backups bewaren |

Bij onvoldoende schijfruimte of een mislukte upload verstuurt de add-on automatisch een foutmelding naar de portal.

### Updates op afstand starten

Zodra `hassio_role: manager` actief is (standaard voor deze add-on), pollt de add-on elke 30 seconden
de portal op openstaande update-opdrachten. Een beheerder kan in Remote Portal, vanuit de HA Status-weergave
van een client, met één klik een update starten voor:

- Home Assistant Core
- Home Assistant OS
- Supervisor
- een individuele add-on

De update wordt uitgevoerd via de Supervisor API (hetzelfde mechanisme dat het `ha` CLI commando
intern gebruikt) en het resultaat verschijnt na afloop als notificatie bij de client in de portal.

Ingebouwde veiligheidschecks rond een update:

- **Schijfruimte vooraf**: de update wordt geweigerd (en gemeld als mislukt) als er minder dan
  `advanced.min_disk_free_gb` (standaard 2GB) vrije schijfruimte op de host is.
- **Herstart vereist**: geeft Supervisor na de update aan dat een herstart nodig is, dan meldt de
  add-on dit als aparte status "Herstart vereist" met een knop in de portal om die herstart
  alsnog direct uit te voeren.
- **Connectiviteitscheck**: na de update (en na een eventuele herstart) wordt gecontroleerd of alle
  devices/entiteiten die ervoor beschikbaar waren, dat erna nog steeds zijn. Zo niet, dan verschijnt
  dat in de melding bij de client.
- **Voortgang (heartbeats)**: tijdens een lange actie stuurt de add-on elke 20 seconden een
  tussentijds signaal naar de portal, zodat "Bezig" niet stil blijft staan.
- **Time-out**: komt er 5 minuten geen heartbeat of resultaat binnen (bv. omdat een host-herstart
  deze container zelf onderbreekt vóórdat hij kon terugmelden), dan markeert de portal het commando
  automatisch als mislukt zodat een stille storing nooit onopgemerkt blijft. Weet je zeker dat de
  actie eigenlijk wél gelukt is, dan kan een vastgelopen melding ook met één klik handmatig als
  "Afgehandeld" worden gemarkeerd in de portal.

### Tips

- Verifieer na de eerste start in het logboek dat de juiste clientnaam en externe URL worden gemeld.
- Wil je een token intrekken? Roteer het token in Remote Portal en werk het nieuwe token bij in de add-on.
- Wanneer `verify_ssl` op `false` staat, worden certificaten niet gecontroleerd. Gebruik dit alleen tijdens testen of met een vertrouwde portal.
- Om verbindingen ook na een serverherstart actief te houden, forceert de add-on `PersistentKeepalive = 25` voor elke WireGuard-peer.
- De watchdog pingt standaard `10.8.0.1` via de add-on interface `cswg0`. Als het doel onbereikbaar is, wordt de WireGuard-config opnieuw opgehaald bij de portal en live toegepast zonder de interface te herstarten. Na 5 mislukte checks op rij stopt de add-on bewust zodat de Home Assistant Supervisor hem opnieuw kan starten. Geavanceerde gebruikers kunnen doel en interval aanpassen via `Ongebruikte optionele configuratieopties tonen` en daar de verborgen opties `monitor_target` of `monitor_interval` invullen.

## License

MIT License

Copyright (c) 2024-2025 Jos Rothman

Copyright (c) 2020-2024 Fabio Mauro

Copyright (c) 2019-2020 Franck Nijhof

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.
