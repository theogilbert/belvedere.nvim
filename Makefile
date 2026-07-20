.PHONY: ci

ci:
	nvim --headless -u NONE \
		-c "runtime! plugin/plenary.vim" \
		-c "PlenaryBustedDirectory spec/" \
		-c "qa!"
