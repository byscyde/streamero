# STREAMERO — instalacija na Linux server (korak po korak)

Ove upute te vode od praznog Linux servera do aplikacije na iPhoneu koja svira tvoju glazbu i videe.
Pretpostavka je da **na serveru već imaš nginx**; na kraju su i varijante bez njega.

```
iPhone (STREAMERO app) ──HTTPS──▶ tvoj nginx (443, certbot) ──▶ 127.0.0.1:8088 ──▶ STREAMERO u Dockeru
                                                                                  (API, worker, baza, Redis, S3)
```

STREAMERO se vrti u Docker kontejnerima i **ne dira tvoj postojeći nginx ni druge stranice** — samo mu
dodaje jedan novi virtual host. Baza, Redis i spremište datoteka nisu dostupni izvana.

---

## 1. Što ti treba

| | Minimum | Preporuka |
| --- | --- | --- |
| OS | Ubuntu 22.04/24.04, Debian 12 (ili bilo koji Linux s Dockerom) | Ubuntu 24.04 LTS |
| CPU | 2 jezgre (x86_64 ili ARM64) | 4 jezgre (transkodiranje videa je zahtjevno) |
| RAM | 4 GB | 8 GB |
| Disk | ~3× veličina tvoje kolekcije* | SSD |
| Mreža | javna IP adresa ili port-forward 80/443 | |
| Domena | npr. `music.tvojadomena.hr` | |

\* Original se čuva + verzije za streaming (AAC, ALAC za lossless, HLS za video). Za 50 GB FLAC-a računaj ~120 GB.

**Zašto domena i HTTPS?** iPhone ne dopušta nekriptirane (`http://`) veze prema internetu. Bez domene
aplikacija radi samo u kućnoj mreži (vidi odjeljak 9).

## 2. DNS zapis

Kod svog DNS providera dodaj zapis:

```
Tip: A      Ime: music      Vrijednost: <javna IPv4 adresa servera>
(opcionalno) Tip: AAAA  Ime: music  Vrijednost: <IPv6 adresa>
```

Provjera (s bilo kojeg računala): `ping music.tvojadomena.hr` mora vratiti IP tvog servera.

> **Cloudflare:** možeš ostaviti narančasti oblak (proxy). U Cloudflareu postavi *SSL/TLS → Full (strict)*.
> Za prvo izdavanje certifikata najlakše je privremeno isključiti proxy (sivi oblak), pokrenuti certbot, pa ga
> ponovo uključiti.

## 3. Otvori portove

Ako koristiš `ufw` (instalacijska skripta to radi sama ako je ufw aktivan):

```bash
sudo ufw allow 'Nginx Full'     # 80 i 443
sudo ufw allow OpenSSH
```

Ako je server iza routera, napravi port-forward 80 i 443 na server. Port **8088 ne otvaraj** — on je
namjerno dostupan samo lokalno (127.0.0.1).

## 4. Preuzmi STREAMERO

```bash
sudo apt-get update && sudo apt-get install -y git curl openssl
cd /opt
sudo git clone --branch v1.0.0 https://github.com/mmzlopasa/streamero.git
cd streamero
```

(Kad budeš imao novije izdanje, `scripts/update-server.sh` prebacuje na najnoviji tag — vidi odjeljak 11.)

## 5. Pokreni instalacijsku skriptu

```bash
sudo ./scripts/install-server.sh
```

Skripta pita nekoliko pitanja:

1. **Način pristupa** — odaberi **1) moj postojeći nginx** (skripta sama prepozna da nginx radi i to predloži).
2. **Domena** — npr. `music.tvojadomena.hr`.
3. **Email administratora** — s njim se prijavljuješ u admin panel i u aplikaciju.

Zatim automatski:

- instalira Docker ako ga nema,
- generira `.env` s jakim nasumičnim lozinkama (datoteka je `chmod 600`, nikad se ne prepisuje),
- izgradi i pokrene servise (prvi put 5–10 minuta),
- napravi `/etc/nginx/sites-available/streamero.conf`, uključi ga, provjeri `nginx -t` i napravi reload,
- ponudi instalaciju **certbota** i izda besplatni Let's Encrypt certifikat (s automatskom obnovom),
- na kraju ispiše:

```
✅ STREAMERO radi!
   Adresa za iPhone aplikaciju:  https://music.tvojadomena.hr
   Admin panel (preglednik):     https://music.tvojadomena.hr/admin/
   Admin email:                  ti@primjer.hr
   Admin lozinka:                ********   (spremljeno i u /opt/streamero/streamero-admin-credentials.txt)
```

Bez pitanja (npr. za automatizaciju):

```bash
sudo STREAMERO_DOMAIN=music.tvojadomena.hr STREAMERO_PROXY=host-nginx \
     ADMIN_EMAIL=ti@primjer.hr ./scripts/install-server.sh --yes
```

### Ručna nginx konfiguracija (ako želiš sam)

Ako radije sam uređuješ nginx, gotova konfiguracija je u `infra/host-nginx-streamero.conf`:

```bash
sudo cp infra/host-nginx-streamero.conf /etc/nginx/sites-available/streamero.conf
sudo sed -i 's/music.example.com/music.tvojadomena.hr/g' /etc/nginx/sites-available/streamero.conf
sudo ln -s /etc/nginx/sites-available/streamero.conf /etc/nginx/sites-enabled/
sudo nginx -t && sudo systemctl reload nginx
sudo certbot --nginx -d music.tvojadomena.hr --redirect
```

Ako STREAMERO dodaješ u **postojeći** `server {}` blok (npr. pod putanjom), važno je zadržati ove postavke:

```nginx
client_max_body_size 10m;          # upload ide u komadima od 8 MB
proxy_buffering off;               # streaming audio/videa i Range zahtjevi
proxy_request_buffering off;       # upload bez spremanja na disk nginxa
proxy_read_timeout 600s;
proxy_set_header Host $host;
proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
proxy_set_header X-Forwarded-Proto $scheme;
```

STREAMERO treba **vlastitu (pod)domenu** (npr. `music.…`), ne podputanju poput `tvojadomena.hr/music`,
jer API koristi putanje `/v1/…` i `/admin/`.

## 6. Provjera

```bash
curl https://music.tvojadomena.hr/readyz
# {"status":"ready","checks":{"database":true,"redis":true,"storage":true}}

cd /opt/streamero
sudo docker compose -f docker-compose.yml -f docker-compose.localhost.yml ps
# api (healthy), worker, postgres (healthy), redis (healthy), s3 (healthy), nginx
```

## 7. Dodaj glazbu i videe

1. Otvori `https://music.tvojadomena.hr/admin/` i prijavi se adminskim emailom i lozinkom.
2. **Upload & import** → povuci datoteke (MP3, AAC/M4A, FLAC, WAV, ALAC, AIFF, OGG… i video MP4/MOV/MKV/WebM).
   Možeš ih poslati i stotine odjednom; upload se nastavlja nakon prekida.
3. **Processing queue** prikazuje napredak. Za svaku pjesmu radi se:
   čitanje tagova (izvođač, album, broj pjesme, žanr, godina, naslovnica, tekst), verzije za streaming
   (Data saver / Standard / High, te **Lossless ALAC** ako je original FLAC/WAV/ALAC).
   Za video: HLS kvalitete do izvorne rezolucije, sličica, titlovi, audio-verzija za slušanje u pozadini.
4. **Tracks / Albums / Artists** — ispravi metapodatke, dodaj naslovnice, tekstove pjesama (LRC za sinkronizirane).
5. **Videos → Subtitles** — dodaj SRT/VTT titlove (npr. `hr`, `en`).

**Pjesme koje su već na serveru** (bez uploada preko preglednika):

```bash
cd /opt/streamero
sudo cp docker-compose.import.example.yml docker-compose.import.yml
sudo nano docker-compose.import.yml          # promijeni /srv/glazba u svoju mapu s glazbom
sudo sed -i 's|^IMPORT_ALLOWED_DIRS=.*|IMPORT_ALLOWED_DIRS=/import|' .env
sudo ./scripts/install-server.sh             # ponovno pokretanje primijeni promjenu (postojeći .env ostaje)
```

Zatim u admin panelu → *Import from server* upiši `/import` (cijela mapa) ili `/import/Izvođač/Album`.
Mapa je montirana samo za čitanje — originali ostaju netaknuti.

## 8. Spoji iPhone aplikaciju

1. Instaliraj `STREAMERO.ipa` iz [GitHub Releases](https://github.com/mmzlopasa/streamero/releases) pomoću
   Feathera (uvezi → potpiši svojim certifikatom → instaliraj).
2. Otvori STREAMERO → upiši `music.tvojadomena.hr` (https se dodaje sam) → **Continue**.
3. Prijavi se adminskim računom ili napravi novi račun (*Create an account*).
4. U **Profile → Settings** odaberi kvalitetu za Wi-Fi/mobilne podatke (npr. Lossless na Wi-Fi, Standard na mobilnim).

Ukućani/prijatelji: neka naprave vlastiti račun u aplikaciji. U admin panelu → **Users & roles** možeš
nekome dati ulogu *editor* (smije dodavati glazbu) ili onemogućiti račun.

## 9. Varijante

**Samo kućna mreža (bez domene):** u skripti odaberi opciju 3. Adresa je `http://192.168.x.x:8088`
(skripta je ispiše). iPhone mora biti na istoj Wi-Fi mreži; iOS će pitati za dopuštenje "Local Network" — dopusti.
Izvan kuće se tako ne može spojiti (za to: domena + HTTPS, ili VPN poput Tailscale/WireGuard).

**Server bez nginxa:** opcija 2 — STREAMERO sam pokrene Caddy koji izda HTTPS certifikat (portovi 80/443 moraju biti slobodni).

## 10. Email (preporučeno)

Za potvrdu emaila i "zaboravljenu lozinku" upiši SMTP u `/opt/streamero/.env`, npr. Gmail s App Passwordom:

```
SMTP_URL=smtps://tvoj.racun%40gmail.com:APP_PASSWORD@smtp.gmail.com:465
MAIL_FROM="STREAMERO <tvoj.racun@gmail.com>"
```

(`@` u korisničkom imenu piše se kao `%40`.) Zatim: `sudo ./scripts/install-server.sh` (primijeni promjene).
Bez SMTP-a sve radi, osim slanja tih emailova.

Opcionalno u `.env`: `YOUTUBE_API_KEY=` (YouTube pretraga u aplikaciji), `APPLE_CLIENT_IDS=` (Sign in with Apple).

## 11. Backup i ažuriranje

**Backup** (baza + sve datoteke) — dnevno u 3:30 preko crona:

```bash
sudo crontab -e
30 3 * * * cd /opt/streamero && ./scripts/backup.sh /var/backups/streamero/$(date +\%F) && find /var/backups/streamero -maxdepth 1 -mtime +14 -exec rm -rf {} +
```

Vraćanje: `sudo ./scripts/restore.sh /var/backups/streamero/2026-10-19` (traži potvrdu, zamjenjuje bazu).
Backup čuvaj i na drugom disku/serveru.

**Ažuriranje** na novo izdanje (najprije napravi backup, pa preuzme najnoviji tag i ponovo izgradi):

```bash
cd /opt/streamero && sudo ./scripts/update-server.sh
```

## 12. Korisne naredbe

```bash
cd /opt/streamero
C="docker compose -f docker-compose.yml -f docker-compose.localhost.yml"   # (+ -f docker-compose.import.yml ako ga koristiš)
sudo $C ps                       # stanje servisa
sudo $C logs -f api              # logovi API-ja
sudo $C logs -f worker           # logovi obrade medija (FFmpeg)
sudo $C restart worker           # restart workera
sudo $C down                     # zaustavi (podaci ostaju u Docker volumenima)
sudo $C up -d                    # pokreni
```

Admin panel → **System health** prikazuje bazu, Redis, spremište, broj aktivnih workera i red čekanja.

## 13. Rješavanje problema

| Problem | Rješenje |
| --- | --- |
| Aplikacija: "doesn't look like a STREAMERO server" / "Could not reach" | Otvori `https://domena/healthz` u Safariju na iPhoneu. Ako ne radi: DNS, portovi 80/443, `sudo nginx -t`, `sudo tail /var/log/nginx/error.log` |
| certbot ne uspijeva | DNS još ne pokazuje na server (pričekaj do sat vremena), port 80 je zatvoren, ili je Cloudflare proxy uključen — vidi odjeljak 2 |
| Upload stane / greška 413 | U nginx vhostu mora biti `client_max_body_size 10m;` |
| Pjesma se ne može premotavati / video zapinje | U vhostu moraju biti `proxy_buffering off;` i `proxy_request_buffering off;` |
| Posao (job) "failed" | Admin → Processing queue → otvori posao → log pokazuje FFmpeg grešku; *Retry* nakon popravka. Oštećene datoteke se trajno odbijaju |
| Video se sporo obrađuje | Povećaj u `.env`: `WORKER_CPUS=4`, `WORKER_MEMORY=4g`, `FFMPEG_THREADS=4`, pa ponovo pokreni skriptu |
| `api` nije healthy | `sudo $C logs api` — najčešće pogrešna vrijednost u `.env` (poruka točno kaže koja) |
| Zaboravio si admin lozinku | `cat /opt/streamero/streamero-admin-credentials.txt`, ili s drugim adminom u Users & roles |

## Sigurnost — kratko

- `.env` i `streamero-admin-credentials.txt` sadrže tajne: ne dijeli ih i ne stavljaj u git (`.env` je već u `.gitignore`).
  Nakon prve prijave možeš obrisati credentials datoteku i lozinku iz `.env` (`BOOTSTRAP_ADMIN_PASSWORD=`).
- Port 8088, baza, Redis i S3 nisu dostupni s interneta.
- Streamaj samo sadržaj koji posjeduješ ili imaš pravo dijeliti.
