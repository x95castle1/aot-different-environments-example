# Example 04: build once, promote the same image by digest through dev1 -> qa1 -> prod1.
# Needs only a local registry (started automatically); no Config Server, Vault or Mongo.
include ../../make/common.mk

.PHONY: demo
demo: ## Build once, push, scan the image, promote by digest to dev1/qa1/prod1, compare
	REVISION=$(REVISION) ./demo.sh

.PHONY: status
status: ## Show the registry and the three environments (and which digest each runs)
	@docker compose ps --format 'table {{.Service}}\t{{.Image}}\t{{.Status}}\t{{.Ports}}'

.PHONY: stop
stop: ## Stop the registry and environments (the registry's images are kept in its volume)
	docker compose down --remove-orphans

.PHONY: clean
clean: ## Stop everything and delete the registry's storage
	docker compose down -v --remove-orphans
