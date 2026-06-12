export type InlineNode =
	| { kind: "text"; text: string }
	| { kind: "bold"; text: string }
	| { kind: "code"; text: string };

export type MarkdownBlock =
	| { kind: "paragraph"; parts: InlineNode[] }
	| { kind: "quote"; parts: InlineNode[] }
	| { kind: "list"; items: InlineNode[][] }
	| { kind: "code"; code: string; language: string | null };

interface ParseResult {
	block: MarkdownBlock;
	nextIndex: number;
}

const FENCE_PATTERN = /^```\s*([\w-]+)?\s*$/;
const LIST_LINE_PATTERN = /^\s*[-*]\s+/;
const QUOTE_LINE_PATTERN = /^\s*>\s?/;

export function parseMarkdown(text: string): MarkdownBlock[] {
	const lines = text.replace(/\r\n/g, "\n").split("\n");
	const blocks: MarkdownBlock[] = [];
	let index = 0;

	while (index < lines.length) {
		const result = parseNextBlock(lines, index);

		if (!result) {
			index += 1;
			continue;
		}

		blocks.push(result.block);
		index = result.nextIndex;
	}

	return blocks;
}

function parseNextBlock(lines: string[], index: number): ParseResult | null {
	const line = lines[index];

	if (line.trim() === "") {
		return null;
	}

	if (FENCE_PATTERN.test(line)) {
		return parseCodeBlock(lines, index);
	}

	if (LIST_LINE_PATTERN.test(line)) {
		return parseListBlock(lines, index);
	}

	if (QUOTE_LINE_PATTERN.test(line)) {
		return parseQuoteBlock(lines, index);
	}

	return parseParagraphBlock(lines, index);
}

function parseCodeBlock(lines: string[], startIndex: number): ParseResult {
	const fence = lines[startIndex].match(FENCE_PATTERN);
	const codeLines: string[] = [];
	let index = startIndex + 1;

	while (index < lines.length && !lines[index].startsWith("```")) {
		codeLines.push(lines[index]);
		index += 1;
	}

	return {
		block: {
			kind: "code",
			code: codeLines.join("\n"),
			language: fence?.[1] ?? null,
		},
		nextIndex: index < lines.length ? index + 1 : index,
	};
}

function parseListBlock(lines: string[], startIndex: number): ParseResult {
	const items: InlineNode[][] = [];
	let index = startIndex;

	while (index < lines.length && LIST_LINE_PATTERN.test(lines[index])) {
		items.push(parseInline(lines[index].replace(LIST_LINE_PATTERN, "")));
		index += 1;
	}

	return { block: { kind: "list", items }, nextIndex: index };
}

function parseQuoteBlock(lines: string[], startIndex: number): ParseResult {
	const quoteLines: string[] = [];
	let index = startIndex;

	while (index < lines.length && QUOTE_LINE_PATTERN.test(lines[index])) {
		quoteLines.push(lines[index].replace(QUOTE_LINE_PATTERN, ""));
		index += 1;
	}

	return {
		block: { kind: "quote", parts: parseInline(quoteLines.join("\n")) },
		nextIndex: index,
	};
}

function parseParagraphBlock(lines: string[], startIndex: number): ParseResult {
	const paragraphLines: string[] = [];
	let index = startIndex;

	while (index < lines.length && !isParagraphBoundary(lines[index])) {
		paragraphLines.push(lines[index]);
		index += 1;
	}

	return {
		block: { kind: "paragraph", parts: parseInline(paragraphLines.join("\n")) },
		nextIndex: index,
	};
}

function isParagraphBoundary(line: string) {
	return (
		line.trim() === "" ||
		FENCE_PATTERN.test(line) ||
		LIST_LINE_PATTERN.test(line) ||
		QUOTE_LINE_PATTERN.test(line)
	);
}

function parseInline(text: string): InlineNode[] {
	const nodes: InlineNode[] = [];
	let index = 0;

	while (index < text.length) {
		const codeIndex = text.indexOf("`", index);
		const boldIndex = text.indexOf("**", index);
		const nextIndex = smallestPositive(codeIndex, boldIndex);

		if (nextIndex === -1) {
			pushText(nodes, text.slice(index));
			break;
		}

		pushText(nodes, text.slice(index, nextIndex));

		if (nextIndex === codeIndex) {
			index = pushInlineCode(nodes, text, nextIndex);
			continue;
		}

		index = pushInlineBold(nodes, text, nextIndex);
	}

	return nodes;
}

function pushInlineCode(nodes: InlineNode[], text: string, openIndex: number) {
	const closeIndex = text.indexOf("`", openIndex + 1);
	if (closeIndex === -1) {
		pushText(nodes, text.slice(openIndex));
		return text.length;
	}

	nodes.push({ kind: "code", text: text.slice(openIndex + 1, closeIndex) });
	return closeIndex + 1;
}

function pushInlineBold(nodes: InlineNode[], text: string, openIndex: number) {
	const closeIndex = text.indexOf("**", openIndex + 2);
	if (closeIndex === -1) {
		pushText(nodes, text.slice(openIndex));
		return text.length;
	}

	nodes.push({ kind: "bold", text: text.slice(openIndex + 2, closeIndex) });
	return closeIndex + 2;
}

function smallestPositive(first: number, second: number) {
	if (first === -1) {
		return second;
	}

	if (second === -1) {
		return first;
	}

	return Math.min(first, second);
}

function pushText(nodes: InlineNode[], text: string) {
	if (text.length > 0) {
		nodes.push({ kind: "text", text });
	}
}
