BIN = bin/vzz
SRC = src/vzz.scm

$(BIN): $(SRC)
	mkdir -p bin
	csc -O2 $(SRC) -o $(BIN)

test: $(BIN)
	test/smoke-test.sh $(BIN)

clean:
	rm -rf bin src/*.o src/*.link

.PHONY: test clean
