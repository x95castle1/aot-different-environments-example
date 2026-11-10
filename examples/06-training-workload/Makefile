# Example 06: train the AOT cache with a real workload (in the pipeline, against throwaway services),
# then measure it against a cache trained on startup only and against no cache.
include ../../make/common.mk

RUNS ?= 3

.PHONY: demo
demo: ## Train with the workload, then measure all three images in dev1 and write the report
	RUNS=$(RUNS) ./demo.sh

.PHONY: train
train: ## Only the training pipeline: -> workload-app:untrained, :context-trained, :workload-trained
	./training-pipeline.sh

.PHONY: workload
workload: ## Drive the request mix at a running instance: make workload URL=http://localhost:8602 N=300
	./run-workload.sh $(or $(URL),http://localhost:8602) $(or $(N),300) 1 | awk '{c[$$1]++; t+=$$2} END {for (k in c) printf "%s x%d  ", k, c[k]; printf "\ntotal %.3fs\n", t}'

.PHONY: stop
stop: ## Remove this example's containers and the training stack
	-@docker rm -f $$(docker ps -aq --filter 'name=^aot-06-') >/dev/null 2>&1; true
	-@docker compose -f training/compose.yml down -v >/dev/null 2>&1; true

.PHONY: clean
clean: stop ## Also remove the images
	-docker image rm workload-app:untrained workload-app:context-trained workload-app:workload-trained
