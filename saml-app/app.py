"""
Minimal SAML Service Provider for the PingFederate learning lab.

Purpose: be a REAL SP so PingFederate has a genuine partner to federate with,
and so you can see an actual assertion rather than a configuration screen.

The interesting page is /whoami. After login it dumps every attribute that
arrived in the assertion. That view is where attribute contracts stop being
abstract: add an attribute to the contract in PingFederate, log in again,
watch it appear here. Remove it, watch it vanish.

Deliberately unstyled and deliberately insecure (plain HTTP, self-signed
trust). This is a teaching rig, not a template for anything real.
"""

import os
import json
from flask import Flask, request, redirect, session, render_template, url_for
from onelogin.saml2.auth import OneLogin_Saml2_Auth
from onelogin.saml2.settings import OneLogin_Saml2_Settings

app = Flask(__name__)

# Generated at import time if unset. Gunicorn runs with --preload so the master
# process imports ONCE before forking; every worker then inherits the same key.
# Without --preload each worker invents its own key, cookies signed by one
# worker fail on another, and the symptom is "I have to refresh a few times
# after logging in". Set FLASK_SECRET_KEY in .env to survive restarts too.
app.secret_key = os.environ.get("FLASK_SECRET_KEY") or os.urandom(32)

SP_BASE_URL = os.environ.get("SP_BASE_URL", "http://localhost:5000")
SP_ENTITY_ID = os.environ.get("SP_ENTITY_ID", f"{SP_BASE_URL}/metadata")

IDP_ENTITY_ID = os.environ.get("IDP_ENTITY_ID", "")
IDP_SSO_URL = os.environ.get("IDP_SSO_URL", "")
IDP_X509_CERT = os.environ.get("IDP_X509_CERT", "")


def saml_settings():
    """
    Build python3-saml settings from environment.

    Note what the SP needs to know about the IdP, and compare it to the
    revision guide's metadata section — entity ID, SSO URL, public certificate.
    That is exactly what a metadata document carries. Here you are pasting by
    hand what metadata exchange would normally automate.
    """
    return {
        "strict": True,
        "debug": True,
        "sp": {
            "entityId": SP_ENTITY_ID,
            "assertionConsumerService": {
                "url": f"{SP_BASE_URL}/acs",
                "binding": "urn:oasis:names:tc:SAML:2.0:bindings:HTTP-POST",
            },
            "NameIDFormat": "urn:oasis:names:tc:SAML:1.1:nameid-format:unspecified",
            # This lab's SP does not sign its requests, so no SP keypair.
            # PingFederate's SP Connection must therefore NOT require signed
            # AuthnRequests. If it does, you get a signature-validation error
            # at the IdP before any login screen appears.
            "x509cert": "",
            "privateKey": "",
        },
        "idp": {
            "entityId": IDP_ENTITY_ID,
            "singleSignOnService": {
                "url": IDP_SSO_URL,
                "binding": "urn:oasis:names:tc:SAML:2.0:bindings:HTTP-Redirect",
            },
            # The IdP's PUBLIC signing certificate. Verifying assertion
            # signatures against this is the whole trust relationship.
            # If PingFederate's signing key is regenerated, this goes stale
            # and every login fails — the exact failure the BYOI HANDOVER
            # warns about with sp_signing_key_import_secret_path.
            "x509cert": IDP_X509_CERT,
        },
        "security": {
            "wantAssertionsSigned": True,
            "wantMessagesSigned": False,
            "wantNameIdEncrypted": False,
            "wantAssertionsEncrypted": False,
            "authnRequestsSigned": False,
        },
    }


def prepare_request(req):
    """Translate a Flask request into what python3-saml expects."""
    url_data = req.url.split("?")
    host = SP_BASE_URL.replace("http://", "").replace("https://", "").split("/")[0]
    return {
        "https": "on" if SP_BASE_URL.startswith("https") else "off",
        "http_host": host,
        "server_port": host.split(":")[1] if ":" in host else "80",
        "script_name": req.path,
        "get_data": req.args.copy(),
        "post_data": req.form.copy(),
        "query_string": url_data[1] if len(url_data) > 1 else "",
    }


def idp_configured():
    return bool(IDP_ENTITY_ID and IDP_SSO_URL and IDP_X509_CERT)


@app.route("/health")
def health():
    return {"status": "ok", "idp_configured": idp_configured()}, 200


@app.route("/")
def index():
    return render_template(
        "index.html",
        user=session.get("samlUserdata"),
        nameid=session.get("samlNameId"),
        idp_configured=idp_configured(),
        sp_entity_id=SP_ENTITY_ID,
        acs_url=f"{SP_BASE_URL}/acs",
    )


@app.route("/login")
def login():
    """Start SP-initiated SSO: build an AuthnRequest and redirect to the IdP."""
    if not idp_configured():
        return render_template("error.html",
                               message="IdP not configured yet. Set IDP_ENTITY_ID, "
                                       "IDP_SSO_URL and IDP_X509_CERT in .env, then "
                                       "`docker compose up -d saml-app`."), 503
    auth = OneLogin_Saml2_Auth(prepare_request(request), saml_settings())
    return redirect(auth.login())


@app.route("/acs", methods=["POST"])
def acs():
    """
    Assertion Consumer Service — where the signed assertion lands.

    This is step 6 of the SAML flow from the revision guide: verify the
    signature against the IdP's certificate, check timestamps and audience,
    then create a local session.
    """
    auth = OneLogin_Saml2_Auth(prepare_request(request), saml_settings())
    auth.process_response()
    errors = auth.get_errors()

    if errors:
        # auth.get_last_error_reason() is the single most useful string in this
        # whole app when debugging Phase 2. Read it before changing anything.
        return render_template(
            "error.html",
            message=f"SAML validation failed: {', '.join(errors)}",
            detail=auth.get_last_error_reason(),
        ), 400

    if not auth.is_authenticated():
        return render_template("error.html", message="Not authenticated"), 401

    session["samlUserdata"] = auth.get_attributes()
    session["samlNameId"] = auth.get_nameid()
    return redirect(url_for("whoami"))


@app.route("/whoami")
def whoami():
    """
    The page that matters. Everything the assertion carried, dumped raw.

    Use this to make attribute contracts concrete:
      - add an attribute to the contract in PingFederate -> reappear here
      - log in as carol (no groups, no department) -> see empty/absent values
    """
    if "samlUserdata" not in session:
        return redirect(url_for("index"))
    return render_template(
        "whoami.html",
        nameid=session.get("samlNameId"),
        attributes=session.get("samlUserdata", {}),
        raw=json.dumps(session.get("samlUserdata", {}), indent=2, sort_keys=True),
    )


@app.route("/metadata")
def metadata():
    """
    This SP's own metadata. Import into PingFederate when creating the
    SP Connection in Phase 2, instead of typing entity ID and ACS URL by hand.
    """
    settings = OneLogin_Saml2_Settings(saml_settings(), sp_validation_only=True)
    xml = settings.get_sp_metadata()
    errors = settings.validate_metadata(xml)
    if errors:
        return f"Invalid metadata: {', '.join(errors)}", 500
    return xml, 200, {"Content-Type": "text/xml"}


@app.route("/logout")
def logout():
    """Local logout only. Single Logout is out of scope for this lab."""
    session.clear()
    return redirect(url_for("index"))


if __name__ == "__main__":
    app.run(host="0.0.0.0", port=8080, debug=True)
