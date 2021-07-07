CC = $(CROSS_COMPILE)gcc

.PHONY: clean

nvmemfuse: nvmemfuse.c
	$(CC) -o '$@' '$<'

clean:
	rm nvmemfuse
