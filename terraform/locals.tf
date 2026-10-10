locals {
  labels = {
    env        = "prod"
    managed_by = "terraform"
    repo       = "project-infra"
  }

  cloudflare_cidrs = concat(
    data.cloudflare_ip_ranges.cf.ipv4_cidrs,
    data.cloudflare_ip_ranges.cf.ipv6_cidrs,
  )
}
