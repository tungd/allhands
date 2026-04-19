import type { JSX } from "solid-js";
import { For } from "solid-js";
import { Dynamic } from "solid-js/web";

type MarkdownContentProps = {
  text: string;
};

type MarkdownBlock =
  | { type: "heading"; level: 1 | 2 | 3 | 4 | 5 | 6; text: string }
  | { type: "paragraph"; text: string }
  | { type: "blockquote"; text: string }
  | { type: "unordered_list"; items: string[] }
  | { type: "ordered_list"; items: string[] }
  | { type: "code"; text: string; language?: string };

function isBlank(line: string): boolean {
  return line.trim().length === 0;
}

function startsBlock(line: string): boolean {
  return (
    /^#{1,6}\s+/.test(line) ||
    /^>\s?/.test(line) ||
    /^```/.test(line) ||
    /^[-*+]\s+/.test(line) ||
    /^\d+\.\s+/.test(line)
  );
}

function parseBlocks(markdown: string): MarkdownBlock[] {
  const normalized = markdown.replace(/\r\n/g, "\n");
  const lines = normalized.split("\n");
  const blocks: MarkdownBlock[] = [];
  let index = 0;

  while (index < lines.length) {
    const line = lines[index] ?? "";

    if (isBlank(line)) {
      index += 1;
      continue;
    }

    const heading = /^(#{1,6})\s+(.*)$/.exec(line);
    if (heading != null) {
      blocks.push({
        type: "heading",
        level: heading[1].length as MarkdownBlock & { type: "heading" }["level"],
        text: heading[2]
      });
      index += 1;
      continue;
    }

    const fence = /^```([\w-]+)?\s*$/.exec(line);
    if (fence != null) {
      const content: string[] = [];
      index += 1;
      while (index < lines.length && !/^```/.test(lines[index] ?? "")) {
        content.push(lines[index] ?? "");
        index += 1;
      }
      if (index < lines.length) {
        index += 1;
      }
      blocks.push({
        type: "code",
        text: content.join("\n"),
        language: fence[1]
      });
      continue;
    }

    if (/^>\s?/.test(line)) {
      const content: string[] = [];
      while (index < lines.length && /^>\s?/.test(lines[index] ?? "")) {
        content.push((lines[index] ?? "").replace(/^>\s?/, ""));
        index += 1;
      }
      blocks.push({ type: "blockquote", text: content.join("\n") });
      continue;
    }

    if (/^[-*+]\s+/.test(line)) {
      const items: string[] = [];
      while (index < lines.length) {
        const match = /^[-*+]\s+(.*)$/.exec(lines[index] ?? "");
        if (match == null) {
          break;
        }
        items.push(match[1]);
        index += 1;
      }
      blocks.push({ type: "unordered_list", items });
      continue;
    }

    if (/^\d+\.\s+/.test(line)) {
      const items: string[] = [];
      while (index < lines.length) {
        const match = /^\d+\.\s+(.*)$/.exec(lines[index] ?? "");
        if (match == null) {
          break;
        }
        items.push(match[1]);
        index += 1;
      }
      blocks.push({ type: "ordered_list", items });
      continue;
    }

    const paragraph: string[] = [];
    while (index < lines.length && !isBlank(lines[index] ?? "") && !startsBlock(lines[index] ?? "")) {
      paragraph.push(lines[index] ?? "");
      index += 1;
    }
    blocks.push({ type: "paragraph", text: paragraph.join("\n") });
  }

  return blocks;
}

function safeHref(href: string): string | null {
  return /^(https?:|mailto:)/i.test(href) ? href : null;
}

function renderText(text: string): JSX.Element[] {
  const parts = text.split("\n");
  const rendered: JSX.Element[] = [];

  parts.forEach((part, index) => {
    if (index > 0) {
      rendered.push(<br />);
    }
    if (part.length > 0) {
      rendered.push(part);
    }
  });

  return rendered;
}

function renderInline(text: string): JSX.Element[] {
  const tokenPattern =
    /(`([^`]+)`|\[([^\]]+)\]\(([^)]+)\)|\*\*([^*]+)\*\*|__([^_]+)__|\*([^*]+)\*|_([^_]+)_)/g;
  const rendered: JSX.Element[] = [];
  let cursor = 0;

  for (const match of text.matchAll(tokenPattern)) {
    const index = match.index ?? 0;
    if (index > cursor) {
      rendered.push(...renderText(text.slice(cursor, index)));
    }

    if (match[2] != null) {
      rendered.push(<code>{match[2]}</code>);
    } else if (match[3] != null && match[4] != null) {
      const href = safeHref(match[4]);
      if (href == null) {
        rendered.push(...renderText(match[0]));
      } else {
        rendered.push(
          <a href={href} rel="noreferrer" target="_blank">
            {renderInline(match[3])}
          </a>
        );
      }
    } else if (match[5] != null || match[6] != null) {
      rendered.push(<strong>{renderInline(match[5] ?? match[6] ?? "")}</strong>);
    } else if (match[7] != null || match[8] != null) {
      rendered.push(<em>{renderInline(match[7] ?? match[8] ?? "")}</em>);
    }

    cursor = index + match[0].length;
  }

  if (cursor < text.length) {
    rendered.push(...renderText(text.slice(cursor)));
  }

  return rendered;
}

function renderBlock(block: MarkdownBlock): JSX.Element {
  switch (block.type) {
    case "heading":
      return (
        <Dynamic component={`h${block.level}` as keyof JSX.IntrinsicElements}>
          {renderInline(block.text)}
        </Dynamic>
      );
    case "paragraph":
      return <p>{renderInline(block.text)}</p>;
    case "blockquote":
      return (
        <blockquote>
          <p>{renderInline(block.text)}</p>
        </blockquote>
      );
    case "unordered_list":
      return (
        <ul>
          <For each={block.items}>{(item) => <li>{renderInline(item)}</li>}</For>
        </ul>
      );
    case "ordered_list":
      return (
        <ol>
          <For each={block.items}>{(item) => <li>{renderInline(item)}</li>}</For>
        </ol>
      );
    case "code":
      return (
        <pre>
          <code>{block.text}</code>
        </pre>
      );
  }
}

export function MarkdownContent(props: MarkdownContentProps) {
  const blocks = () => parseBlocks(props.text);

  return <For each={blocks()}>{(block) => renderBlock(block)}</For>;
}
