.PHONY: build test run seed clean tidy app-deps app-analyze app-web app-run

build:
	go build -o bin/server ./cmd/server
	go build -o bin/seed ./cmd/seed

test:
	go test ./...

run: build
	./bin/server

seed: build
	./bin/seed

tidy:
	go mod tidy

clean:
	rm -rf bin/ *.db *.db-journal

# ----- Flutter -----

app-deps:
	cd app && flutter pub get

app-analyze:
	cd app && flutter analyze

app-web:
	cd app && flutter build web --release --no-tree-shake-icons

# Run the Flutter app against the Go server on localhost:8765.
# Default device is Chrome; override with DEVICE=ios, web-server etc.
DEVICE ?= chrome
app-run:
	cd app && flutter run -d $(DEVICE)
