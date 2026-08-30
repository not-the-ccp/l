.PHONY: all tools test clean
all tools:
	./build.sh tools
test:
	./test.sh
clean:
	./build.sh clean
