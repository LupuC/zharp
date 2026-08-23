# Zharp for macOS. Mirrors the Windows build's dotnet targets.
.PHONY: build run test check-shell app app-debug dmg icon clean release

build:          ## Debug build
	swift build

release:        ## Optimized build
	swift build -c release

run: build      ## Build and launch the app
	.build/debug/Zharp

test: check-shell ## Emulator smoke tests (exit code = failures)
	swift run ZharpCoreSmokeTests

check-shell:    ## Syntax-check the generated shell-integration templates
	./Scripts/check-shell-templates.sh

icon:           ## Regenerate Packaging/AppIcon.icns from the logo set
	./Scripts/make-icon.sh

app: icon       ## Assemble dist/Zharp.app (release)
	./Scripts/make-app.sh release

dmg: app        ## Package dist/Zharp-<version>.dmg for distribution
	./Scripts/make-dmg.sh

app-debug: icon ## Assemble dist/Zharp.app from the debug build
	./Scripts/make-app.sh debug

clean:
	rm -rf .build dist
