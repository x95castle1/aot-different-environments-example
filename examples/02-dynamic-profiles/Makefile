# Example 02: profiles decided at startup under Spring AOT, plus the @Profile pitfall. No external services needed.
include ../../make/common.mk

IMAGE := profiles-app:1.0.0

.PHONY: demo
demo: image ## Build, then run dev1/dev2/qa1/prod1 (+ debug, + AOT off) from one image and compare
	./demo.sh

.PHONY: image
image: ## Build the image (Spring AOT + AOT cache trained with the prod flags, offline)
	docker build -f $(ROOT)/docker/app.Dockerfile \
	  --build-arg MODULE=examples/02-dynamic-profiles/app --build-arg APP=profiles-app \
	  --build-arg REVISION=$(REVISION) -t $(IMAGE) $(ROOT)

.PHONY: run
run: ## Run one env on :8201: make run APP_ENV=qa APP_ENV_INDEX=1
	docker rm -f aot-02-profiles >/dev/null 2>&1 || true
	docker run -d --name aot-02-profiles -p 8201:8080 -e APP_ENV=$(or $(APP_ENV),dev) -e APP_ENV_INDEX=$(APP_ENV_INDEX) $(IMAGE)
	@sleep 2; curl -s localhost:8201/info/profiles | jq .

.PHONY: stop
stop: ## Remove this example's containers
	-@docker rm -f $$(docker ps -aq --filter 'name=^aot-02-') >/dev/null 2>&1; true

.PHONY: clean
clean: stop ## Remove containers and the image
	-docker image rm $(IMAGE)
