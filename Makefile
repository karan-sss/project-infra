TF := terraform -chdir=terraform

.PHONY: help fmt validate lint ssh tunnel logs

help: ## Show targets
	@grep -E '^[a-z-]+:.*## ' $(MAKEFILE_LIST) | awk -F':.*## ' '{printf "  %-10s %s\n", $$1, $$2}'

fmt: ## Format Terraform
	$(TF) fmt -recursive

validate: ## Validate Terraform without a backend
	$(TF) init -backend=false -input=false >/dev/null && $(TF) validate

lint: fmt validate ## fmt + validate + tflint
	cd terraform && tflint --init && tflint

ssh: ## SSH to the server over Tailscale
	ssh karan@core-01

tunnel: ## Forward Postgres (5432) and Redis (6379) over SSH
	ssh -N -L 5432:127.0.0.1:5432 -L 6379:127.0.0.1:6379 karan@core-01

logs: ## Tail a platform service: make logs s=caddy
	ssh karan@core-01 docker logs -f --tail 100 $(s)
