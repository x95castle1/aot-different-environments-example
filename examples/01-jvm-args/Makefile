# Example 01: the same image started with different JVM flags. No external services needed.
include ../../make/common.mk

IMAGE := jvm-args-app:1.0.0
RUNS ?= 5

.PHONY: demo
demo: image ## Build, then run every JVM-flag scenario and print the cache/startup table
	RUNS=$(RUNS) ./demo.sh

.PHONY: image
image: ## Build the image (Spring AOT + AOT cache trained with the prod flags, offline)
	docker build -f $(ROOT)/docker/app.Dockerfile \
	  --build-arg MODULE=examples/01-jvm-args/app --build-arg APP=jvm-args-app \
	  --build-arg REVISION=$(REVISION) -t $(IMAGE) $(ROOT)

.PHONY: run
run: ## Run it once on :8101 with your own flags: make run FLAGS="-XX:+UseG1GC -Xmx128m"
	docker rm -f aot-01-jvm-args >/dev/null 2>&1 || true
	docker run -d --name aot-01-jvm-args -p 8101:8080 $(if $(FLAGS),-e JDK_JAVA_OPTIONS="$(FLAGS)") $(IMAGE)
	@sleep 2; curl -s localhost:8101/info/jvm | jq .

.PHONY: stop
stop: ## Remove this example's containers
	-@docker rm -f $$(docker ps -aq --filter 'name=^aot-01-') >/dev/null 2>&1; true

.PHONY: clean
clean: stop ## Remove containers and the image
	-docker image rm $(IMAGE)
