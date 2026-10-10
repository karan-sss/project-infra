# Terraform owns the whole tailnet policy (ADR-0008).
# - Your own devices (autogroup:member) keep full access, incl. laptop -> server.
# - CI runners (tag:ci, ephemeral) may only reach SSH on the server.
resource "tailscale_acl" "this" {
  overwrite_existing_content = true

  acl = jsonencode({
    tagOwners = {
      "tag:server" = ["autogroup:admin"]
      "tag:ci"     = ["autogroup:admin"]
    }
    grants = [
      {
        src = ["autogroup:member"]
        dst = ["*"]
        ip  = ["*"]
      },
      {
        src = ["tag:ci"]
        dst = ["tag:server"]
        ip  = ["tcp:22"]
      },
    ]
  })
}

# Single-use, short-lived key consumed by cloud-init on first boot.
# Tagged devices have node-key expiry disabled by default, so the server
# stays on the tailnet without further management.
resource "tailscale_tailnet_key" "server" {
  description         = "${var.server_name} first boot"
  reusable            = false
  ephemeral           = false
  preauthorized       = true
  expiry              = 3600
  tags                = ["tag:server"]
  recreate_if_invalid = "never"

  depends_on = [tailscale_acl.this]
}
