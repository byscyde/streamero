# Streamero — postavljanje (hrvatski)

Streamero je administratorska aplikacija za tvoj streamero.net: Jellyfin, Jellyseerr/Overseerr, Sonarr, Radarr,
Lidarr, Prowlarr i Bazarr. Aplikacija se spaja **izravno** na svaki servis preko njegovog API-ja — na serveru ne
treba instalirati ništa novo.

## 1. Instalacija na iPhone

1. Preuzmi `STREAMERO.ipa` iz [Releases](https://github.com/mmzlopasa/streamero/releases).
2. Feather → uvezi IPA → potpiši svojim certifikatom → instaliraj.
3. Otvori Streamero. Prikazat će se popis svih servisa s već upisanim adresama.

## 2. Adrese (zadane, mogu se mijenjati)

| Servis | Adresa |
| --- | --- |
| Jellyfin | `https://streamero.net` |
| Jellyseerr | `https://req.streamero.net` |
| Radarr | `https://rad.streamero.net` |
| Sonarr | `https://son.streamero.net` |
| Lidarr | `https://lid.streamero.net` |
| Prowlarr | `https://prow.streamero.net` |
| Bazarr | `https://baz.streamero.net` |

Ako je neki servis na drugoj poddomeni, samo promijeni adresu u aplikaciji (Settings → Services → servis → Address).
Drugi Seerr (npr. Overseerr) ili drugi Radarr (npr. 4K): Settings → Services → **Add another …**.
Ako servis koristi URL base (npr. `https://streamero.net/sonarr`), upiši adresu zajedno s njim.

## 3. API ključevi — gdje ih naći

| Servis | Gdje je API ključ |
| --- | --- |
| Sonarr, Radarr, Lidarr, Prowlarr | Web sučelje → **Settings → General → Security → API Key** |
| Bazarr | **Settings → General → Security → API Key** |
| Jellyseerr / Overseerr | **Settings → General → API Key** |
| Jellyfin | **Dashboard → API Keys → +** (naziv npr. "Streamero"), *ili* u aplikaciji upiši korisničko ime i lozinku administratora i stisni **Sign in** |

U aplikaciji: dodirni servis → zalijepi ključ u **API key** → **Test connection** (mora pisati *Connected* i
verziju) → **Save**.

Ključevi se spremaju samo na iPhoneu (Keychain) i šalju samo tvojim serverima.

## 4. Što aplikacija radi

- **Dashboard** — stanje i verzija svakog servisa, upozorenja (health), tko trenutno gleda, zahtjevi na čekanju,
  preuzimanja, diskovi, što izlazi idućih 7 dana. Osvježava se svakih 30 s.
- **Requests** — odobri/odbij/obriši zahtjeve (povlačenje udesno/ulijevo), traži i zatraži nove filmove i serije,
  prijavljeni problemi (Issues).
- **Library** — filmovi (Radarr), serije (Sonarr), glazba (Lidarr): pretraga, praćenje (monitor), traženje
  datoteka, brisanje, dodavanje novog naslova (+).
- **Activity** — zajednički red preuzimanja (uklanjanje i blocklist), kalendar, što nedostaje (Wanted) s
  pretragom, povijest.
- **More → Jellyfin** — aktivni streamovi (pauza, stop, poruka gledatelju), skeniranje knjižnica, korisnici
  (novi, brisanje, isključi/uključi, admin, nova lozinka), zakazani zadaci, dnevnik, restart/gašenje servera.
- **More → Indexers** — Prowlarr indexeri (status, uključi/isključi, test), ručna pretraga i slanje u download klijent.
- **More → Subtitles** — Bazarr titlovi koji nedostaju (preuzimanje po jeziku jednim dodirom), povijest, provideri, zadaci.
- **Settings** — servisi, zaključavanje s Face ID-om, verzija.

## 5. Ako nešto ne radi

- **"The API key or login was rejected"** — krivi ključ ili je servis iza dodatne prijave (Authelia, Cloudflare
  Access, basic auth na reverse proxyju). Aplikacija šalje samo API ključ; za taj servis na proxyju dopusti
  zahtjeve s API ključem (npr. iznimka za `/api/`) ili koristi lokalnu adresu.
- **"Not found (404)"** — kriva adresa ili nedostaje URL base (npr. `/sonarr`).
- **Lokalna adresa** (`http://192.168.x.x:8989`) — radi kad je iPhone na kućnoj mreži; iOS će pitati za dozvolu
  *Local Network*.
- **Jellyfin "is not a Jellyfin administrator"** — prijavi se korisnikom koji ima administratorske ovlasti.
