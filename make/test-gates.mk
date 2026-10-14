# Gates on the change itself rather than on the code.

.PHONY: test-check

## test-check: a change to Go, shell or UI source changed a test with it
test-check:
	@sh scripts/test-check.sh
