#!/usr/bin/env python3
"""Configure single-page Turnstile browser login flow for a Keycloak realm."""

from __future__ import annotations

import json
import os
import sys
import urllib.error
import urllib.parse
import urllib.request

FLOW_ALIAS = "browser-turnstile"
FORMS_ALIAS = f"{FLOW_ALIAS} forms"
TURNSTILE_PROVIDER = "cloudflare-turnstile-authenticator"
USERNAME_PASSWORD_PROVIDER = "auth-username-password-form"


def env(name: str, default: str | None = None, required: bool = False) -> str:
    value = os.environ.get(name, default)
    if required and not value:
        print(f"Missing required env: {name}", file=sys.stderr)
        sys.exit(1)
    return value or ""


def request(method: str, url: str, token: str, body: dict | list | None = None) -> object:
    data = None
    headers = {"Authorization": f"Bearer {token}", "Accept": "application/json"}
    if body is not None:
        data = json.dumps(body).encode()
        headers["Content-Type"] = "application/json"
    req = urllib.request.Request(url, data=data, headers=headers, method=method)
    try:
        with urllib.request.urlopen(req) as resp:
            raw = resp.read()
            if not raw:
                return None
            return json.loads(raw)
    except urllib.error.HTTPError as exc:
        detail = exc.read().decode("utf-8", errors="replace")
        raise RuntimeError(f"{method} {url} -> HTTP {exc.code}: {detail}") from exc


def token(base: str, admin_user: str, admin_password: str) -> str:
    form = urllib.parse.urlencode(
        {
            "grant_type": "password",
            "client_id": "admin-cli",
            "username": admin_user,
            "password": admin_password,
        }
    ).encode()
    req = urllib.request.Request(
        f"{base}/realms/master/protocol/openid-connect/token",
        data=form,
        headers={"Content-Type": "application/x-www-form-urlencoded"},
        method="POST",
    )
    with urllib.request.urlopen(req) as resp:
        return json.loads(resp.read())["access_token"]


def admin(base: str, realm: str, path: str) -> str:
    return f"{base}/admin/realms/{urllib.parse.quote(realm, safe='')}/{path.lstrip('/')}"


def flow_exists(base: str, realm: str, token_value: str, alias: str) -> bool:
    flows = request("GET", admin(base, realm, "authentication/flows"), token_value)
    return any(f.get("alias") == alias for f in flows or [])


def duplicate_browser_flow(base: str, realm: str, token_value: str) -> None:
    if flow_exists(base, realm, token_value, FLOW_ALIAS):
        print(f"Flow '{FLOW_ALIAS}' already exists.")
        return
    request(
        "POST",
        admin(base, realm, "authentication/flows/browser/copy"),
        token_value,
        {"newName": FLOW_ALIAS},
    )
    print(f"Created flow '{FLOW_ALIAS}' from browser.")


def get_executions(base: str, realm: str, token_value: str, alias: str) -> list[dict]:
    encoded = urllib.parse.quote(alias, safe="")
    return request(
        "GET",
        admin(base, realm, f"authentication/flows/{encoded}/executions"),
        token_value,
    )


def delete_execution(base: str, realm: str, token_value: str, execution_id: str) -> None:
    request("DELETE", admin(base, realm, f"authentication/executions/{execution_id}"), token_value)


def add_execution(base: str, realm: str, token_value: str, alias: str, provider: str) -> None:
    encoded = urllib.parse.quote(alias, safe="")
    request(
        "POST",
        admin(base, realm, f"authentication/flows/{encoded}/executions/execution"),
        token_value,
        {"provider": provider},
    )


def put_executions(base: str, realm: str, token_value: str, alias: str, executions: list[dict]) -> None:
    encoded = urllib.parse.quote(alias, safe="")
    request(
        "PUT",
        admin(base, realm, f"authentication/flows/{encoded}/executions"),
        token_value,
        executions,
    )


def create_turnstile_config(
    base: str,
    realm: str,
    token_value: str,
    execution_id: str,
    site_key: str,
    secret_key: str,
) -> str:
    payload = {
        "alias": "turnstile-prod",
        "config": {
            "siteKey": site_key,
            "secretKey": secret_key,
            "implementationMethod": "CUSTOM_THEME",
            "widgetMode": "managed",
            "widgetTheme": "auto",
            "recordVerifications": "true",
            "failAction": "BLOCK",
            "failMode": "FAIL_CLOSED",
            "connectTimeout": "5000",
            "readTimeout": "5000",
            "ipAllowlist": "10.0.0.0/8,172.16.0.0/12,192.168.0.0/16,127.0.0.0/8,::1/128,fc00::/7,fe80::/10",
            "allowlistBehavior": "VERIFY_BUT_ALLOW",
        },
    }
    created = request(
        "POST",
        admin(base, realm, f"authentication/executions/{execution_id}/config"),
        token_value,
        payload,
    )
    return created["id"]


def update_turnstile_config(
    base: str,
    realm: str,
    token_value: str,
    config_id: str,
    site_key: str,
    secret_key: str,
) -> None:
    payload = {
        "alias": "turnstile-prod",
        "config": {
            "siteKey": site_key,
            "secretKey": secret_key,
            "implementationMethod": "CUSTOM_THEME",
            "widgetMode": "managed",
            "widgetTheme": "auto",
            "recordVerifications": "true",
            "failAction": "BLOCK",
            "failMode": "FAIL_CLOSED",
            "connectTimeout": "5000",
            "readTimeout": "5000",
            "ipAllowlist": "10.0.0.0/8,172.16.0.0/12,192.168.0.0/16,127.0.0.0/8,::1/128,fc00::/7,fe80::/10",
            "allowlistBehavior": "VERIFY_BUT_ALLOW",
        },
    }
    request(
        "PUT",
        admin(base, realm, f"authentication/config/{config_id}"),
        token_value,
        payload,
    )


def configure_forms_flow(base: str, realm: str, token_value: str, site_key: str, secret_key: str) -> None:
    execs = get_executions(base, realm, token_value, FORMS_ALIAS)

    for item in execs:
        provider = item.get("providerId")
        if provider == USERNAME_PASSWORD_PROVIDER:
            delete_execution(base, realm, token_value, item["id"])
            print("Removed Username Password Form from forms subflow (single-page Custom Theme).")

    execs = get_executions(base, realm, token_value, FORMS_ALIAS)
    turnstile_execs = [e for e in execs if e.get("providerId") == TURNSTILE_PROVIDER and e.get("level", 0) == 0]
    if len(turnstile_execs) > 1:
        for extra in turnstile_execs[1:]:
            delete_execution(base, realm, token_value, extra["id"])
        print("Removed duplicate Turnstile executions.")
        execs = get_executions(base, realm, token_value, FORMS_ALIAS)
        turnstile_execs = [e for e in execs if e.get("providerId") == TURNSTILE_PROVIDER and e.get("level", 0) == 0]

    if not turnstile_execs:
        add_execution(base, realm, token_value, FORMS_ALIAS, TURNSTILE_PROVIDER)
        execs = get_executions(base, realm, token_value, FORMS_ALIAS)
        turnstile_execs = [e for e in execs if e.get("providerId") == TURNSTILE_PROVIDER and e.get("level", 0) == 0]

    turnstile = turnstile_execs[0]
    config_id = turnstile.get("authenticationConfig")
    if config_id:
        update_turnstile_config(base, realm, token_value, config_id, site_key, secret_key)
        print("Updated Turnstile authenticator config.")
    else:
        config_id = create_turnstile_config(base, realm, token_value, turnstile["id"], site_key, secret_key)
        turnstile["authenticationConfig"] = config_id
        print("Created Turnstile authenticator config.")

    for item in execs:
        if item.get("providerId") == TURNSTILE_PROVIDER and item.get("level", 0) == 0:
            item["requirement"] = "REQUIRED"
            item["authenticationConfig"] = config_id

    top_level = [e for e in execs if e.get("level", 0) == 0]
    put_executions(base, realm, token_value, FORMS_ALIAS, top_level)
    print(f"Set Turnstile REQUIRED in '{FORMS_ALIAS}'.")


def remove_top_level_turnstile(base: str, realm: str, token_value: str) -> None:
    execs = get_executions(base, realm, token_value, FLOW_ALIAS)
    for item in execs:
        if item.get("providerId") == TURNSTILE_PROVIDER and item.get("level", 0) == 0:
            delete_execution(base, realm, token_value, item["id"])
            print("Removed top-level Turnstile execution (keeps forms subflow active).")


def bind_browser_flow(base: str, realm: str, token_value: str) -> None:
    request(
        "PUT",
        admin(base, realm, ""),
        token_value,
        {"browserFlow": FLOW_ALIAS},
    )
    print(f"Bound browser flow to '{FLOW_ALIAS}'.")


def main() -> None:
    realm = env("KEYCLOAK_REALM", "CyberVem")
    base = env("KEYCLOAK_URL", "http://127.0.0.1:8080").rstrip("/")
    admin_user = env("KEYCLOAK_ADMIN", "admin")
    admin_password = env("KEYCLOAK_ADMIN_PASSWORD", required=True)
    site_key = env("TURNSTILE_SITE_KEY", required=True)
    secret_key = env("TURNSTILE_SECRET_KEY", required=True)

    token_value = token(base, admin_user, admin_password)
    duplicate_browser_flow(base, realm, token_value)
    remove_top_level_turnstile(base, realm, token_value)
    configure_forms_flow(base, realm, token_value, site_key, secret_key)
    bind_browser_flow(base, realm, token_value)
    print(f"Turnstile single-page login configured for realm '{realm}'.")


if __name__ == "__main__":
    main()
