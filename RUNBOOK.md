# Runbook

Setup through to each phase's click-path. Follow in order.

Phase numbers match `pingfederate-objects-learning-plan.md`.

---

# Part A — One-time setup

## A1. Renew the PingFederate DevOps key first

Your current key expires around **27 Aug 2026**. The lab is useless without a
valid one, and finding out mid-Phase-4 is worse than finding out now.

Get one at <https://devops.pingidentity.com/> (free community programme).
You need the **user** (email) and the **key** (a UUID).

## A2. Allocate an Elastic IP

**Do this before launching anything.** Not optional — see ARCHITECTURE.md.

```
EC2 → Elastic IPs → Allocate Elastic IP address → Allocate
```

Note the address. This is your `HOST_IP` forever.

## A3. Launch the EC2 instance

| Setting | Value |
|---|---|
| AMI | Amazon Linux 2023 |
| Type | `t3.large` (8 GB) |
| Storage | 30 GB gp3 |
| Key pair | your own |

`t3.medium` will technically boot but PingFederate and Keycloak are both JVMs
and you will spend your time watching swap instead of learning.

Then associate the Elastic IP:

```
EC2 → Elastic IPs → select → Actions → Associate → your instance
```

## A4. Security group

Find your public IP: <https://checkip.amazonaws.com>

Inbound rules, **all sourced to `<your-ip>/32`** — never `0.0.0.0/0`:

| Port | Purpose |
|---|---|
| 22 | SSH |
| 9999 | PF admin console |
| 9031 | PF runtime engine |
| 8080 | Keycloak |
| 5000 | Flask SAML SP |
| 3000 | Grafana |

> Home IP changed and everything stopped working? Update the security group
> before debugging anything else. This will happen.

## A5. Install Docker

```bash
ssh -i <key.pem> ec2-user@<ELASTIC_IP>

# copy this repo onto the instance first (scp / git clone), then:
cd pingfederate-lab
chmod +x scripts/*.sh
./scripts/install-docker.sh

exit   # MUST log out and back in for the docker group to apply
```

Log back in and verify:

```bash
docker ps
docker compose version
docker buildx version    # must be >= 0.17.0
```

**Why the script rather than plain `dnf install docker`:** AL2023's docker
package ships no current buildx or compose plugin, and Compose needs
buildx `>=0.17.0` to build the Flask SAML SP's local Dockerfile. Without it
you hit `compose build requires buildx 0.17.0 or later` — and confusingly,
only *after* the three pulled images succeed, so the failure looks later in
the process than it is.

**The detail that actually matters:** AL2023's docker reads plugins from
`/usr/libexec/docker/cli-plugins`. Docker CE reads
`/usr/local/lib/docker/cli-plugins`. Installing plugins into the CE path
while running the AL2023 package means they are silently never found — the
binary is there, `docker buildx version` still fails. The script uses the
correct path.

> Installing Docker CE instead also works but is messier: Docker publishes no
> AL2023 repo, so you point dnf at the CentOS repo and must pin `$releasever`
> by hand (it otherwise expands to AL2023's own version string and 404s on
> `repomd.xml`). Distro package plus correct plugin path is simpler.

## A6. Configure and start

```bash
cd pingfederate-lab      # already copied across in A5

cp .env.example .env
vi .env
```

Set at minimum: `HOST_IP` (the Elastic IP),
`PING_IDENTITY_DEVOPS_USER`, `PING_IDENTITY_DEVOPS_KEY`, and change the three
admin passwords.

Then:

```bash
./scripts/render-realm.sh     # substitutes HOST_IP into the Keycloak realm
docker compose up -d
docker compose logs -f pingfederate    # first boot takes 2-4 minutes
```

When the log settles:

```bash
./scripts/verify.sh
```

Do not proceed until that is clean. Every failure it reports is cheaper to fix
now than to misdiagnose later as a federation problem.

## A7. First look

| URL | Login |
|---|---|
| `https://<HOST_IP>:9999/pingfederate/app` | `administrator` / `PF_ADMIN_PASSWORD` |
| `http://<HOST_IP>:8080` | `admin` / `KEYCLOAK_ADMIN_PASSWORD` |
| `http://<HOST_IP>:5000` | — |
| `http://<HOST_IP>:3000` | `admin` / `GRAFANA_ADMIN_PASSWORD` |

Browser will warn on the two HTTPS ports (self-signed). Accept and continue.

## A8. Daily use

```bash
docker compose stop        # end of session
docker compose start       # next session
./scripts/verify.sh
```

Stop the **instance** when idle to save money. The Elastic IP keeps the address
stable across stop/start — which is exactly why A2 exists.

---

# Part B — Phase click-paths

> **Back up before each phase.** `./scripts/backup-config.sh pre-phase2`
> A bad experiment then costs a restore, not a rebuild.

---

## Phase 1 — Foundation

Consolidating what you already know, in a clean environment.

**Server Settings** — `System → Server → Protocol Settings`

Confirm Base URL and SAML 2.0 Entity ID both use `https://<HOST_IP>:9031`,
**not** `localhost`. Write down the entity ID; several later steps need it.

**Signing certificate** — `Security → Certificate & Key Management → Signing`

Create a self-signed cert (CN = `pf-lab`, RSA 2048, 1 year). Export the
**certificate** (not the key) as base64 — Phase 2 needs it.

**Password Credential Validator** — `System → Data Stores`... actually
`Security → Password Credential Validators`. Create a *Simple Username
Password* validator with two users, e.g. `pflocal` and `pftest`.

> Note: these are PingFederate-local users, unrelated to Keycloak's. Phase 2
> uses these; Phase 4 replaces them with real upstream users.

**IdP Adapter** — `Authentication → Integration → IdP Adapters`

Create an *HTML Form IdP Adapter*, point it at the validator above. Core
contract: `username`, `policy.action`.

**Checkpoint:** answer quiz Phase 1 in the learning plan.

---

## Phase 2 — Outbound SAML (PF as IdP → Flask SP)

The first real end-to-end flow.

### 2.1 Get the SP's metadata

Visit `http://<HOST_IP>:5000/metadata` and save the XML. It carries the SP's
entity ID and ACS URL — precisely what the revision guide's metadata section
described.

### 2.2 Create the SP Connection

`Applications → SP Connections → Create Connection`

| Screen | Value |
|---|---|
| Connection Type | Browser SSO Profiles, SAML 2.0 |
| Connection Options | Browser SSO |
| Metadata | File → upload the XML from 2.1 |
| Protocol Settings → SSO | IdP-Initiated + SP-Initiated, POST binding |
| Assertion Consumer Service | should auto-fill from metadata |
| **Attribute Contract** | extend with `email`, `firstName`, `lastName` |
| Authentication Source Mapping | map your Phase 1 adapter |
| Credentials → Signing | select the Phase 1 signing cert |

On the adapter mapping screen, fulfil each contract attribute. With no data
store connected, use *Text* values or map from the adapter's `username`.
That crudeness is the point: it shows the contract is a promise the IdP must
keep, regardless of where values come from.

Save and **enable** the connection.

### 2.3 Wire the SP to trust PingFederate

Back on the EC2 host, in `.env`:

```bash
IDP_ENTITY_ID=<PF SAML entity ID from Phase 1>
IDP_SSO_URL=https://<HOST_IP>:9031/idp/SSO.saml2
IDP_X509_CERT=<signing cert, base64, ONE line, no BEGIN/END markers>
```

```bash
docker compose up -d saml-app
./scripts/verify.sh
```

### 2.4 Test

Go to `http://<HOST_IP>:5000` → **Log in via PingFederate** → authenticate with
a Phase 1 local user → you land on `/whoami`.

**That page is the exercise.** Everything shown arrived inside a signed
assertion. Now iterate:

- Add an attribute to the contract → log in again → it appears
- Remove one → it vanishes
- Open devtools, Network tab, find the POST to `/acs`, decode the base64
  `SAMLResponse` — read the actual XML you have been learning about

**Checkpoint:** quiz Phase 2.

---

## Phase 3 — Neutral layer (APC)

Nothing new to run; this is refactoring what Phase 2 built.

1. `Authentication → Policies → Policy Contracts` — create an APC with the
   same attributes as your Phase 2 contract.
2. Rewire the SP Connection to map from the **APC** instead of directly from
   the adapter.
3. `Authentication → Policies` — build a small tree with one selector.
4. `Authentication → Policies → Settings` — confirm
   **IdP Authentication Selection** is enabled.

> That last checkbox is `enableIdpAuthnSelection`. The BYOI HANDOVER warns
> that without it the entire policy tree is silently inert. Turn it off
> deliberately once and watch what happens — then turn it back on.

Re-test the Phase 2 login. Same result, different plumbing. That "no visible
change" is the point: the APC decoupled the adapter from the connection.

**Checkpoint:** quiz Phase 3.

---

## Phase 4 — Inbound SAML (Keycloak → PF)

Now PingFederate becomes the SP.

### 4.1 Fix the Keycloak SAML client ID

The realm ships a placeholder because the client ID must equal PingFederate's
SAML entity ID.

Keycloak admin → realm `byoi-test` → Clients → the client named
`PF_SAML_ENTITY_ID_PLACEHOLDER` → change Client ID to your PF entity ID → Save.

### 4.2 Get Keycloak's metadata

```
http://<HOST_IP>:8080/realms/byoi-test/protocol/saml/descriptor
```

### 4.3 Create the IdP Connection

`Authentication → Integration → IdP Connections → Create Connection`

| Screen | Value |
|---|---|
| Connection Type | Browser SSO Profiles, SAML 2.0 |
| Metadata | File → the descriptor from 4.2 |
| Browser SSO → User-Session Creation | map into the **Phase 3 APC** |
| Attribute mapping | `email`, `firstName`, `lastName`, `department`, `groups` |

For `department` and `groups`, notice you can choose **NO_MAPPING**. Leave the
mapping in place for now; you will exercise the alternative in 4.5.

### 4.4 Add Keycloak to the policy tree

`Authentication → Policies` — add the new IdP Connection as an authentication
source so a user can choose it.

### 4.5 Test — and this is the payoff

`http://<HOST_IP>:5000` → Log in → choose the Keycloak source → authenticate as
`alice` / `Alice-Lab-2026!`.

You should land on `/whoami` with alice's attributes and
`groups: platform-admins`.

**Stop and notice what just happened.** Alice authenticated at Keycloak. The
Flask app knows nothing about Keycloak — it only trusts PingFederate. That is
brokering.

Then, deliberately:

- Log in as **carol** (`Carol-Lab-2026!`). No groups, no department. Watch what
  arrives, or what fails. This is why `NO_MAPPING` exists.
- Log in as **bob** and confirm `groups: viewers` instead.

**Checkpoint:** quiz Phase 4.

---

## Phase 5 — OAuth (PF as Authorization Server)

### 5.1 Enable the AS

`System → OAuth Settings → Authorization Server Settings` — set the issuer to
`https://<HOST_IP>:9031`. Add scopes: `openid`, `profile`, `email`.

### 5.2 Access Token Manager

`Applications → OAuth → Access Token Management` — create a JWT-based manager.
Give it attributes `sub`, `email`, `groups`.

### 5.3 APC → OAuth mapping

`Applications → OAuth → Access Token Mappings` — map from your **Phase 3 APC**
into the token manager.

> This object is the bridge. It is how a user authenticated over SAML ends up
> holding an OAuth token — the protocol translation you learned about, as a
> configurable thing.

### 5.4 Register the Grafana client

`Applications → OAuth → Clients → Add Client`

| Field | Value |
|---|---|
| Client ID | `grafana` |
| Client Authentication | Client Secret (generate and copy it) |
| Redirect URIs | `http://<HOST_IP>:3000/login/generic_oauth` |
| Allowed Grant Types | Authorization Code |
| Scopes | `openid`, `profile`, `email` |

**Checkpoint:** quiz Phase 5.

---

## Phase 6 — OIDC (Grafana login)

### 6.1 OIDC policy

`Applications → OAuth → OpenID Connect Policy Management` — create a policy
including `sub`, `email`, `name`, `groups`.

### 6.2 Turn on Grafana

In `.env`:

```bash
OIDC_ENABLED=true
OIDC_CLIENT_ID=grafana
OIDC_CLIENT_SECRET=<from 5.4>
```

```bash
docker compose up -d grafana
```

### 6.3 Test

`http://<HOST_IP>:3000` → **Sign in with PingFederate** → authenticate via
Keycloak as `alice` → you land in Grafana as an **Admin**.

Then log in as `bob` and confirm you get **Viewer** instead.

**That difference is group-based RBAC working** — the same shape as Identity
Center mapping groups to permission sets, which is your Day 6-12 exercise.

### 6.4 Read the tokens

Decode the ID token (jwt.io, or PF's logs) and locate `sub`, `aud`, `exp`,
`iss`. Put it side by side with the SAML assertion from Phase 2 and compare
field for field. Same security model, different syntax.

**Checkpoint:** quiz Phase 6, then attempt the capstone in the learning plan.

---

# Part C — Troubleshooting

| Symptom | Check first |
|---|---|
| Nothing loads at all | Security group — did your home IP change? |
| Every connection broke at once | Did `HOST_IP` change? Elastic IP still associated? |
| PF container restarting | DevOps key expired or wrong. `docker compose logs pingfederate` |
| `Invalid SAML Response` at Flask SP | `IDP_X509_CERT` stale — re-export after any signing key change |
| Audience mismatch | SP Connection entity ID ≠ Flask SP entity ID |
| Keycloak rejects redirect | `render-realm.sh` not run, or `HOST_IP` changed since |
| Login works, no attributes | Attribute contract fulfilment, not the connection itself |
| Policy tree ignored | `enableIdpAuthnSelection` is off |
| Grafana always Viewer | `groups` claim missing from the OIDC policy |
| Config vanished after restart | `pf-data` volume not mounted |
| `compose build requires buildx 0.17.0+` | Run `./scripts/install-docker.sh`. If already run, check plugins are in `/usr/libexec/docker/cli-plugins` (AL2023's path), not `/usr/local/lib/...` (Docker CE's) |
| `docker buildx version` fails though the binary exists | Wrong plugin directory — see above. AL2023's docker only reads `/usr/libexec/docker/cli-plugins` |
| `permission denied` on docker socket | You did not log out and back in after `install-docker.sh` added you to the docker group |
| `verify.sh` shows PF unreachable but everything else works | Expected. Self-curling your own public IP hairpins through the IGW and is evaluated by the security group like external traffic — correctly blocked, since 9999/9031 are locked to your laptop's `/32`. `verify.sh` checks PF via loopback instead; confirm real reachability from your laptop's browser |
| Keycloak stuck on `starting` right after `up -d` | Normal on first boot — DB init plus realm import takes longer than a bare start. Watch `docker compose logs -f keycloak` for the realm-imported line, then re-check |
| Keycloak crash-loops: `Unrecognized field "_comment..."` | A stale `.template` still has the old comment-style keys. `rm keycloak/realm-byoi-test.json.template`, then re-run `render-realm.sh` — see `keycloak/README.md` |

**General rule:** run `./scripts/verify.sh` before assuming a federation
problem. Most "SAML is broken" turns out to be a stopped container or a
security group.

**Reading the actual assertion** is the highest-value debugging move in
Phase 2. Devtools → Network → the POST to `/acs` → decode the base64
`SAMLResponse`. Everything you need is in that XML.
