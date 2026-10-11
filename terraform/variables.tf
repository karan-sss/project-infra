variable "domain" {
  description = "Apex domain served by the platform."
  type        = string
}

variable "cloudflare_zone_id" {
  description = "Cloudflare zone ID of var.domain."
  type        = string
}

variable "cloudflare_account_id" {
  description = "Cloudflare account ID (R2, Web Analytics)."
  type        = string
}

variable "location" {
  description = "Hetzner location."
  type        = string
  default     = "fsn1"
}

variable "server_type" {
  description = "Hetzner server type."
  type        = string
  default     = "cax11"
}

variable "image" {
  description = "Hetzner OS image."
  type        = string
  default     = "ubuntu-24.04"
}

variable "server_name" {
  description = "Server name; also its Tailscale/MagicDNS hostname."
  type        = string
  default     = "core-01"
}

variable "admin_username" {
  description = "Human admin user (sudo)."
  type        = string
  default     = "karan"
}

variable "admin_ssh_pubkey" {
  description = "SSH public key of the human admin."
  type        = string
}

variable "deploy_ssh_pubkey" {
  description = "SSH public key used by CI as the deployer user."
  type        = string
}

variable "admin_password_hash" {
  description = "SHA-512 crypt hash (openssl passwd -6) for Hetzner web-console break-glass login only."
  type        = string
  sensitive   = true
}

variable "hc_ping_key" {
  description = "healthchecks.io project ping key."
  type        = string
  sensitive   = true
}

variable "ssh_public_access" {
  description = "Break-glass: open TCP 22 to the internet. Keep false; access is via Tailscale."
  type        = bool
  default     = false
}

variable "github_user" {
  description = "GitHub user that hosts the Upptime status page."
  type        = string
  default     = "karan-sss"
}

variable "enable_status_page" {
  description = "Create status.<domain> CNAME to GitHub Pages. Enable only once the Pages site exists (avoids subdomain takeover)."
  type        = bool
  default     = false
}

variable "no_email" {
  description = "Domain never sends or receives email: publish SPF -all and a null MX (RFC 7505) so nobody can send mail as @domain."
  type        = bool
  default     = true
}

variable "alert_email" {
  description = "Where Grafana Cloud sends alert emails."
  type        = string
  sensitive   = true
}

variable "grafana_prometheus_name" {
  description = "Name of the Grafana Cloud stack's hosted Prometheus data source (grafanacloud-<stack>-prom)."
  type        = string
}
