.PHONY: lint
lint:
	@find . -type f -name Chart.yaml -not -path './.git/*' -exec sh -c 'for chart do helm lint "$${chart%/Chart.yaml}" || exit $$?; done' sh {} +
