.PHONY: build clean

DIST_STAMP := dist/.build_stamp

$(DIST_STAMP): package.json package-lock.json vite.config.ts \
               $(wildcard src/*) $(wildcard src/**/*) $(wildcard *.html)
	npm ci && npm run build
	@touch $@

build: $(DIST_STAMP)

clean:
	rm -rf dist node_modules
