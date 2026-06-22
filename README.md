# HA SSO — visoko dostupan sistem jedinstvene prijave (microk8s)

Implementacija visoko dostupnog sistema autentifikacije i autorizacije (SSO) zasnovanog na komponentama otvorenog koda, orkestriranog na microk8s klasteru. Keycloak je provajder identiteta, CloudNativePG obezbjeđuje visoko dostupnu PostgreSQL bazu, a nginx Ingress je ulazna tačka.

Repozitorij je napravljen tako da bude **reproducibilan** — bilo koja institucija može uspostaviti isti sistem na vlastitim serverima izmjenom jednog konfiguracionog fajla.

Nastao kao dio master rada *„Dizajn i implementacija visoko dostupnog sistema autentifikacije i autorizacije u univerzitetskom okruženju”*, Elektrotehnički fakultet, Univerzitet u Banjoj Luci, 2026.

---

## Zašto microk8s

microk8s je CNCF-certifikovana laka distribucija Kubernetesa. Na Ubuntu okruženju pruža automatsko klasterovanje visoke dostupnosti pri dodavanju trećeg čvora (dqlite kontrolna ravan), jednostavnu integraciju potrebnih dodataka (Ingress, skladištenje, DNS) jednom komandom, te nativnu podršku za namjenske operatore. Budući da je fokus rada na dostupnosti servisa autentifikacije i sloja perzistencije, a ne na orkestracionoj platformi, microk8s zadovoljava sve zahtjeve arhitekture uz minimalnu operativnu složenost.

---

## Arhitektura

Tri sloja, svaki sa redundansom:

- **Sloj jedinstvene prijave** — tri Keycloak instance u aktivno-aktivnom režimu, replikacija sesija kroz Infinispan, međusobno otkrivanje putem DNS_PING.
- **Sloj perzistencije** — PostgreSQL klaster (primary + dvije replike) pod CloudNativePG operatorom, streaming replikacija i automatski failover.
- **Kontrolna ravan** — tri microk8s čvora sa automatskom HA kontrolnom ravni (dqlite), čime ni kontrolna ravan nije jedinstvena tačka otkaza.

Operatori automatski kreiraju StatefulSet, Deployment, servise, PVC, replikaciju i failover. Ručno se definiše samo konfiguracija, tajne i tri prilagođena resursa.

---

## Preduslovi

| Stavka | Minimalno | Preporučeno |
|---|---|---|
| Broj čvorova | 1 (bez HA) | 3 (HA klaster) |
| RAM po čvoru | 4 GB | 8 GB ili više |
| Disk po čvoru | 20 GB | 50 GB ili više |
| OS | Ubuntu 22.04 (snap) | Ubuntu 22.04 |
| Mreža | jedna podmreža | jedna podmreža |
| DNS | A-zapis za hostname | A-zapis za hostname |

Potreban je SSH pristup sa root privilegijama na svim čvorovima.

---

## Struktura repozitorija

```
ha-sso/
├── config.env                      # JEDINI fajl koji mijenjate
├── README.md
├── scripts/
│   ├── 01-install-microk8s.sh      # instalacija (svaki čvor)
│   ├── 02-form-cluster.sh          # HA klaster (n00)
│   ├── 03-addons-operators.sh      # dodaci + operatori (n00)
│   ├── 04-secrets.sh               # namespace + tajne (n00)
│   ├── 05-deploy.sh                # render + deploy (n00)
│   └── 06-verify.sh                # provjera + dokazi (n00)
├── templates/
│   ├── postgres/cnpg-cluster.yaml
│   ├── keycloak/keycloak-cr.yaml
│   ├── keycloak/realm-import-cr.yaml
│   └── ingress/ingress.yaml
└── docs/                           # ovdje 06-verify.sh snima izlaze
```

---

## Brzi početak

### 1. Klonirajte i podesite

```bash
git clone https://github.com/<korisnik>/ha-sso
cd ha-sso
nano config.env      # upišite IP adrese, hostname, domenu
```

### 2. Instalirajte microk8s na svakom čvoru

Na **sva tri čvora**:

```bash
sudo bash scripts/01-install-microk8s.sh
```

Nakon instalacije odjavite se i prijavite ponovo (radi članstva u grupi `microk8s`).

### 3. Formirajte HA klaster (samo n00)

```bash
sudo bash scripts/02-form-cluster.sh
```

Skripta ispisuje `microk8s join ...` komande. Pokrenite ih na n01 i n02 kako vas skripta vodi.

### 4. Dodaci i operatori (samo n00)

```bash
sudo bash scripts/03-addons-operators.sh
```

### 5. Tajne (samo n00)

```bash
sudo bash scripts/04-secrets.sh '<db-lozinka>' '<admin-lozinka>'
```

### 6. Deploy (samo n00)

```bash
sudo bash scripts/05-deploy.sh
```

### 7. Provjera

```bash
sudo bash scripts/06-verify.sh
```

Otvorite `https://<vaš-hostname>` — pojaviće se Keycloak. Admin konzola je na `/admin`.

---

## Prilagođavanje za drugu instituciju

Sve izmjene idu u `config.env`. Obavezno promijenite:

- `NODE0_IP`, `NODE1_IP`, `NODE2_IP` — adrese vaših čvorova
- `KEYCLOAK_HOSTNAME` — vaša domena (sa važećim DNS zapisom)

Vjerovatno ćete prilagoditi i `PG_STORAGE_SIZE` i `REALM_NAME`. Nazive rola i test klijent mijenjate u `templates/keycloak/realm-import-cr.yaml`.

---

## Produkcione napomene

- **TLS certifikat**: skripta `04` generiše self-signed certifikat radi brzog starta. Za produkciju ga zamijenite važećim (Let's Encrypt preko cert-manager-a ili certifikat institucije) u Secretu `keycloak-tls`.
- **Lozinke**: ne upisujte ih u verzionisane fajlove; prosljeđujte kao argumente skripte `04`.
- **Broj instanci**: tri Keycloak instance su minimum za ispravan Infinispan quorum.
- **HA klaster**: microk8s prelazi u HA režim tek sa tri čvora. Sa manje od tri, kontrolna ravan nije redundantna.

---

## Licenca

MIT — slobodno za upotrebu, izmjenu i dalju distribuciju.
