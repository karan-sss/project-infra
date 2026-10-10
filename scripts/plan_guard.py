#!/usr/bin/env python3
"""Terraform plan guard (ADR-0010).

Usage: plan_guard.py plan.json   (plan.json = `terraform show -json tfplan`)

Fails (exit 1) when:
  * the monthly Hetzner cost of the planned end state exceeds BUDGET_EUR (gross, incl. VAT), or
  * a protected resource would be deleted or replaced and ALLOW_REPLACE != "true".

Env: HCLOUD_TOKEN (required), BUDGET_EUR (default 7.50), ALLOW_REPLACE,
     GITHUB_STEP_SUMMARY (optional, report is appended there too).
"""
import json
import os
import sys
import urllib.request

PROTECTED_TYPES = {"hcloud_server", "hcloud_primary_ip", "cloudflare_r2_bucket"}
PRICING_URL = "https://api.hetzner.cloud/v1/pricing"


def planned_resources(plan):
    """Yield every resource of the planned end state (root + child modules)."""
    stack = [plan.get("planned_values", {}).get("root_module", {})]
    while stack:
        module = stack.pop()
        yield from module.get("resources", [])
        stack.extend(module.get("child_modules", []))


def fetch_pricing(token):
    req = urllib.request.Request(PRICING_URL, headers={"Authorization": f"Bearer {token}"})
    with urllib.request.urlopen(req, timeout=20) as resp:
        return json.load(resp)["pricing"]


def monthly_price(prices, location):
    for p in prices:
        if p.get("location") == location:
            return float(p["price_monthly"]["gross"])
    raise LookupError(f"no price for location {location}")


def cost_lines(plan, pricing):
    server_prices = {s["name"]: s["prices"] for s in pricing["server_types"]}
    ip_prices = {p["type"]: p["prices"] for p in pricing.get("primary_ips", [])}
    lines = []
    for res in planned_resources(plan):
        v = res.get("values") or {}
        if res["type"] == "hcloud_server":
            stype, loc = v["server_type"], v["location"]
            lines.append((res["address"], f"{stype} @ {loc}", monthly_price(server_prices[stype], loc)))
        elif res["type"] == "hcloud_primary_ip":
            ip_type, loc = v["type"], v.get("location")
            price = monthly_price(ip_prices[ip_type], loc) if ip_type in ip_prices else 0.0
            lines.append((res["address"], f"primary {ip_type} @ {loc}", price))
    return lines


def destructive_changes(plan):
    out = []
    for rc in plan.get("resource_changes", []):
        actions = rc["change"]["actions"]
        if rc["type"] in PROTECTED_TYPES and "delete" in actions:
            out.append((rc["address"], "/".join(actions), rc.get("action_reason", "")))
    return out


def main():
    if len(sys.argv) != 2:
        sys.exit(__doc__)
    plan = json.load(open(sys.argv[1]))
    budget = float(os.environ.get("BUDGET_EUR", "7.50"))
    allow_replace = os.environ.get("ALLOW_REPLACE", "").lower() == "true"

    lines = cost_lines(plan, fetch_pricing(os.environ["HCLOUD_TOKEN"]))
    total = sum(price for _, _, price in lines)
    destructive = destructive_changes(plan)

    cost_ok = total <= budget
    replace_ok = not destructive or allow_replace

    md = ["## Plan guard", "", "### Monthly cost (Hetzner, gross, live pricing)", "",
          "| Resource | What | €/month |", "|---|---|---:|"]
    md += [f"| `{a}` | {w} | {p:.2f} |" for a, w, p in lines]
    md += [f"| **Total** | budget €{budget:.2f} | **{total:.2f}** {'✅' if cost_ok else '❌'} |", ""]
    if destructive:
        md += ["### ⛔ Destructive changes to protected resources", "",
               "| Resource | Actions | Reason |", "|---|---|---|"]
        md += [f"| `{a}` | {act} | {r} |" for a, act, r in destructive]
        md += ["", "Allowed by the `allow-replace` label." if allow_replace else
               "**Blocked.** Add the `allow-replace` label to this PR if this is intentional.", ""]
    else:
        md += ["No deletes or replacements of protected resources. ✅", ""]

    report = "\n".join(md)
    print(report)
    summary = os.environ.get("GITHUB_STEP_SUMMARY")
    if summary:
        with open(summary, "a") as f:
            f.write(report + "\n")

    sys.exit(0 if cost_ok and replace_ok else 1)


if __name__ == "__main__":
    main()
