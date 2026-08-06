# PingFederate Learning Lab

A throwaway sandbox for learning PingFederate objects hands-on, with **real
partners on both sides** rather than dummy connections.

Four containers on one EC2 host:

| Service | Port | Role |
|---|---|---|
| PingFederate | 9999 / 9031 | The broker — the thing being learned |
| Keycloak | 8080 | Upstream IdP (pre-configured) |
| Flask SAML SP | 5000 | Downstream SAML app |
| Grafana | 3000 | Downstream OIDC app |

---

## Read these in order

1. **[ARCHITECTURE.md](ARCHITECTURE.md)** — what each piece is and why it was chosen
2. **[RUNBOOK.md](RUNBOOK.md)** — EC2 setup, then per-phase click-paths
3. Your `pingfederate-objects-learning-plan.md` — the phases and quizzes

---

## Quick start

```bash
# On a t3.large Amazon Linux 2023 instance WITH AN ELASTIC IP
chmod +x scripts/*.sh
./scripts/install-docker.sh
exit                           # log out/in for the docker group to apply

cd pingfederate-lab
cp .env.example .env
vi .env                        # HOST_IP + DevOps key + passwords

./scripts/render-realm.sh      # bake HOST_IP into the Keycloak realm
docker compose up -d
./scripts/verify.sh            # must be clean before you start
```

Full detail in [RUNBOOK.md](RUNBOOK.md) Part A.

---

## Two things that will bite you

**Use an Elastic IP.** `HOST_IP` is baked into entity IDs, ACS URLs, redirect
URIs and metadata on both sides. If the instance's public IP changes, every
connection breaks at once and it looks like config corruption.

**Renew the DevOps licence key first.** The current one expires around
27 Aug 2026. Get a fresh one at <https://devops.pingidentity.com/> before
starting.

---

## What is and is not pre-configured

**Pre-configured:** Keycloak only — realm, users, groups, attribute mappers,
both client types. It is the *other side*, not the subject.

**Not pre-configured:** anything inside PingFederate. You build every
connection, adapter, contract and policy by hand. That is the entire point.

Test users:

| User | Password | Groups | Purpose |
|---|---|---|---|
| `alice` | `Alice-Lab-2026!` | `platform-admins` | Happy path → Grafana Admin |
| `bob` | `Bob-Lab-2026!` | `viewers` | Proves mapping discriminates |
| `carol` | `Carol-Lab-2026!` | none | Shows why `NO_MAPPING` exists |

---

## Scripts

| Script | Purpose |
|---|---|
| `scripts/install-docker.sh` | Docker + buildx + compose on AL2023. **Run first** |
| `scripts/verify.sh` | Health-check everything. **Run before debugging config** |
| `scripts/backup-config.sh` | Export PF config via the Admin API |
| `scripts/render-realm.sh` | Substitute `HOST_IP` into the Keycloak realm |

Back up before each phase:

```bash
./scripts/backup-config.sh pre-phase2
```

Diffing two backups shows exactly what a console change altered — a useful
habit, and early practice for the Admin API work in Days 18–22.

---

## Cost

`t3.large` is roughly $0.08/hour. **Stop the instance when idle.** The Elastic
IP keeps the address stable across stop/start, so nothing breaks.

An Elastic IP is free while associated with a running instance; AWS charges a
small hourly rate when it is allocated but unattached or attached to a stopped
instance.

---

## Not included, on purpose

Terraform, CDK, TLS, clustering, security scanning, Single Logout, DID
registry, login portal. All deliberately staged for later — see
[ARCHITECTURE.md](ARCHITECTURE.md) for the reasoning.

This is a learning rig on a personal AWS account. Do not copy it toward
anything real.
