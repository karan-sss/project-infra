# All credentials come from environment variables set by CI:
#   HCLOUD_TOKEN, CLOUDFLARE_API_TOKEN,
#   TAILSCALE_OAUTH_CLIENT_ID, TAILSCALE_OAUTH_CLIENT_SECRET,
#   GRAFANA_URL, GRAFANA_AUTH (service-account token, Alerting editor)
provider "hcloud" {}

provider "cloudflare" {}

provider "tailscale" {
  tailnet = "-"
}

provider "grafana" {}
