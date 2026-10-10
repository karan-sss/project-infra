# All credentials come from environment variables set by CI:
#   HCLOUD_TOKEN, CLOUDFLARE_API_TOKEN,
#   TAILSCALE_OAUTH_CLIENT_ID, TAILSCALE_OAUTH_CLIENT_SECRET
provider "hcloud" {}

provider "cloudflare" {}

provider "tailscale" {
  tailnet = "-"
}
