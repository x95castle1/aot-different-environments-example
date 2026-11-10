# Example 06: train the AOT cache with a real workload (in the pipeline, against throwaway services),
# then measure it against a cache trained on startup only and against no cache, and run it as dev1 and prod1.
#
#   training/compose.yml   the throwaway training stack + the "trainer" (the untrained image recording a cache)
#   compose.yml            the environments dev1 and prod1 on the shared infrastructure
include ../../make/common.mk

RUNS ?= 3

.PHONY: demo
demo: ## Train with the workload, time all three images in dev1, run the trained image as dev1 + prod1, report
	RUNS=$(RUNS) ./demo.sh

.PHONY: train
train: ## Only the training pipeline: -> workload-app:untrained, :context-trained, :workload-trained
	./training-pipeline.sh

.PHONY: envs
envs: ## Run dev1 (:8602) and prod1 (:8603) from compose.yml (IMAGE=workload-app:<tag>, default workload-trained)
	$(MAKE) -C $(ROOT)/infra up
	$(ROOT)/infra/bootstrap.sh workload-app dev1 prod1
	docker compose up -d --force-recreate
	@echo "dev1  http://localhost:8602/info/runtime   prod1 http://localhost:8603/info/runtime"

.PHONY: workload
workload: ## Drive the request mix at a running instance: make workload URL=http://localhost:8602 N=300
	./run-workload.sh $(or $(URL),http://localhost:8602) $(or $(N),300) 1 | awk '{c[$$1]++; t+=$$2} END {for (k in c) printf "%s x%d  ", k, c[k]; printf "\ntotal %.3fs\n", t}'

.PHONY: stop
stop: ## Stop the environments and remove the training stack
	-@docker compose down --remove-orphans >/dev/null 2>&1; true
	-@docker compose -f training/compose.yml down -v >/dev/null 2>&1; true

.PHONY: clean
clean: stop ## Also remove the images
	-docker image rm workload-app:untrained workload-app:context-trained workload-app:workload-trained
