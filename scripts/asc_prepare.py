#!/usr/bin/env python3
"""Pregătirea unui build pe GitHub Actions, prin App Store Connect API:

1. înregistrează Bundle ID-ul, dacă nu există încă în cont;
2. află echipa (Team ID) din Bundle ID;
3. alege numărul de build: cel mai mare build urcat vreodată + 1.

Scrie TEAM_ID și BUILD_NUMBER în $GITHUB_ENV (sau le afișează, local).
Variabile de mediu: ASC_KEY_ID, ASC_ISSUER_ID, ASC_PRIVATE_KEY, BUNDLE_ID, APP_NAME.
"""
import base64
import json
import os
import re
import sys
import textwrap
import time
import urllib.error
import urllib.request

import jwt  # PyJWT

BASE = "https://api.appstoreconnect.apple.com"
BUNDLE_ID = os.environ["BUNDLE_ID"]
APP_NAME = os.environ.get("APP_NAME", "AnonRooms")


def private_key() -> str:
    raw = os.environ["ASC_PRIVATE_KEY"].strip().replace("\\n", "\n")
    if "BEGIN" not in raw:
        try:
            dec = base64.b64decode(raw).decode()
            if "BEGIN" in dec:
                raw = dec
        except Exception:
            pass
    body = re.sub(r"-----(BEGIN|END) [A-Z ]+-----", "", raw)
    body = re.sub(r"\s+", "", body)
    return "-----BEGIN PRIVATE KEY-----\n" + "\n".join(textwrap.wrap(body, 64)) + "\n-----END PRIVATE KEY-----\n"


def token() -> str:
    return jwt.encode(
        {"iss": os.environ["ASC_ISSUER_ID"].strip(), "exp": int(time.time()) + 15 * 60, "aud": "appstoreconnect-v1"},
        private_key(), algorithm="ES256",
        headers={"kid": os.environ["ASC_KEY_ID"].strip(), "typ": "JWT"})


def api(method: str, path: str, body=None):
    req = urllib.request.Request(
        BASE + path, method=method,
        data=json.dumps(body).encode() if body is not None else None,
        headers={"Authorization": "Bearer " + token(), "Content-Type": "application/json"})
    try:
        with urllib.request.urlopen(req, timeout=60) as resp:
            raw = resp.read()
            return json.loads(raw) if raw else {}
    except urllib.error.HTTPError as err:
        raise SystemExit(f"App Store Connect {method} {path}: {err.code}\n{err.read().decode()[:1500]}")


def main():
    found = api("GET", f"/v1/bundleIds?filter[identifier]={BUNDLE_ID}&limit=20")["data"]
    bundle = next((b for b in found if b["attributes"]["identifier"] == BUNDLE_ID), None)
    if not bundle:
        bundle = api("POST", "/v1/bundleIds", {"data": {"type": "bundleIds", "attributes": {
            "identifier": BUNDLE_ID, "name": APP_NAME, "platform": "IOS"}}})["data"]
        print(f"Bundle ID {BUNDLE_ID}: înregistrat acum")
    team = bundle["attributes"]["seedId"]

    apps = api("GET", f"/v1/apps?filter[bundleId]={BUNDLE_ID}")["data"]
    if not apps:
        raise SystemExit(
            f"::error::Aplicația nu există încă în App Store Connect. Creeaz-o manual "
            f"(Apps → + → New App) cu Bundle ID-ul {BUNDLE_ID}, apoi rulează din nou. "
            f"Bundle ID-ul e deja înregistrat și apare în listă.")
    builds = api("GET", f"/v1/builds?filter[app]={apps[0]['id']}&sort=-uploadedDate&limit=50")["data"]
    numbers = [int(b["attributes"]["version"]) for b in builds if b["attributes"]["version"].isdigit()]
    build = max(numbers, default=0) + 1
    print(f"Echipa {team}, build nou {build}")

    out = os.environ.get("GITHUB_ENV")
    if out:
        with open(out, "a") as f:
            f.write(f"TEAM_ID={team}\nBUILD_NUMBER={build}\n")


if __name__ == "__main__":
    sys.exit(main())
