IMAGE ?= arquivo/arquivo-apache-httpd:test

.PHONY: build test

build:
	docker build -t $(IMAGE) .

test: build
	tests/smoke-test.sh $(IMAGE)
