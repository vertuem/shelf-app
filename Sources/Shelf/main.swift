import AppKit

// A few command-line tools ship inside the app binary for contributors:
//   Shelf --version
//   Shelf --dump-pasteboard [name]     current pasteboard as a test fixture
//   Shelf --render-previews <folder>   offscreen renders of the UI for docs
//   Shelf --render-demo <file.gif>      the animated README demo
if CommandLineTools.run(CommandLine.arguments) {
    exit(0)
}
ShelfApp.main()
