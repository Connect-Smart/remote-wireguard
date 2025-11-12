## 1.1.3

- Voegt automatisch `PersistentKeepalive = 25` toe aan de WireGuard-peerconfiguratie zodat de client na een serverherstart vanzelf opnieuw verbindt.

## 1.1.0

- Ondersteuning voor Remote Portal installatietokens toegevoegd.
- WireGuard-configuratie wordt nu automatisch opgehaald via het publieke enrollment-endpoint.
- Nieuwe configuratie-opties: `portal_url`, `enrollment_token` en `verify_ssl`.
