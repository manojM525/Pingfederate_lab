# Lab Architecture

What each piece is, why it was chosen, and which learning phase it serves.

---

## The idea

Configuring an SP Connection with nothing on the other end teaches you the
screens. It does not teach you the failure modes, and the failure modes are
where the understanding lives.

So this lab puts a **real entity on both sides** of PingFederate:

```
            ┌──────────────┐
            │   Keycloak   │   upstream IdP        (Phase 4)
            │   :8080      │
            └──────┬───────┘
                   │  PF acts as SP
                   ▼
        ┌────────────────────────┐
        │     PingFederate       │   the broker
        │  :9999 admin           │   ← everything you build
        │  :9031 runtime         │
        └───┬────────────────┬───┘
            │  PF acts as IdP │
            ▼                 ▼
   ┌────────────────┐  ┌──────────────┐
   │ Flask SAML SP  │  │   Grafana    │
   │ :5000  (SAML)  │  │ :3000 (OIDC) │
   │   Phase 2      │  │  Phase 5/6   │
   └────────────────┘  └──────────────┘
```

That shape is the BYOI project in miniature: upstream IdP → broker → downstream
apps, with the broker vouching in the middle.

---

## Component choices

| Component | Why this one |
|---|---|
| **PingFederate** | The subject. Same major version pinned in the BYOI platform repo, so what you learn transfers |
| **Keycloak** | What BYOI itself uses as a test IdP. Speaks **both** SAML and OIDC, so one container covers Phase 4 either way |
| **Flask SAML SP** | Mirrors BYOI's own `saml-app`. Needed because **Grafana OSS cannot do SAML** — that is an Enterprise feature |
| **Grafana** | The OIDC app in the real BYOI project. Its `role_attribute_path` gives you group→role mapping for free |

Everything runs as containers on one EC2 host via Docker Compose. No ECS, no
Aurora, no ALB — those are BYOI's production concerns and would obscure the
thing you are trying to see.

---

## Which flows exercise which PingFederate objects

| Flow | Direction | PF role | Objects you build |
|---|---|---|---|
| Login at Flask SP | Outbound | **IdP** | `idp_sp_connection`, attribute contract, adapter mapping |
| Keycloak → PF | Inbound | **SP** | `sp_idp_connection`, attribute mapping into the APC |
| Keycloak → PF → Flask SP | Both | Broker | The above plus `authentication_policy_contract` |
| Grafana login | Outbound | **OAuth AS / OP** | `oauth_client`, `access_token_manager`, `openid_connect_policy` |

The third row is the payoff. When a user authenticates at Keycloak and lands
in the Flask app, with the Flask app knowing nothing about Keycloak — that is
brokering, working, in front of you.

---

## What is pre-configured, and what is not

**Pre-configured: Keycloak only.**
Realm, three users, two groups, attribute mappers, and both client types
(SAML and OIDC) ship in `keycloak/realm-byoi-test.json`. Keycloak is the
*other side* — scaffolding, not the subject.

**Not pre-configured: anything inside PingFederate.**
No connections, no adapters, no contracts, no policy tree. You build every
object by hand through the console. A pre-built SP Connection would give you a
working demo and no understanding.

The runbook tells you what to click. It does not click for you.

---

## Why the test users are shaped that way

| User | Groups | department | Purpose |
|---|---|---|---|
| `alice` | `platform-admins` | Platform Engineering | The happy path. Maps to Grafana **Admin** |
| `bob` | `viewers` | Finance | Proves group mapping actually discriminates |
| `carol` | *none* | *none* | **The interesting one** |

`carol` exists so `NO_MAPPING` stops being a doc paragraph. Put `department`
in an attribute contract, log in as carol, and watch assertion construction
fail — or watch the attribute arrive empty. That failure is the lesson.

---

## Design decisions and their trade-offs

### HTTP, not HTTPS

Deliberate, for Phases 1–4.

**Gains:** no certificate management, no browser warnings, and SAML POST
bodies and OIDC redirects are readable in devtools. Being able to *see* a
base64 assertion in the network tab is worth a lot early on.

**Costs:** not how anything ships, and Keycloak and Grafana are both fussier
about cookies over plain HTTP.

PingFederate itself still serves HTTPS on 9999/9031 with a self-signed cert —
that is the image's default and not worth fighting. Your browser will warn;
accept and continue.

Adding TLS later is a good standalone exercise once the flows work.

### Elastic IP is mandatory

`HOST_IP` is baked into entity IDs, ACS URLs, redirect URIs, metadata
documents, and Keycloak's client config — **on both sides**.

Stop an EC2 instance without an Elastic IP and the public IP changes. Every
connection then breaks simultaneously, and the symptoms look like config
corruption rather than an address change. You will lose an afternoon.

This is the same failure as the `localhost` metadata problem from Day 1:
URLs baked into federation config must stay stable.

### Volumes, or you lose your work

PingFederate keeps configuration in an embedded H2 database inside the
container. Without `pf-data` mounted, `docker compose down` destroys every
object you built.

Keycloak's realm state and Grafana's users are likewise persisted.

### Ports

| Port | Service | Notes |
|---|---|---|
| 9999 | PF admin console | Configuration only. Never in the live auth path |
| 9031 | PF runtime engine | All federation traffic |
| 8080 | Keycloak | Upstream IdP |
| 5000 | Flask SAML SP | Mapped from container port 8080 |
| 3000 | Grafana | |
| 22 | SSH | |

All locked to your `/32` in the security group. No `0.0.0.0/0`.

The 9999/9031 split is worth internalising: the console can be completely down
while users continue authenticating, because the engine serves runtime traffic
independently.

---

## Deliberately out of scope

| Not included | Why |
|---|---|
| Terraform / CDK | Manual first. Automating a thing you do not understand hides the failures |
| TLS | Phases 1–4 read better in plaintext. Add later as an exercise |
| Clustering / HA | Single node. Console-vs-engine split is still visible via ports |
| Security scanning | This is a throwaway learning rig on a personal account |
| Single Logout | Adds surface without adding understanding at this stage |
| DID registry, login portal | BYOI product components, not PingFederate concepts |

---

## How this maps back to BYOI

| This lab | BYOI equivalent |
|---|---|
| Docker Compose on EC2 | ECS Fargate on GovCloud |
| Public Ping DevOps image | Iron Bank hardened image (CAC-gated) |
| Console clicks | Terraform via the PF Admin API |
| `.env` | `config.<env>.yaml` + Secrets Manager |
| Keycloak realm import | `config/<env>/idps/*.yaml` |
| Flask SP + Grafana | `infrastructure/test-apps/` |
| `backup-config.sh` | Terraform state as source of truth |

The objects you build here by hand are the same objects `byoi-config` creates
declaratively. Once a connection is familiar from the console, the Terraform
that produces it becomes readable rather than cryptic.
