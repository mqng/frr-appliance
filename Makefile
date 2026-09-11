SHELL := /bin/bash

.PHONY: lint build-vanilla build-vpp

lint:
	@for f in $$(find ci scripts -type f -name '*.sh'); do bash -n $$f; done

build-vanilla:
	./ci/pipeline.sh vanilla

build-vpp:
	./ci/pipeline.sh vpp
