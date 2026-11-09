# Example 05: all four questions at once. Four environments, one image, real Config Server/Vault/Mongo.
#
# Typical demo:  make start  ->  make verify  ->  make aot-check  ->  make startup-compare  ->  make fail-fast-demo
include ../../make/common.mk

APPS := app-dev1 app-dev2 app-qa1 app-prod1
ENVS := dev1 dev2 qa1 prod1
ENV ?= dev1

.PHONY: demo
demo: start verify aot-check ## Full demo: start everything, verify every env, check AOT-cache use

.PHONY: image
image: ## Build the ONE app image (Spring AOT + AOT-cache training, offline)
	docker compose build

.PHONY: infra
infra: ## Start the shared Config Server, Vault and MongoDB
	$(MAKE) -C $(ROOT)/infra up

.PHONY: bootstrap
bootstrap: ## Per-env Mongo users, Vault secrets/policies/tokens (rotates on every run)
	$(ROOT)/infra/bootstrap.sh demo-app $(ENVS)

.PHONY: apps
apps: ## Start dev1, dev2, qa1, prod1 from the same image
	docker compose up -d --force-recreate $(APPS)
	@echo "dev1 http://localhost:8081  dev2 http://localhost:8082  qa1 http://localhost:8083  prod1 http://localhost:8084"

.PHONY: start
start: image infra bootstrap apps ## Everything: build image, start infra, bootstrap, start all four envs

.PHONY: verify
verify: ## Check each env: profiles, config, secrets, Mongo, data isolation, same image
	./scripts/verify.sh

.PHONY: aot-check
aot-check: ## Which envs' JVMs used the AOT cache (prod/dev1/qa1: yes, dev2/ZGC: falls back)
	./scripts/aot-check.sh

.PHONY: startup-compare
startup-compare: ## Startup time: AOT cache + Spring AOT vs Spring AOT only vs neither
	./scripts/startup-compare.sh

.PHONY: fail-fast-demo
fail-fast-demo: ## Startup refuses to run when Config Server/Vault are unreachable or the token is wrong
	./scripts/fail-fast-demo.sh

.PHONY: report
report: ## Print one env's startup report (ENV=dev1|dev2|qa1|prod1)
	@docker compose logs app-$(ENV) | sed -n '/===== startup report/,/=====================/p'

.PHONY: logs
logs: ## Follow a container's logs (fzf picker; or ENV=dev1|dev2|qa1|prod1 to skip it)
	@$(ROOT)/scripts/logs.sh $(if $(filter command line,$(origin ENV)),aot-05-all-together-app-$(ENV)-1)

.PHONY: status
status: ## Show this example's containers and the image each one runs
	@docker compose ps --format 'table {{.Service}}\t{{.Image}}\t{{.Status}}\t{{.Ports}}'

.PHONY: stop
stop: ## Stop this example's apps (the shared infra keeps running: make -C ../../infra stop)
	docker compose down

.PHONY: clean
clean: stop ## Stop the apps and remove the image
	-docker image rm demo-app:1.0.0
