# State lives in a private Cloudflare R2 bucket (ADR-0005).
# The account-specific endpoint is supplied at init time so it isn't committed:
#   terraform init -backend-config=backend.hcl
# where backend.hcl contains:
#   endpoints = { s3 = "https://<ACCOUNT_ID>.r2.cloudflarestorage.com" }
# Credentials come from AWS_ACCESS_KEY_ID / AWS_SECRET_ACCESS_KEY (R2 S3 keys).
terraform {
  backend "s3" {
    bucket       = "project-infra-tfstate"
    key          = "prod/terraform.tfstate"
    region       = "auto"
    use_lockfile = true

    use_path_style              = true
    skip_credentials_validation = true
    skip_region_validation      = true
    skip_requesting_account_id  = true
    skip_metadata_api_check     = true
    skip_s3_checksum            = true
  }
}
