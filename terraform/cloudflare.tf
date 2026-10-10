locals {
  web_records = {
    apex_a        = { name = var.domain, type = "A", content = hcloud_primary_ip.ipv4.ip_address }
    apex_aaaa     = { name = var.domain, type = "AAAA", content = hcloud_server.main.ipv6_address }
    wildcard_a    = { name = "*.${var.domain}", type = "A", content = hcloud_primary_ip.ipv4.ip_address }
    wildcard_aaaa = { name = "*.${var.domain}", type = "AAAA", content = hcloud_server.main.ipv6_address }
  }

  zone_settings = {
    ssl                      = "strict"
    always_use_https         = "on"
    min_tls_version          = "1.2"
    tls_1_3                  = "on"
    automatic_https_rewrites = "on"
  }
}

resource "cloudflare_dns_record" "web" {
  for_each = local.web_records

  zone_id = var.cloudflare_zone_id
  name    = each.value.name
  type    = each.value.type
  content = each.value.content
  proxied = true
  ttl     = 1
  comment = "managed by terraform (project-infra)"
}

# Created only once the Upptime Pages site exists, to avoid a dangling
# CNAME that someone else's Pages site could claim (subdomain takeover).
resource "cloudflare_dns_record" "status" {
  count = var.enable_status_page ? 1 : 0

  zone_id = var.cloudflare_zone_id
  name    = "status.${var.domain}"
  type    = "CNAME"
  content = "${var.github_user}.github.io"
  proxied = false
  ttl     = 300
  comment = "Upptime status page on GitHub Pages"
}

resource "cloudflare_zone_setting" "this" {
  for_each = local.zone_settings

  zone_id    = var.cloudflare_zone_id
  setting_id = each.key
  value      = each.value
}

# Free plan: up to 5 custom rules.
resource "cloudflare_ruleset" "waf_custom" {
  zone_id     = var.cloudflare_zone_id
  name        = "project-infra custom WAF"
  description = "Managed by terraform"
  kind        = "zone"
  phase       = "http_request_firewall_custom"

  rules = [
    {
      description = "Block common scanner paths"
      action      = "block"
      enabled     = true
      expression  = join(" or ", [for p in ["/wp-admin", "/wp-login.php", "/xmlrpc.php", "/.env", "/.git", "/phpmyadmin"] : "(http.request.uri.path contains \"${p}\")"])
    },
    {
      description = "Block empty User-Agent"
      action      = "block"
      enabled     = true
      expression  = "(http.user_agent eq \"\")"
    },
  ]
}

# Free plan: 1 rate-limiting rule, 10 s period and 10 s mitigation.
resource "cloudflare_ruleset" "rate_limit" {
  zone_id     = var.cloudflare_zone_id
  name        = "project-infra rate limit"
  description = "Managed by terraform"
  kind        = "zone"
  phase       = "http_ratelimit"

  rules = [
    {
      description = "Rate limit API paths per IP"
      action      = "block"
      enabled     = true
      expression  = "(http.request.uri.path contains \"/api/\")"
      ratelimit = {
        characteristics     = ["cf.colo.id", "ip.src"]
        period              = 10
        requests_per_period = 50
        mitigation_timeout  = 10
      }
    },
  ]
}

resource "cloudflare_web_analytics_site" "this" {
  account_id   = var.cloudflare_account_id
  zone_tag     = var.cloudflare_zone_id
  auto_install = true
}

resource "cloudflare_r2_bucket" "backups" {
  account_id = var.cloudflare_account_id
  name       = "project-infra-backups"
  location   = "EEUR"
}

# Anti-spoofing for a domain that never sends or receives email.
# Together with the existing _dmarc record (p=quarantine), receivers reject
# mail forged as @domain. Set var.no_email = false before adding a mail provider.
resource "cloudflare_dns_record" "spf_none" {
  count = var.no_email ? 1 : 0

  zone_id = var.cloudflare_zone_id
  name    = var.domain
  type    = "TXT"
  content = "\"v=spf1 -all\""
  ttl     = 3600
  comment = "managed by terraform: no mail is ever sent from this domain"
}

resource "cloudflare_dns_record" "null_mx" {
  count = var.no_email ? 1 : 0

  zone_id  = var.cloudflare_zone_id
  name     = var.domain
  type     = "MX"
  content  = "."
  priority = 0
  ttl      = 3600
  comment  = "managed by terraform: null MX (RFC 7505), domain accepts no mail"
}
