# Example 03: Config Server, Vault and MongoDB contacted at startup, never at build time.
# Uses the shared infrastructure in ../../infra (started automatically by `make demo`).
include ../../make/common.mk

IMAGE := connections-app:1.0.0

.PHONY: demo
demo: ## Offline build, start dev1, rotate its secret, then break each dependency
	./demo.sh

.PHONY: image
image: ## Build the image (no network for Spring AOT or JDK AOT-cache training)
	docker build -f $(ROOT)/docker/app.Dockerfile \
	  --build-arg MODULE=examples/03-startup-connections/app --build-arg APP=connections-app \
	  --build-arg REVISION=$(REVISION) -t $(IMAGE) $(ROOT)

.PHONY: start
start: image ## Start infra + dev1 on :8301 without the rest of the demo
	$(MAKE) -C $(ROOT)/infra up
	$(ROOT)/infra/bootstrap.sh connections-app dev1
	docker compose up -d --force-recreate app-dev1
	@echo "http://localhost:8301/info/connections"

.PHONY: logs
logs: ## Follow dev1's logs
	docker compose logs -f app-dev1

.PHONY: stop
stop: ## Stop this example's app (shared infra keeps running: make -C ../../infra stop)
	docker compose down --remove-orphans

.PHONY: clean
clean: stop ## Stop the app and remove the image
	-docker image rm $(IMAGE)
