import AppKit

enum EditorLanguage: Equatable {
    case plain, swift, javascript, typescript, json, yaml, markdown, shell, python, go, rust, cFamily, html, css, xml, sql, toml, ini, dockerfile, graphql, ruby, kotlin, java, csharp, lua, php

    init(path: String) {
        let url = URL(fileURLWithPath: path)
        let fileName = url.lastPathComponent.lowercased()
        if fileName == "dockerfile" {
            self = .dockerfile
            return
        }
        if fileName == "makefile" || fileName == "gemfile" || fileName == "rakefile" {
            self = .shell
            return
        }
        if fileName == ".env" || fileName.hasPrefix(".env.") {
            self = .ini
            return
        }
        switch url.pathExtension.lowercased() {
        case "swift": self = .swift
        case "js", "jsx", "mjs", "cjs": self = .javascript
        case "ts", "tsx": self = .typescript
        case "json", "jsonc", "json5": self = .json
        case "yml", "yaml": self = .yaml
        case "md", "markdown", "mdx": self = .markdown
        case "sh", "bash", "zsh", "fish", "shell", "ps1": self = .shell
        case "py", "pyi": self = .python
        case "go": self = .go
        case "rs": self = .rust
        case "c", "h", "cc", "cpp", "cxx", "hpp", "hxx", "hh", "c++", "m", "mm": self = .cFamily
        case "html", "htm", "vue", "svelte", "astro": self = .html
        case "css", "scss", "sass", "less": self = .css
        case "xml", "svg", "plist": self = .xml
        case "sql": self = .sql
        case "toml": self = .toml
        case "ini", "cfg", "conf", "properties": self = .ini
        case "graphql", "gql": self = .graphql
        case "rb", "rake": self = .ruby
        case "kt", "kts": self = .kotlin
        case "java": self = .java
        case "cs": self = .csharp
        case "lua": self = .lua
        case "php": self = .php
        case "dockerfile": self = .dockerfile
        default: self = .plain
        }
    }
}

struct SyntaxToken: Equatable {
    enum Kind: Equatable {
        case comment, string, keyword, number, type, property, function, constant, decorator, attribute, variable, `operator`, markup, heading, emphasis, link, code
    }

    let range: NSRange
    let kind: Kind
}

struct EditorSyntaxPalette: Equatable {
    let background: UInt32
    let foreground: UInt32
    let comment: UInt32
    let string: UInt32
    let keyword: UInt32
    let number: UInt32
    let type: UInt32
    let property: UInt32
    let function: UInt32
    let constant: UInt32
    let decorator: UInt32
    let attribute: UInt32
    let variable: UInt32
    let `operator`: UInt32
    let markup: UInt32
    let heading: UInt32
    let emphasis: UInt32
    let link: UInt32
    let code: UInt32

    var backgroundColor: NSColor { Self.color(background) }
    var foregroundColor: NSColor { Self.color(foreground) }

    func color(for kind: SyntaxToken.Kind) -> NSColor {
        let value = switch kind {
        case .comment: comment
        case .string: string
        case .keyword: keyword
        case .number: number
        case .type: type
        case .property: property
        case .function: function
        case .constant: constant
        case .decorator: decorator
        case .attribute: attribute
        case .variable: variable
        case .operator: `operator`
        case .markup: markup
        case .heading: heading
        case .emphasis: emphasis
        case .link: link
        case .code: code
        }
        return Self.color(value)
    }

    private static func color(_ hex: UInt32) -> NSColor {
        NSColor(
            srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
            green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255,
            alpha: 1
        )
    }
}

extension EditorSyntaxPalette {
    static func pinata(appTheme: ThemePreference) -> Self {
        if appTheme == .dark {
            return Self(
                background: appTheme.palette.background,
                foreground: appTheme.palette.primaryText,
                comment: 0x7C8793,
                string: 0x8FD18F,
                keyword: 0xFF8C82,
                number: 0xD6A8FF,
                type: 0x6EC8FF,
                property: 0x77D9E8,
                function: 0xB9A5FF,
                constant: 0xFFCC66,
                decorator: 0x5DE4C7,
                attribute: 0x76D6FF,
                variable: 0xD2B4FF,
                operator: 0xE5B6FF,
                markup: 0xFFD447,
                heading: 0xFFB86C,
                emphasis: 0xFF9CCB,
                link: 0x76BEFF,
                code: 0xE6C56D
            )
        }
        return Self(
            background: appTheme.palette.background,
            foreground: appTheme.palette.primaryText,
            comment: 0x78818A,
            string: 0x287A3B,
            keyword: 0xB13F37,
            number: 0x7A4BA3,
            type: 0x126D9A,
            property: 0x167887,
            function: 0x634BA1,
            constant: 0xA65F00,
            decorator: 0x0D8072,
            attribute: 0x1765B0,
            variable: 0x7950A4,
            operator: 0x8A3D9E,
            markup: 0x9A6A00,
            heading: 0xA64C00,
            emphasis: 0xAA3567,
            link: 0x1765B0,
            code: 0x806000
        )
    }
}

@MainActor
final class SyntaxHighlighter {
    static let maximumCharacters = 250_000

    private let language: EditorLanguage
    private var pendingHighlight: DispatchWorkItem?

    init(path: String) {
        language = EditorLanguage(path: path)
    }

    func schedule(in textView: NSTextView) {
        pendingHighlight?.cancel()
        let work = DispatchWorkItem { [weak self, weak textView] in
            guard let self, let textView else { return }
            self.apply(to: textView)
        }
        pendingHighlight = work
        DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(100), execute: work)
    }

    func apply(to textView: NSTextView) {
        guard let storage = textView.textStorage else { return }
        let settings = UserSettingsStore().load()
        let palette = EditorSyntaxPalette.pinata(appTheme: settings.theme)
        let fullRange = NSRange(location: 0, length: storage.length)
        let font = textView.font ?? .monospacedSystemFont(ofSize: 13, weight: .regular)
        let base: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: palette.foregroundColor]
        storage.beginEditing()
        storage.setAttributes(base, range: fullRange)
        if storage.length <= Self.maximumCharacters {
            SyntaxTokenizer.tokens(in: storage.string, language: language).forEach { token in
                storage.addAttribute(.foregroundColor, value: palette.color(for: token.kind), range: token.range)
                switch token.kind {
                case .heading:
                    storage.addAttribute(.font, value: NSFont.monospacedSystemFont(ofSize: 14, weight: .bold), range: token.range)
                case .emphasis:
                    storage.addAttribute(.font, value: NSFontManager.shared.convert(font, toHaveTrait: .italicFontMask), range: token.range)
                default:
                    break
                }
            }
        }
        storage.endEditing()
        textView.typingAttributes = base
    }
}

enum SyntaxTokenizer {
    private static let neverPattern = #"(?!x)x"#
    private static let commonOperators = #"(?:===|!==|>>>|<<=|>>=|=>|==|!=|<=|>=|&&|\|\||\+\+|--|\+=|-=|\*=|/=|%=|\?\?|[+\-*\/%=<>!&|^~])"#
    private static let quotedStrings = #"(?s)(?:\"(?:\\.|[^\"\\])*\"|'(?:\\.|[^'\\])*')"#
    private static let scriptStrings = #"(?s)(?:`(?:\\.|[^`\\])*`|\"(?:\\.|[^\"\\])*\"|'(?:\\.|[^'\\])*')"#
    private static let tripleStrings = #"(?s)(?:\"\"\".*?\"\"\"|'''[\s\S]*?'''|\"(?:\\.|[^\"\\])*\"|'(?:\\.|[^'\\])*')"#

    static func tokens(in string: String, language: EditorLanguage) -> [SyntaxToken] {
        switch language {
        case .plain:
            []
        case .markdown:
            markdownTokens(in: string)
        case .json:
            jsonTokens(in: string)
        case .yaml:
            tokens(in: string, comments: #"#.*$"#, keywords: #"\b(?:as|if|else|elif|for|in|not|and|or|is|when|end)\b"#, types: #"\b(?:str|int|float|bool|map|list|object)\b"#, properties: #"(?m)^\s*[A-Za-z0-9_.-]+(?=\s*:)"#, constants: #"\b(?:true|false|null|yes|no|on|off)\b"#, operators: commonOperators)
        case .shell:
            tokens(in: string, comments: #"#.*$"#, keywords: #"\b(?:if|then|else|elif|fi|for|while|in|do|done|case|esac|function|export|local|readonly|return|select|until|time)\b"#, constants: #"\b(?:true|false)\b"#, variables: #"\$(?:\{[A-Za-z_][A-Za-z0-9_]*\}|[A-Za-z_][A-Za-z0-9_]*|\d+|[?@#*])"#, attributes: #"(?m)--[A-Za-z][A-Za-z0-9-]*"#, operators: #"(?:\|\||&&|>>|<<|\|&|[|;&><])"#)
        case .python:
            tokens(in: string, comments: #"#.*$"#, keywords: #"\b(?:as|assert|async|await|break|class|continue|def|del|elif|else|except|finally|for|from|global|if|import|in|is|lambda|nonlocal|not|or|and|pass|raise|return|try|while|with|yield|match|case)\b"#, types: #"\b(?:bool|bytes|complex|dict|float|frozenset|int|list|object|set|str|tuple|type|Any)\b"#, properties: #"(?<=\.)[A-Za-z_][A-Za-z0-9_]*"#, constants: #"\b(?:False|None|NotImplemented|Ellipsis|True)\b"#, decorators: #"(?m)^\s*@[A-Za-z_][A-Za-z0-9_.]*"#, variables: #"\b(?:self|cls)\b"#, operators: commonOperators, strings: tripleStrings)
        case .swift:
            tokens(in: string, comments: #"//.*$|/\*[\s\S]*?\*/"#, keywords: #"\b(?:actor|as|async|await|break|case|catch|class|continue|default|defer|deinit|do|else|enum|extension|fallthrough|for|func|guard|if|import|in|init|inout|internal|is|let|open|operator|private|protocol|public|repeat|rethrows|return|static|struct|subscript|super|switch|throw|throws|try|typealias|var|where|while|some|any|associatedtype|consuming|borrowing|isolated|nonisolated)\b"#, types: #"\b(?:Any|Bool|Character|Data|Date|Decimal|Double|Error|Float|Int|Never|ObjectIdentifier|Result|String|UInt|URL|UUID|Void)\b"#, properties: #"(?<=\.)[A-Za-z_][A-Za-z0-9_]*"#, constants: #"\b(?:false|nil|true)\b"#, decorators: #"@[A-Za-z_][A-Za-z0-9_.]*"#, variables: #"\b(?:self|super)\b"#, attributes: #"#(?:if|elseif|else|endif|available|colorLiteral|imageLiteral|selector)\b"#, operators: commonOperators, strings: tripleStrings)
        case .javascript, .typescript:
            tokens(in: string, comments: #"//.*$|/\*[\s\S]*?\*/"#, keywords: #"\b(?:async|await|break|case|catch|class|const|continue|default|delete|do|else|export|extends|finally|for|from|function|if|import|in|instanceof|interface|let|new|of|private|protected|public|return|static|switch|throw|try|type|typeof|var|void|while|with|yield|implements|declare|namespace|abstract|keyof|readonly|as|satisfies)\b"#, types: language == .typescript ? #"\b(?:any|bigint|boolean|never|number|object|string|symbol|unknown|void)\b"# : #"\b(?:Array|Boolean|Date|Error|Function|JSON|Map|Math|Number|Object|Promise|RegExp|Set|String|Symbol)\b"#, properties: #"(?<=\.)[A-Za-z_$][A-Za-z0-9_$]*"#, constants: #"\b(?:false|Infinity|NaN|null|true|undefined)\b"#, decorators: #"@[A-Za-z_$][A-Za-z0-9_$.]*"#, variables: #"\b(?:arguments|this|super)\b"#, operators: commonOperators, strings: scriptStrings)
        case .go:
            tokens(in: string, comments: #"//.*$|/\*[\s\S]*?\*/"#, keywords: #"\b(?:break|case|chan|const|continue|default|defer|else|fallthrough|for|func|go|goto|if|import|interface|map|package|range|return|select|struct|switch|type|var)\b"#, types: #"\b(?:bool|byte|complex64|complex128|error|float32|float64|int|int8|int16|int32|int64|rune|string|uint|uint8|uint16|uint32|uint64|uintptr)\b"#, properties: #"(?<=\.)[A-Za-z_][A-Za-z0-9_]*"#, constants: #"\b(?:false|iota|nil|true)\b"#, variables: #"\b(?:append|cap|close|copy|delete|len|make|new|panic|print|println|recover)\b"#, operators: commonOperators)
        case .rust:
            tokens(in: string, comments: #"//.*$|/\*[\s\S]*?\*/"#, keywords: #"\b(?:as|async|await|break|const|continue|crate|dyn|else|enum|extern|fn|for|if|impl|in|let|loop|match|mod|move|mut|pub|ref|return|static|struct|super|trait|type|unsafe|use|where|while|become|box|do|final|macro|override|priv|typeof|unsized|virtual|yield)\b"#, types: #"\b(?:bool|char|f32|f64|i8|i16|i32|i64|i128|isize|Self|str|u8|u16|u32|u64|u128|usize)\b"#, properties: #"(?<=\.)[A-Za-z_][A-Za-z0-9_]*"#, constants: #"\b(?:false|None|Some|true)\b"#, decorators: #"#\[[^\]]+\]"#, variables: #"\b(?:self|Self)\b"#, operators: commonOperators)
        case .cFamily:
            tokens(in: string, comments: #"//.*$|/\*[\s\S]*?\*/"#, keywords: #"\b(?:alignas|alignof|asm|auto|break|case|catch|class|const|constexpr|continue|default|delete|do|else|enum|explicit|extern|for|friend|goto|if|inline|namespace|new|noexcept|nullptr|operator|private|protected|public|return|sizeof|static|struct|switch|template|this|throw|try|typedef|typename|union|using|virtual|void|volatile|while|override|final)\b"#, types: #"\b(?:bool|char|char8_t|char16_t|char32_t|double|float|int|int8_t|int16_t|int32_t|int64_t|long|short|size_t|string|uint8_t|uint16_t|uint32_t|uint64_t|unsigned|wchar_t)\b"#, properties: #"(?:(?<=\.)|(?<=->))[A-Za-z_][A-Za-z0-9_]*"#, constants: #"\b(?:false|NULL|nullptr|true)\b"#, decorators: #"(?m)^\s*#\s*[A-Za-z_][A-Za-z0-9_]*"#, operators: commonOperators)
        case .html, .xml:
            markupTokens(in: string, embedded: language == .html)
        case .css:
            tokens(in: string, comments: #"/\*[\s\S]*?\*/"#, keywords: #"\b(?:important|inherit|initial|none|solid|transparent|unset|auto|block|flex|grid|inline|relative|absolute|fixed|sticky)\b"#, properties: #"\b(?:--)?[a-zA-Z][a-zA-Z0-9-]*(?=\s*:)"#, constants: #"#[0-9a-fA-F]{3,8}\b"#, variables: #"--[a-zA-Z][a-zA-Z0-9-]*"#, operators: commonOperators)
        case .sql:
            tokens(in: string, comments: #"--.*$|/\*[\s\S]*?\*/"#, keywords: #"(?i)\b(?:SELECT|FROM|WHERE|JOIN|LEFT|RIGHT|FULL|INNER|OUTER|CROSS|ON|INSERT|INTO|VALUES|UPDATE|SET|DELETE|CREATE|ALTER|DROP|TABLE|INDEX|VIEW|ORDER|BY|GROUP|HAVING|LIMIT|OFFSET|AS|AND|OR|NOT|NULL|DISTINCT|UNION|ALL|WITH|RECURSIVE|RETURNING|CASE|WHEN|THEN|ELSE|END|BEGIN|COMMIT|ROLLBACK|GRANT|REVOKE|PRIMARY|KEY|FOREIGN|REFERENCES|CONSTRAINT|DEFAULT|CHECK|UNIQUE)\b"#, types: #"(?i)\b(?:BIGINT|BOOLEAN|CHAR|DATE|DECIMAL|DOUBLE|FLOAT|INT|INTEGER|JSON|NUMERIC|REAL|SMALLINT|TEXT|TIME|TIMESTAMP|UUID|VARCHAR)\b"#, properties: #"(?<=\.)[A-Za-z_][A-Za-z0-9_]*"#, constants: #"(?i)\b(?:FALSE|NULL|TRUE)\b"#, operators: commonOperators)
        case .toml:
            tokens(in: string, comments: #"#.*$"#, keywords: neverPattern, properties: #"(?m)^\s*[A-Za-z0-9_.-]+(?=\s*=)"#, constants: #"\b(?:true|false)\b"#, attributes: #"(?m)^\s*\[\[?[^\]]+\]\]?"#, operators: #"="#)
        case .ini:
            tokens(in: string, comments: #"[#;].*$"#, keywords: neverPattern, properties: #"(?m)^\s*[^=:\n]+(?=\s*[:=])"#, constants: #"\b(?:false|no|off|on|true|yes)\b"#, attributes: #"(?m)^\s*\[[^\]\n]+\]"#, operators: #"[:=]"#)
        case .dockerfile:
            tokens(in: string, comments: #"#.*$"#, keywords: #"(?i)\b(?:ADD|ARG|CMD|COPY|ENTRYPOINT|ENV|EXPOSE|FROM|HEALTHCHECK|LABEL|ONBUILD|RUN|SHELL|STOPSIGNAL|USER|VOLUME|WORKDIR|AS)\b"#, properties: #"(?m)--[A-Za-z][A-Za-z0-9-]*"#, variables: #"\$\{?[A-Za-z_][A-Za-z0-9_]*\}?"#, operators: #"(?:&&|\|\||\\)"#)
        case .graphql:
            tokens(in: string, comments: #"#.*$"#, keywords: #"\b(?:query|mutation|subscription|fragment|on|schema|scalar|type|interface|union|enum|input|extend|directive|implements|repeatable)\b"#, types: #"\b(?:Boolean|Float|ID|Int|String)\b"#, properties: #"(?m)^\s*[A-Za-z_][A-Za-z0-9_]*(?=\s*:)|(?<=\.)[A-Za-z_][A-Za-z0-9_]*"#, constants: #"\b(?:false|null|true)\b"#, operators: #"[!$&:=|@]"#, strings: #"(?s)(?:\"\"\".*?\"\"\"|\"(?:\\.|[^\"\\])*\")"#)
        case .ruby:
            tokens(in: string, comments: #"#.*$"#, keywords: #"\b(?:alias|and|begin|break|case|class|def|defined|do|else|elsif|end|ensure|for|if|in|module|next|not|or|redo|rescue|retry|return|self|super|then|undef|unless|until|when|while|yield|require|include|extend|private|protected|public)\b"#, types: #"\b[A-Z][A-Za-z0-9_]*\b"#, properties: #"(?<=\.)[A-Za-z_][A-Za-z0-9_!?=]*"#, constants: #"\b(?:false|nil|true)\b"#, decorators: #"(?m)^\s*attr_(?:reader|writer|accessor)\b"#, variables: #"(?:@@|@|\$)[A-Za-z_][A-Za-z0-9_]*"#, operators: commonOperators)
        case .kotlin:
            tokens(in: string, comments: #"//.*$|/\*[\s\S]*?\*/"#, keywords: #"\b(?:as|break|by|catch|class|constructor|continue|data|do|else|enum|false|field|file|final|finally|for|fun|if|import|in|init|interface|internal|is|lateinit|noinline|object|open|operator|out|override|package|private|protected|public|reified|return|sealed|super|suspend|tailrec|this|throw|true|try|typealias|typeof|val|var|vararg|when|where|while)\b"#, types: #"\b(?:Any|Boolean|Byte|Char|Double|Float|Int|Long|Nothing|Short|String|Unit|UByte|UInt|ULong|UShort)\b"#, properties: #"(?<=\.)[A-Za-z_][A-Za-z0-9_]*"#, constants: #"\b(?:false|null|true)\b"#, decorators: #"@[A-Za-z_][A-Za-z0-9_.]*"#, variables: #"\b(?:this|super)\b"#, operators: commonOperators)
        case .java:
            tokens(in: string, comments: #"//.*$|/\*[\s\S]*?\*/"#, keywords: #"\b(?:abstract|assert|break|case|catch|class|const|continue|default|do|else|enum|extends|final|finally|for|goto|if|implements|import|instanceof|interface|native|new|package|private|protected|public|return|static|strictfp|super|switch|synchronized|this|throw|throws|transient|try|volatile|while)\b"#, types: #"\b(?:boolean|byte|char|class|double|float|int|long|Object|short|String|void)\b"#, properties: #"(?<=\.)[A-Za-z_][A-Za-z0-9_]*"#, constants: #"\b(?:false|null|true)\b"#, decorators: #"@[A-Za-z_][A-Za-z0-9_.]*"#, variables: #"\b(?:this|super)\b"#, operators: commonOperators)
        case .csharp:
            tokens(in: string, comments: #"//.*$|/\*[\s\S]*?\*/"#, keywords: #"\b(?:abstract|as|async|await|base|break|case|catch|checked|class|const|continue|default|delegate|do|else|enum|event|explicit|extern|finally|fixed|for|foreach|goto|if|implicit|in|interface|internal|is|lock|namespace|new|object|operator|out|override|params|private|protected|public|readonly|ref|return|sealed|sizeof|stackalloc|static|struct|switch|this|throw|try|typeof|unchecked|unsafe|using|virtual|void|volatile|while|var)\b"#, types: #"\b(?:bool|byte|char|decimal|double|float|int|long|nint|nuint|object|string|short|uint|ulong|ushort|Task|String)\b"#, properties: #"(?<=\.)[A-Za-z_][A-Za-z0-9_]*"#, constants: #"\b(?:false|null|true)\b"#, decorators: #"\[[A-Za-z_][A-Za-z0-9_.]*(?:\([^\]]*\))?\]"#, variables: #"\b(?:this|base)\b"#, operators: commonOperators)
        case .lua:
            tokens(in: string, comments: #"--.*$|--\[\[[\s\S]*?\]\]"#, keywords: #"\b(?:and|break|do|else|elseif|end|for|function|goto|if|in|local|not|or|repeat|return|then|until|while)\b"#, types: #"\b(?:coroutine|debug|io|math|os|string|table|utf8)\b"#, properties: #"(?<=\.)[A-Za-z_][A-Za-z0-9_]*"#, constants: #"\b(?:false|nil|true)\b"#, variables: #"\b(?:self|_ENV|_G)\b"#, operators: commonOperators)
        case .php:
            tokens(in: string, comments: #"//.*$|#.*$|/\*[\s\S]*?\*/"#, keywords: #"\b(?:abstract|and|array|as|break|callable|case|catch|class|clone|const|continue|declare|default|die|do|echo|else|elseif|empty|enddeclare|endfor|endforeach|endif|endswitch|endwhile|eval|exit|extends|final|finally|for|foreach|function|global|goto|if|implements|include|include_once|instanceof|insteadof|interface|isset|list|namespace|new|or|print|private|protected|public|require|require_once|return|static|switch|throw|trait|try|unset|use|var|while|xor|yield)\b"#, types: #"\b(?:bool|callable|float|int|iterable|mixed|never|null|object|resource|string|void)\b"#, properties: #"(?:(?<=->)|(?<=::))[A-Za-z_][A-Za-z0-9_]*"#, constants: #"\b(?:FALSE|NULL|TRUE)\b"#, variables: #"\$[A-Za-z_][A-Za-z0-9_]*"#, operators: commonOperators, strings: scriptStrings)
        }
    }

    private static func tokens(
        in string: String,
        comments: String? = nil,
        keywords: String,
        types: String? = nil,
        properties: String? = nil,
        constants: String? = nil,
        decorators: String? = nil,
        variables: String? = nil,
        attributes: String? = nil,
        operators: String? = nil,
        strings: String = quotedStrings
    ) -> [SyntaxToken] {
        let stringTokens = matches(strings, in: string, kind: .string)
        let commentTokens = (comments.map { matches($0, in: string, kind: .comment) } ?? [])
            .filter { comment in !stringTokens.contains { intersects(comment.range, $0.range) } }
        let protected = stringTokens + commentTokens
        var result: [SyntaxToken] = []

        func append(_ pattern: String?, kind: SyntaxToken.Kind) {
            guard let pattern else { return }
            result += matches(pattern, in: string, kind: kind)
                .filter { token in !protected.contains { intersects(token.range, $0.range) } }
        }

        append(operators, kind: .operator)
        append(#"(?<![A-Za-z0-9_])(?:0[xX][0-9a-fA-F](?:_?[0-9a-fA-F])*|0[bB][01](?:_?[01])*|0[oO][0-7](?:_?[0-7])*|\d(?:_?\d)*(?:\.\d(?:_?\d)*)?(?:[eE][+-]?\d(?:_?\d)*)?)(?![A-Za-z0-9_])"#, kind: .number)
        append(properties, kind: .property)
        append(types, kind: .type)
        append(#"\b[A-Za-z_$][A-Za-z0-9_$]*(?=\s*\()"#, kind: .function)
        append(keywords, kind: .keyword)
        append(constants, kind: .constant)
        append(decorators, kind: .decorator)
        append(attributes, kind: .attribute)
        append(variables, kind: .variable)
        result += stringTokens
        result += commentTokens
        return result
    }

    private static func jsonTokens(in string: String) -> [SyntaxToken] {
        let strings = matches(quotedStrings, in: string, kind: .string)
        let comments = matches(#"//.*$|/\*[\s\S]*?\*/"#, in: string, kind: .comment)
            .filter { comment in !strings.contains { intersects(comment.range, $0.range) } }
        var result = matches(#"-?(?:0[xX][0-9a-fA-F]+|\d+(?:\.\d+)?(?:[eE][+-]?\d+)?)"#, in: string, kind: .number)
            .filter { token in !strings.contains { intersects(token.range, $0.range) } }
        result += matches(#"\b(?:true|false|null)\b"#, in: string, kind: .constant)
            .filter { token in !strings.contains { intersects(token.range, $0.range) } }
        result += strings
        result += matches(#"\"(?:\\.|[^\"\\])*\"(?=\s*:)"#, in: string, kind: .property)
        result += comments
        return result
    }

    private static func markupTokens(in string: String, embedded: Bool) -> [SyntaxToken] {
        let comments = matches(#"<!--[\s\S]*?-->"#, in: string, kind: .comment)
        let strings = matches(#"\"(?:\\.|[^\"\\])*\"|'(?:\\.|[^'\\])*'"#, in: string, kind: .string)
        let protected = comments + strings
        var result = matches(#"<!DOCTYPE[^>]*>|</?[A-Za-z][^>]*>"#, in: string, kind: .markup)
            .filter { token in !protected.contains { intersects(token.range, $0.range) } }
        result += matches(#"\b[A-Za-z_:][-A-Za-z0-9_:.]*(?=\s*=)"#, in: string, kind: .property)
            .filter { token in !protected.contains { intersects(token.range, $0.range) } }
        result += matches(#"&(?:amp|apos|gt|lt|quot|nbsp|#\d+|#x[0-9a-fA-F]+);"#, in: string, kind: .constant)
            .filter { token in !protected.contains { intersects(token.range, $0.range) } }
        result += strings
        result += comments
        if embedded {
            result += embeddedTokens(in: string, tag: "script", language: .javascript)
            result += embeddedTokens(in: string, tag: "style", language: .css)
        }
        return result
    }

    private static func embeddedTokens(in string: String, tag: String, language: EditorLanguage) -> [SyntaxToken] {
        guard let expression = try? NSRegularExpression(
            pattern: "(?is)<\(tag)\\b[^>]*>(.*?)</\(tag)\\s*>"
        ) else { return [] }
        let range = NSRange(string.startIndex..., in: string)
        var result: [SyntaxToken] = []
        for match in expression.matches(in: string, range: range) {
            let bodyRange = match.range(at: 1)
            guard bodyRange.location != NSNotFound else { continue }
            let body = (string as NSString).substring(with: bodyRange)
            result += tokens(in: body, language: language).map {
                SyntaxToken(range: NSRange(location: bodyRange.location + $0.range.location, length: $0.range.length), kind: $0.kind)
            }
        }
        return result
    }

    private static func markdownTokens(in string: String) -> [SyntaxToken] {
        let fences = matches(#"(?m)^\s*(`{3,}|~{3,})[^\n]*$"#, in: string, kind: .code)
        var protectedRanges: [NSRange] = []
        var fencedBodies: [(range: NSRange, language: EditorLanguage)] = []
        var index = 0
        while index < fences.count {
            let opening = fences[index]
            let openingText = (string as NSString).substring(with: opening.range)
            let trimmed = openingText.trimmingCharacters(in: .whitespacesAndNewlines)
            let marker = String(trimmed.prefix(while: { $0 == "`" || $0 == "~" }))
            let markerCharacter = marker.first
            var closingIndex: Int?
            if index + 1 < fences.count {
                for candidateIndex in (index + 1)..<fences.count {
                    let candidateText = (string as NSString).substring(with: fences[candidateIndex].range)
                    let candidateTrimmed = candidateText.trimmingCharacters(in: .whitespacesAndNewlines)
                    let candidateMarker = String(candidateTrimmed.prefix(while: { $0 == "`" || $0 == "~" }))
                    if candidateMarker.first == markerCharacter,
                       candidateMarker.count >= marker.count,
                       candidateTrimmed.dropFirst(candidateMarker.count).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        closingIndex = candidateIndex
                        break
                    }
                }
            }

            let closing = closingIndex.map { fences[$0] }
            let bodyEnd = closing?.range.location ?? string.utf16.count
            let bodyStart = NSMaxRange(opening.range)
            if bodyStart <= bodyEnd {
                let bodyRange = NSRange(location: bodyStart, length: bodyEnd - bodyStart)
                let info = trimmed
                    .dropFirst(marker.count)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                    .split(whereSeparator: { $0 == " " || $0 == "\t" })
                    .first
                    .map(String.init) ?? ""
                fencedBodies.append((bodyRange, EditorLanguage(path: "file.\(info)")))
            }
            let protectedEnd = closing.map { NSMaxRange($0.range) } ?? string.utf16.count
            protectedRanges.append(NSRange(location: opening.range.location, length: protectedEnd - opening.range.location))
            index = closingIndex.map { $0 + 1 } ?? fences.count
        }

        var result: [SyntaxToken] = []
        func append(_ pattern: String, kind: SyntaxToken.Kind) {
            result += matches(pattern, in: string, kind: kind)
                .filter { token in !protectedRanges.contains { intersects(token.range, $0) } }
        }

        append(#"(?s)\A---\r?\n.*?\r?\n---\s*(?:\n|$)"#, kind: .markup)
        append(#"(?m)^\s*#{1,6}(?:\s+.*?\s*#*\s*)?$"#, kind: .heading)
        append(#"(?m)^\s{0,3}>.*$"#, kind: .markup)
        append(#"(?m)^\s*(?:[-+*]|\d+[.)])\s+(?:\[[ xX]\]\s+)?"#, kind: .markup)
        append(#"(?m)^\s*(?:[-*_]\s*){3,}$"#, kind: .markup)
        append(#"(?m)^\s*\|?.*\|\s*$"#, kind: .markup)
        append(#"(?m)^\s*\|?(?:\s*:?-{3,}:?\s*\|)+\s*$"#, kind: .markup)
        append(#"!?(?:\[[^\]\n]+\]\([^\)\n]+\)|\[[^\]\n]+\]\[[^\]\n]*\]|<https?://[^>]+>|\[\^[^\]]+\])"#, kind: .link)
        append(#"<(?=[A-Za-z][^>]*>)[^>]+>"#, kind: .markup)
        append(#"`{1,3}[^`\n]+`{1,3}"#, kind: .code)
        append(#"(?<!\*)\*\*[^*\n]+\*\*|__[^_\n]+__|~~[^~\n]+~~"#, kind: .emphasis)
        append(#"(?<!\*)\*[^*\n]+\*|(?<!_)_[^_\n]+_"#, kind: .emphasis)
        result += fences
        for body in fencedBodies {
            let source = (string as NSString).substring(with: body.range)
            result += tokens(in: source, language: body.language).map {
                SyntaxToken(range: NSRange(location: body.range.location + $0.range.location, length: $0.range.length), kind: $0.kind)
            }
        }
        return result
    }

    private static func matches(_ pattern: String, in string: String, kind: SyntaxToken.Kind) -> [SyntaxToken] {
        guard let expression = try? NSRegularExpression(pattern: pattern, options: [.anchorsMatchLines]) else { return [] }
        let range = NSRange(string.startIndex..., in: string)
        return expression.matches(in: string, range: range).map { SyntaxToken(range: $0.range, kind: kind) }
    }

    private static func intersects(_ lhs: NSRange, _ rhs: NSRange) -> Bool {
        NSIntersectionRange(lhs, rhs).length > 0
    }
}
