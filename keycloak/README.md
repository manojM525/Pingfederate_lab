# Keycloak realm — design notes

`realm-byoi-test.json` has no comments in it on purpose now — an earlier
version used `_comment_*` fake fields for inline notes, which JSON's syntax
happily allows but Keycloak's strict importer does not: it deserializes
against a fixed Java class and rejects any field it doesn't recognize. JSON
has no real comment syntax, and that convention doesn't work for a strict
consumer. This file is where those notes live instead.

---

## Groups and users

`platform-admins` and `viewers` exist so you can exercise group-to-role
mapping. Grafana (Phase 6) maps `platform-admins` to its Admin role — the same
shape as AWS Identity Center mapping groups to permission sets.

| User | Group | department | Purpose |
|---|---|---|---|
| `alice` | `platform-admins` | Platform Engineering | Happy path |
| `bob` | `viewers` | Finance | Proves mapping discriminates |
| `carol` | none | none | Deliberate — see below |

`carol` has no group and no department. Log in as her once an attribute
contract in PingFederate expects `department`, and you'll see directly why
`NO_MAPPING` exists rather than reading about it.

## The `byoi-attributes` client scope

Without an explicit mapper, group membership and custom attributes do **not**
appear in tokens or assertions by default — Keycloak has to be told to
include them. This scope carries `groups` and `department` and is attached as
a default scope on the OIDC client, so both show up in the OIDC flow (Phase
5/6) without extra clicking.

## The two placeholder clients

Both ship with literal placeholder strings that `render-realm.sh` and manual
editing fill in — **not** comments, real values the realm needs:

**`pingfederate-broker` (OIDC).** Redirect URIs contain `HOST_IP_PLACEHOLDER`,
filled in by `render-realm.sh` from your `.env`. This is Phase 4's OIDC-inbound
path — PingFederate is the client here, Keycloak is upstream. The secret
(`pf-lab-client-secret-2026`) is fixed for lab convenience; never do this
outside a throwaway sandbox.

**`PF_SAML_ENTITY_ID_PLACEHOLDER` (SAML).** The `clientId` itself is a
placeholder, not just a URI — for a SAML client in Keycloak, the client ID
**must equal** the SP's entity ID exactly. You can't know that value until
you've set PingFederate's own SAML entity ID in Server Settings (Phase 1). So
this one is fixed by hand — see RUNBOOK.md Phase 4, step 4.1 — not by the
render script.

Its protocol mappers (`email`, `firstName`, `lastName`, `department`,
`groups`) are the SAML-side equivalent of the `byoi-attributes` scope above:
without them, an assertion authenticates the user but carries no attributes.

---

## If you already hit the `_comment` crash

The container will have crash-looped a few times, which is harmless — no
partial realm was ever imported, since the crash happens before any data is
written. Recovery:

```bash
docker compose down
rm -f keycloak/realm-byoi-test.json.template   # stale, still has the bad keys
docker compose up -d keycloak
docker compose logs -f keycloak
```

Deleting the `.template` matters: `render-realm.sh` only regenerates it if
absent, so a stale copy would silently reintroduce the same crash on the next
render.
