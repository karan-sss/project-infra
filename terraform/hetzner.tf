resource "hcloud_ssh_key" "admin" {
  name       = "${var.admin_username}-admin"
  public_key = var.admin_ssh_pubkey
}

# Primary IPs are separate resources so the addresses survive a server rebuild.
resource "hcloud_primary_ip" "ipv4" {
  name              = "${var.server_name}-ipv4"
  type              = "ipv4"
  location          = var.location
  auto_delete       = false
  delete_protection = true
  labels            = local.labels
}

resource "hcloud_primary_ip" "ipv6" {
  name              = "${var.server_name}-ipv6"
  type              = "ipv6"
  location          = var.location
  auto_delete       = false
  delete_protection = true
  labels            = local.labels
}

data "cloudflare_ip_ranges" "cf" {}

# Primary perimeter (ADR-0006): web traffic only from Cloudflare, no public SSH.
resource "hcloud_firewall" "main" {
  name   = "${var.server_name}-fw"
  labels = local.labels

  rule {
    description = "ICMP"
    direction   = "in"
    protocol    = "icmp"
    source_ips  = ["0.0.0.0/0", "::/0"]
  }

  rule {
    description = "HTTP from Cloudflare"
    direction   = "in"
    protocol    = "tcp"
    port        = "80"
    source_ips  = local.cloudflare_cidrs
  }

  rule {
    description = "HTTPS from Cloudflare"
    direction   = "in"
    protocol    = "tcp"
    port        = "443"
    source_ips  = local.cloudflare_cidrs
  }

  rule {
    description = "Tailscale direct connections"
    direction   = "in"
    protocol    = "udp"
    port        = "41641"
    source_ips  = ["0.0.0.0/0", "::/0"]
  }

  dynamic "rule" {
    for_each = var.ssh_public_access ? [1] : []
    content {
      description = "BREAK-GLASS public SSH"
      direction   = "in"
      protocol    = "tcp"
      port        = "22"
      source_ips  = ["0.0.0.0/0", "::/0"]
    }
  }
}

resource "hcloud_server" "main" {
  name         = var.server_name
  server_type  = var.server_type
  image        = var.image
  location     = var.location
  ssh_keys     = [hcloud_ssh_key.admin.id]
  firewall_ids = [hcloud_firewall.main.id]
  labels       = local.labels

  public_net {
    ipv4_enabled = true
    ipv4         = hcloud_primary_ip.ipv4.id
    ipv6_enabled = true
    ipv6         = hcloud_primary_ip.ipv6.id
  }

  # sensitive() is mandatory: the rendered template contains the Tailscale
  # auth key, the admin password hash and the healthchecks ping key, and
  # Actions logs of this public repo are public (ADR-0014).
  user_data = sensitive(templatefile("${path.module}/templates/cloud-init.yaml.tftpl", {
    hostname            = var.server_name
    admin_username      = var.admin_username
    admin_ssh_pubkey    = var.admin_ssh_pubkey
    deploy_ssh_pubkey   = var.deploy_ssh_pubkey
    admin_password_hash = var.admin_password_hash
    hc_ping_key         = var.hc_ping_key
    ts_authkey          = tailscale_tailnet_key.server.key
    docker_apt_key      = file("${path.module}/templates/keys/docker.asc")
    tailscale_apt_key   = file("${path.module}/templates/keys/tailscale.asc")
  }))

  delete_protection  = true
  rebuild_protection = true

  lifecycle {
    # cloud-init only runs on first boot; changing these must never replace
    # the server. Rebuilds are deliberate (allow-replace label, ADR-0010).
    ignore_changes = [user_data, image, ssh_keys]
  }
}
