.PHONY: lean lean-bootstrap

lean:
	./scripts/gen_lean.sh

lean-bootstrap:
	./scripts/gen_lean.sh --bootstrap
