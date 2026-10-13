import { foldForSearch } from "../data/arabic";
import { ImportError } from "./model";

/**
 * Bytes of an uploaded file as text: UTF-8 (with or without a BOM), UTF-16 with a
 * BOM (Excel's "Unicode text"), or Windows-1256, which Excel on Arabic Windows uses
 * for "CSV (comma delimited)".
 */
export function decodeText(bytes: ArrayBuffer | Uint8Array): string {
  const b = bytes instanceof Uint8Array ? bytes : new Uint8Array(bytes);
  if (b[0] === 0xff && b[1] === 0xfe) return new TextDecoder("utf-16le").decode(b.subarray(2));
  if (b[0] === 0xfe && b[1] === 0xff) return new TextDecoder("utf-16be").decode(b.subarray(2));
  try {
    return stripBom(new TextDecoder("utf-8", { fatal: true, ignoreBOM: false }).decode(b));
  } catch {
    try {
      return new TextDecoder("windows-1256", { fatal: true, ignoreBOM: false }).decode(b);
    } catch {
      throw new ImportError("invalid_encoding", "تعذّرت قراءة نص الملف. احفظه بترميز UTF-8 ثم ارفعه مرة أخرى.");
    }
  }
}

export const stripBom = (text: string) => (text.charCodeAt(0) === 0xfeff ? text.slice(1) : text);

/** The delimiter of the first line: comma, semicolon or tab, whichever appears most outside quotes. */
export function detectDelimiter(text: string): string {
  const counts = new Map<string, number>([[",", 0], [";", 0], ["\t", 0]]);
  let quoted = false;
  for (const ch of text) {
    if (ch === '"') quoted = !quoted;
    else if (!quoted && (ch === "\n" || ch === "\r")) break;
    else if (!quoted && counts.has(ch)) counts.set(ch, counts.get(ch)! + 1);
  }
  let best = ",";
  for (const [d, n] of counts) if (n > counts.get(best)!) best = d;
  return best;
}

/**
 * RFC 4180 CSV: quoted fields may hold the delimiter, doubled quotes and line
 * breaks; CRLF, LF and CR all end a row. A leading BOM is dropped. Rows whose
 * cells are all empty are skipped.
 */
export function parseCsv(input: string, delimiter = detectDelimiter(stripBom(input))): string[][] {
  const text = stripBom(input);
  const rows: string[][] = [];
  let row: string[] = [];
  let field = "";
  let quoted = false;
  let i = 0;
  const endField = () => {
    row.push(field);
    field = "";
  };
  const endRow = () => {
    endField();
    if (row.some((cell) => cell.trim() !== "")) rows.push(row);
    row = [];
  };
  while (i < text.length) {
    const ch = text[i]!;
    if (quoted) {
      if (ch === '"') {
        if (text[i + 1] === '"') {
          field += '"';
          i += 2;
          continue;
        }
        quoted = false;
      } else {
        field += ch;
      }
      i++;
      continue;
    }
    if (ch === '"' && field.trim() === "") {
      field = "";
      quoted = true;
    } else if (ch === delimiter) {
      endField();
    } else if (ch === "\r" || ch === "\n") {
      endRow();
      if (ch === "\r" && text[i + 1] === "\n") i++;
    } else {
      field += ch;
    }
    i++;
  }
  if (field !== "" || row.length > 0) endRow();
  return rows;
}

/** A header cell as a lookup key: lowercase, Arabic folded («الأولوية» matches «الاولويه»), "_" as a space. */
export const headerKey = (name: string) => foldForSearch(name).replace(/[_]+/g, " ");

/** Rows after the header as maps keyed by `headerKey` of each column. */
export function csvRecords(rows: string[][]): { header: string[]; records: Map<string, string>[] } {
  const [header = [], ...body] = rows;
  const names = header.map(headerKey);
  const records = body.map((cells) => {
    const record = new Map<string, string>();
    names.forEach((name, i) => {
      // The first column of a repeated name wins.
      if (!record.has(name)) record.set(name, (cells[i] ?? "").trim());
    });
    return record;
  });
  return { header: names, records };
}
