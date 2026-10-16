# Documentation gates. Documentation is the source of truth, so it is checked
# like code is.

.PHONY: docs-check docs-links docs-manifest docs-dashes

## docs-check: every documentation gate
docs-check: docs-links docs-manifest docs-dashes

## docs-links: no relative link in the docs points at a missing file
docs-links:
	@sh scripts/docs-links.sh

## docs-manifest: every file the website publishes still exists
docs-manifest:
	@sh scripts/docs-manifest-check.sh

## docs-dashes: no tracked text file contains an em dash
docs-dashes:
	@sh scripts/em-dash-check.sh
