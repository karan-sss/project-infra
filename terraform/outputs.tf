output "ipv4" {
  description = "Public IPv4 (reachable on 80/443 from Cloudflare only)."
  value       = hcloud_primary_ip.ipv4.ip_address
}

output "ipv6" {
  description = "Public IPv6 address of the server."
  value       = hcloud_server.main.ipv6_address
}

output "ssh_command" {
  description = "Admin SSH over Tailscale."
  value       = "ssh ${var.admin_username}@${var.server_name}"
}
