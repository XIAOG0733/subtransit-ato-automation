CC=clang
CFLAGS=-Wall -Wextra -O2 -fobjc-arc
FRAMEWORKS=-framework AppKit -framework Vision -framework CoreGraphics -framework ImageIO -framework Foundation

bin/subtransit-ato: ato.m
	mkdir -p bin
	$(CC) $(CFLAGS) ato.m -o $@ $(FRAMEWORKS)

clean:
	rm -rf bin

.PHONY: clean
