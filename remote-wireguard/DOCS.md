# Home Assistant Add-on: WireGuard 

[WireGuard®][wireguard] is an extremely simple yet fast and modern VPN that
utilizes state-of-the-art cryptography. It aims to be faster, simpler, leaner,
and more useful than IPsec, while avoiding the massive headache.

It intends to be considerably more performant than OpenVPN. WireGuard is
designed as a general-purpose VPN for running on embedded interfaces and
supercomputers alike, fit for many different circumstances.

Initially released for the Linux kernel, it is now cross-platform
including via an Connect-Smart add-on!

## Configuratie

Deze add-on is gebouwd rondom [Remote Portal](https://github.com/Connect-Smart/remote_portal), maar kan door elke dienst worden gebruikt die hetzelfde installatietoken-eindpunt aanbiedt.

1. Maak in Remote Portal een client aan en kopieer het **installatietoken**.
2. Open de add-on configuratie in Home Assistant en vul de velden in:
   - `portal_url`: Basis-URL van de portal (bijv. `https://vpn.remote.connect-smart.nl`).
   - `enrollment_token`: Het installatietoken dat je uit de portal kopieerde.
   - `verify_ssl`: Laat standaard op `true`. Zet op `false` wanneer je (tijdelijk) met een zelfondertekend certificaat test.
3. Start of herstart de add-on. Bij elke start wordt de WireGuard-configuratie opgehaald via:

   ```
   GET <portal_url>/api/public/clients/<enrollment_token>/wireguard-config
   ```

   De configuratie wordt opgeslagen als `/etc/wireguard/wg0.conf`. Bij wijzigingen in de portal wordt het bestand automatisch bijgewerkt.

### Tips

- Verifieer na de eerste start in het logboek dat de juiste clientnaam en externe URL worden gemeld.
- Wil je een token intrekken? Roteer het token in Remote Portal en werk het nieuwe token bij in de add-on.
- Wanneer `verify_ssl` op `false` staat, worden certificaten niet gecontroleerd. Gebruik dit alleen tijdens testen of met een vertrouwde portal.

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
