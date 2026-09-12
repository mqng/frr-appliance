SHELL := /bin/bash

.PHONY: lint build-vanilla build-vpp

lint:
	bash ci/static-check.sh

build-vanilla:
	bash ci/pipeline.sh vanilla

build-vpp:
	bash ci/pipeline.sh vpp
