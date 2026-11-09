# Shared infrastructure for examples 03 and 05: Config Server, Vault, MongoDB.
include ../make/common.mk

COMPOSE := docker compose -f $(ROOT)/infra/compose.yml

.PHONY: up
up: ## Start Config Server, Vault and MongoDB and wait until healthy
	$(COMPOSE) up -d --wait

.PHONY: bootstrap
bootstrap: ## Per-env credentials: make bootstrap APP=demo-app ENVS="dev1 qa1"
	@[ -n "$(APP)" ] && [ -n "$(ENVS)" ] || { echo 'usage: make bootstrap APP=<app> ENVS="<env> ..."'; exit 2; }
	$(ROOT)/infra/bootstrap.sh $(APP) $(ENVS)

.PHONY: status
status: ## Show infrastructure containers
	@$(COMPOSE) ps --format 'table {{.Service}}\t{{.Image}}\t{{.Status}}\t{{.Ports}}'

.PHONY: stop
stop: ## Stop the infrastructure (Vault is in-memory: bootstrap again after the next start)
	$(COMPOSE) down

.PHONY: clean
clean: ## Stop and delete volumes and all generated secrets
	$(COMPOSE) down -v --remove-orphans
	rm -rf $(ROOT)/.secrets
