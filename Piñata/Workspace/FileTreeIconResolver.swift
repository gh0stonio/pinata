import AppKit

enum FileTreeIconKind: String, CaseIterable {
    case folder, file, swift, objectiveC, c, cpp, rust, go, python, ruby, php, java
    case kotlin, scala, dart, lua, elixir, erlang, haskell, javascript, typescript
    case react, vue, svelte, html, css, sass, shell, powershell, sql, graphql
    case json, yaml, toml, xml, markdown, text, config, git, docker, make
    case archive, image, video, audio, font, pdf, spreadsheet, presentation
    case database, binary, lock, key, certificate, terraform, nix, protobuf
    case wasm, log, environment, notebook, package
}

struct FileTreeIconDescriptor: Equatable {
    let kind: FileTreeIconKind
}

@MainActor
enum FileTreeIconResolver {
    static let supportedFileNameCount = fileNames.count
    static let supportedSuffixCount = suffixes.count

    static func descriptor(for name: String, isDirectory: Bool) -> FileTreeIconDescriptor {
        if isDirectory { return FileTreeIconDescriptor(kind: .folder) }
        let normalized = name.lowercased()
        if normalized == ".env" || normalized.hasPrefix(".env.") {
            return FileTreeIconDescriptor(kind: .environment)
        }
        if let kind = fileNames[normalized] {
            return FileTreeIconDescriptor(kind: kind)
        }
        if let suffix = normalized.split(separator: ".", omittingEmptySubsequences: true).last,
           let kind = suffixes[String(suffix)] {
            return FileTreeIconDescriptor(kind: kind)
        }
        return FileTreeIconDescriptor(kind: .file)
    }

    static func image(for descriptor: FileTreeIconDescriptor) -> NSImage? {
        if let image = images[descriptor.kind] { return image }
        let name = appearance(for: descriptor.kind).symbol
        let image = NSImage(systemSymbolName: name, accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 13, weight: .regular))
            ?? NSImage(systemSymbolName: "doc.plaintext", accessibilityDescription: nil)?
                .withSymbolConfiguration(.init(pointSize: 13, weight: .regular))
        images[descriptor.kind] = image
        return image
    }

    static func tintColor(for descriptor: FileTreeIconDescriptor) -> NSColor {
        guard AppTheme.usesColoredFileIcons else { return AppTheme.secondaryText }
        return switch appearance(for: descriptor.kind).tint {
        case .neutral: AppTheme.secondaryText
        case .blue: .systemBlue
        case .cyan: .systemCyan
        case .green: .systemGreen
        case .indigo: .systemIndigo
        case .orange: .systemOrange
        case .pink: .systemPink
        case .purple: .systemPurple
        case .red: .systemRed
        case .teal: .systemTeal
        case .yellow: .systemYellow
        }
    }

    private enum Tint {
        case neutral, blue, cyan, green, indigo, orange, pink, purple, red, teal, yellow
    }

    private struct Appearance {
        let symbol: String
        let tint: Tint
    }

    private static var images: [FileTreeIconKind: NSImage] = [:]

    private static func appearance(for kind: FileTreeIconKind) -> Appearance {
        switch kind {
        case .folder: Appearance(symbol: "folder", tint: .neutral)
        case .file: Appearance(symbol: "doc.plaintext", tint: .neutral)
        case .swift: Appearance(symbol: "swift", tint: .orange)
        case .objectiveC: Appearance(symbol: "apple.logo", tint: .blue)
        case .c: Appearance(symbol: "c.square", tint: .blue)
        case .cpp: Appearance(symbol: "plus.forwardslash.minus", tint: .blue)
        case .rust: Appearance(symbol: "gearshape.2", tint: .orange)
        case .go: Appearance(symbol: "figure.run", tint: .cyan)
        case .python: Appearance(symbol: "curlybraces.square", tint: .yellow)
        case .ruby: Appearance(symbol: "diamond", tint: .red)
        case .php: Appearance(symbol: "p.square", tint: .indigo)
        case .java: Appearance(symbol: "cup.and.saucer", tint: .orange)
        case .kotlin: Appearance(symbol: "k.square", tint: .purple)
        case .scala: Appearance(symbol: "stairs", tint: .red)
        case .dart: Appearance(symbol: "scope", tint: .cyan)
        case .lua: Appearance(symbol: "moon", tint: .blue)
        case .elixir: Appearance(symbol: "drop", tint: .purple)
        case .erlang: Appearance(symbol: "e.square", tint: .red)
        case .haskell: Appearance(symbol: "function", tint: .purple)
        case .javascript: Appearance(symbol: "j.square", tint: .yellow)
        case .typescript: Appearance(symbol: "t.square", tint: .blue)
        case .react: Appearance(symbol: "atom", tint: .cyan)
        case .vue: Appearance(symbol: "v.square", tint: .green)
        case .svelte: Appearance(symbol: "flame", tint: .orange)
        case .html: Appearance(symbol: "chevron.left.forwardslash.chevron.right", tint: .orange)
        case .css: Appearance(symbol: "paintbrush", tint: .blue)
        case .sass: Appearance(symbol: "paintpalette", tint: .pink)
        case .shell: Appearance(symbol: "terminal", tint: .green)
        case .powershell: Appearance(symbol: "greaterthan.square", tint: .blue)
        case .sql: Appearance(symbol: "cylinder", tint: .cyan)
        case .graphql: Appearance(symbol: "point.3.connected.trianglepath.dotted", tint: .pink)
        case .json: Appearance(symbol: "curlybraces", tint: .yellow)
        case .yaml: Appearance(symbol: "list.bullet.indent", tint: .red)
        case .toml: Appearance(symbol: "tablecells", tint: .orange)
        case .xml: Appearance(symbol: "chevron.left.forwardslash.chevron.right", tint: .orange)
        case .markdown: Appearance(symbol: "text.document", tint: .blue)
        case .text: Appearance(symbol: "doc.text", tint: .neutral)
        case .config: Appearance(symbol: "gearshape", tint: .neutral)
        case .git: Appearance(symbol: "g.circle", tint: .orange)
        case .docker: Appearance(symbol: "shippingbox.fill", tint: .cyan)
        case .make: Appearance(symbol: "hammer", tint: .orange)
        case .archive: Appearance(symbol: "doc.zipper", tint: .yellow)
        case .image: Appearance(symbol: "photo", tint: .purple)
        case .video: Appearance(symbol: "film", tint: .pink)
        case .audio: Appearance(symbol: "waveform", tint: .purple)
        case .font: Appearance(symbol: "textformat", tint: .red)
        case .pdf: Appearance(symbol: "doc.richtext", tint: .red)
        case .spreadsheet: Appearance(symbol: "tablecells", tint: .green)
        case .presentation: Appearance(symbol: "rectangle.on.rectangle.angled", tint: .orange)
        case .database: Appearance(symbol: "cylinder.split.1x2", tint: .cyan)
        case .binary: Appearance(symbol: "01.square", tint: .neutral)
        case .lock: Appearance(symbol: "lock", tint: .yellow)
        case .key: Appearance(symbol: "key", tint: .yellow)
        case .certificate: Appearance(symbol: "checkmark.seal", tint: .green)
        case .terraform: Appearance(symbol: "square.3.layers.3d", tint: .purple)
        case .nix: Appearance(symbol: "snowflake", tint: .blue)
        case .protobuf: Appearance(symbol: "network", tint: .orange)
        case .wasm: Appearance(symbol: "cpu", tint: .purple)
        case .log: Appearance(symbol: "list.bullet.rectangle", tint: .neutral)
        case .environment: Appearance(symbol: "leaf", tint: .green)
        case .notebook: Appearance(symbol: "book.closed", tint: .orange)
        case .package: Appearance(symbol: "shippingbox", tint: .yellow)
        }
    }

    private static let fileNames = map([
        (.git, [".gitignore", ".gitattributes", ".gitmodules", ".gitkeep", ".mailmap"]),
        (.docker, ["dockerfile", "containerfile", "docker-compose.yml", "docker-compose.yaml", "compose.yml", "compose.yaml"]),
        (.make, ["makefile", "gnumakefile", "cmakelists.txt", "justfile", "taskfile.yml", "taskfile.yaml"]),
        (.package, ["package.json", "package-lock.json", "yarn.lock", "pnpm-lock.yaml", "bun.lock", "bun.lockb", "cargo.toml", "cargo.lock", "go.mod", "go.sum", "gemfile", "gemfile.lock", "podfile", "podfile.lock", "requirements.txt", "pyproject.toml", "poetry.lock", "pipfile", "pipfile.lock", "composer.json", "composer.lock", "mix.exs", "mix.lock"]),
        (.typescript, ["tsconfig.json", "tsconfig.base.json", "deno.json", "deno.jsonc"]),
        (.javascript, ["jsconfig.json", ".babelrc", ".babelrc.json", ".eslintrc", ".eslintrc.json", ".prettierrc", ".prettierrc.json"]),
        (.config, [".editorconfig", ".npmrc", ".yarnrc", ".nvmrc", ".tool-versions", "procfile", "vite.config.js", "vite.config.ts", "webpack.config.js", "webpack.config.ts"]),
        (.shell, [".bashrc", ".bash_profile", ".zshrc", ".zprofile", ".profile"]),
        (.markdown, ["readme", "license", "changelog", "contributing", "code_of_conduct"]),
    ])

    private static let suffixes = map([
        (.swift, ["swift"]),
        (.objectiveC, ["m", "mm"]),
        (.c, ["c", "h"]),
        (.cpp, ["cc", "cpp", "cxx", "c++", "hh", "hpp", "hxx", "h++", "ipp", "inl"]),
        (.rust, ["rs"]),
        (.go, ["go"]),
        (.python, ["py", "pyw", "pyi", "pyx", "pxd", "pxi"]),
        (.ruby, ["rb", "rake", "gemspec"]),
        (.php, ["php", "phtml", "php3", "php4", "php5", "phps"]),
        (.java, ["java"]),
        (.kotlin, ["kt", "kts"]),
        (.scala, ["scala", "sc"]),
        (.dart, ["dart"]),
        (.lua, ["lua"]),
        (.elixir, ["ex", "exs", "eex", "leex", "heex"]),
        (.erlang, ["erl", "hrl"]),
        (.haskell, ["hs", "lhs"]),
        (.javascript, ["js", "mjs", "cjs"]),
        (.typescript, ["ts", "mts", "cts"]),
        (.react, ["jsx", "tsx"]),
        (.vue, ["vue"]),
        (.svelte, ["svelte"]),
        (.html, ["html", "htm", "xhtml", "shtml", "astro"]),
        (.css, ["css"]),
        (.sass, ["scss", "sass", "less", "styl", "stylus"]),
        (.shell, ["sh", "bash", "zsh", "fish", "ksh", "csh", "tcsh"]),
        (.powershell, ["ps1", "psm1", "psd1"]),
        (.sql, ["sql", "ddl", "dml"]),
        (.graphql, ["graphql", "gql"]),
        (.json, ["json", "jsonc", "json5", "jsonl", "ndjson", "geojson", "webmanifest"]),
        (.yaml, ["yaml", "yml"]),
        (.toml, ["toml"]),
        (.xml, ["xml", "xsd", "xsl", "xslt", "dtd", "plist", "storyboard", "xib"]),
        (.markdown, ["md", "markdown", "mdown", "mkdn", "mdx", "rst", "adoc", "asciidoc", "org"]),
        (.text, ["txt", "text", "nfo", "rtf"]),
        (.config, ["cfg", "conf", "config", "ini", "properties", "prefs", "editorconfig"]),
        (.git, ["patch", "diff"]),
        (.make, ["mk", "mak"]),
        (.archive, ["zip", "tar", "gz", "tgz", "bz2", "tbz", "tbz2", "xz", "txz", "7z", "rar", "zst", "lz", "lz4", "cab", "iso", "dmg", "pkg", "deb", "rpm", "apk", "whl"]),
        (.image, ["png", "jpg", "jpeg", "gif", "webp", "bmp", "tif", "tiff", "ico", "icns", "avif", "heic", "heif", "psd", "ai", "eps", "raw", "cr2", "nef", "orf", "svg"]),
        (.video, ["mp4", "mov", "mkv", "avi", "webm", "m4v", "mpeg", "mpg", "wmv", "flv", "ogv", "3gp"]),
        (.audio, ["mp3", "wav", "flac", "aac", "ogg", "oga", "m4a", "wma", "aiff", "aif", "opus", "midi", "mid"]),
        (.font, ["ttf", "otf", "woff", "woff2", "eot"]),
        (.pdf, ["pdf"]),
        (.spreadsheet, ["csv", "tsv", "xls", "xlsx", "ods", "numbers"]),
        (.presentation, ["ppt", "pptx", "odp", "keynote"]),
        (.database, ["db", "sqlite", "sqlite3", "mdb", "accdb", "parquet", "avro", "orc"]),
        (.binary, ["bin", "dat", "obj", "o", "a", "so", "dylib", "dll", "exe", "app", "pyc", "pyo"]),
        (.lock, ["lock"]),
        (.key, ["pem", "key", "ppk", "asc", "gpg"]),
        (.certificate, ["crt", "cer", "cert", "der", "p12", "pfx"]),
        (.terraform, ["tf", "tfvars", "hcl"]),
        (.nix, ["nix"]),
        (.protobuf, ["proto", "capnp", "thrift"]),
        (.wasm, ["wasm", "wat"]),
        (.log, ["log"]),
        (.environment, ["env"]),
        (.notebook, ["ipynb"]),
        (.package, ["nuspec", "podspec"]),
    ])

    private static func map(
        _ groups: [(FileTreeIconKind, [String])]
    ) -> [String: FileTreeIconKind] {
        var result: [String: FileTreeIconKind] = [:]
        for (kind, names) in groups {
            for name in names { result[name] = kind }
        }
        return result
    }
}
