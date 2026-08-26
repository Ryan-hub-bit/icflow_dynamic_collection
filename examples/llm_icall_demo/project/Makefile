CC ?= cc
CFLAGS ?= -O0 -g -Wall -Wextra -fno-pie
LDFLAGS ?= -no-pie
TEST_CASE_FILE ?= tests/native_cases.txt

.PHONY: all check clean

all: icall_demo

icall_demo: dispatcher.c
	$(CC) $(CFLAGS) $< $(LDFLAGS) -o $@

check: icall_demo
	@test -f "$(TEST_CASE_FILE)"
	@while read -r operation expected; do \
		case "$$operation" in ''|'#'*) continue ;; esac; \
		./icall_demo "$$operation" "$$expected"; \
	done < "$(TEST_CASE_FILE)"

clean:
	rm -f icall_demo icall_demo.orig *_icall.json *_ijump.json
