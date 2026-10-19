## 📱 Instalacija na iPhone (Feather)

1. Preuzmi **`STREAMERO.ipa`** ispod (Assets).
2. U Featheru uvezi IPA, potpiši ga svojim certifikatom i instaliraj.
3. Otvori STREAMERO i upiši adresu svog servera (npr. `https://music.tvojadomena.hr`).

Ovo je **nepotpisan** IPA — Feather (ili AltStore/SideStore/Sideloadly) ga potpisuje tvojim certifikatom.
CarPlay i Sign in with Apple rade samo s certifikatom koji ima te Appleove dozvole; sve ostalo
(glazba u pozadini, lock screen, AirPlay, PiP, offline downloadi, prijava emailom) radi s bilo kojim certifikatom.

## 🖥️ Server

Upute korak po korak: [`docs/INSTALACIJA_SERVERA.md`](https://github.com/mmzlopasa/streamero/blob/{{TAG}}/docs/INSTALACIJA_SERVERA.md)

```bash
git clone --branch {{TAG}} https://github.com/mmzlopasa/streamero.git && cd streamero
sudo ./scripts/install-server.sh
```

Minimalni zahtjevi servera: Linux x86_64 ili ARM64, 2 CPU jezgre, 4 GB RAM, Docker; prostor ovisno o glazbi/videu.

---
*English:* download `STREAMERO.ipa`, sign and install it with Feather/AltStore, then enter your server address.
Server setup: `docs/INSTALACIJA_SERVERA.md` / `docs/DEPLOYMENT.md`.
