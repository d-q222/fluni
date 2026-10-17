// Streaming CSV loader: fetches a (optionally gzipped) CSV and keeps only the requested columns, so a
// multi-million-row timeline never exists as one string or as 29-column row objects.
// Limits: fields are plain strings (like Papa's header: true); blank lines are skipped; quoted fields
// may contain commas, doubled quotes and newlines; UTF-8 only.

// Split one record into fields, honouring "quotes" and "" escapes.
function splitQuoted(line) {
  const out = [];
  let cur = '', q = false;
  for (let i = 0; i < line.length; i++) {
    const c = line[i];
    if (q) {
      if (c !== '"') cur += c;
      else if (line[i + 1] === '"') { cur += '"'; i++; } else q = false;
    } else if (c === '"') q = true;
    else if (c === ',') { out.push(cur); cur = ''; } else cur += c;
  }
  out.push(cur);
  return out;
}

const splitLine = (line) => (line.includes('"') ? splitQuoted(line) : line.split(','));
const quoteCount = (line) => line.split('"').length - 1;

// Peek the first bytes; gunzip if they are the gzip magic. Returns a stream of raw (decompressed) bytes.
async function openBytes(body) {
  const reader = body.getReader();
  let first = new Uint8Array(0);
  while (first.length < 2) {
    const { done, value } = await reader.read();
    if (done) break;
    const joined = new Uint8Array(first.length + value.length);
    joined.set(first);
    joined.set(value, first.length);
    first = joined;
  }
  let sent = false;
  const stream = new ReadableStream({
    async pull(ctl) {
      if (!sent) { sent = true; if (first.length) { ctl.enqueue(first); return; } }
      const { done, value } = await reader.read();
      if (done) ctl.close(); else ctl.enqueue(value);
    },
    cancel: (why) => reader.cancel(why),
  });
  const gz = first[0] === 0x1f && first[1] === 0x8b;
  return gz ? stream.pipeThrough(new DecompressionStream('gzip')) : stream;
}

// Async generator of text lines (no \r\n / \n), joining records whose quotes span lines.
async function* lines(stream) {
  const reader = stream.getReader();
  const dec = new TextDecoder();
  let rest = '', open = '', first = true;
  // Returns the finished record, or '' while a quoted field is still open (or the line is blank).
  const join = (line) => {
    if (open) line = open + '\n' + line;
    if (line.includes('"') && quoteCount(line) % 2) { open = line; return ''; }
    open = '';
    return line;
  };
  try {
    for (;;) {
      const { done, value } = await reader.read();
      let text = rest + (done ? dec.decode() : dec.decode(value, { stream: true }));
      if (first && text) { if (text.charCodeAt(0) === 0xfeff) text = text.slice(1); first = false; }
      let a = 0, b;
      while ((b = text.indexOf('\n', a)) >= 0) {
        const line = join(b > a && text.charCodeAt(b - 1) === 13 ? text.slice(a, b - 1) : text.slice(a, b));
        if (line) yield line;
        a = b + 1;
      }
      rest = text.slice(a);
      if (done) break;
    }
    const line = join(rest.endsWith('\r') ? rest.slice(0, -1) : rest);
    if (line) yield line;
    if (open) yield open; // unterminated quote at EOF: keep what we have
  } finally {
    reader.releaseLock();
  }
}

// columns: header names to keep (missing ones yield undefined).
// Returns { fields: all header names, rows: AsyncIterable of plain objects with only `columns` }.
export async function streamCsv(url, columns, { fetchImpl = fetch } = {}) {
  const res = await fetchImpl(url);
  if (!res.ok) throw new Error(`${res.status} ${res.statusText}`);
  const it = lines(await openBytes(res.body));
  const head = await it.next();
  const fields = head.done ? [] : splitLine(head.value);
  const idx = columns.map((c) => fields.indexOf(c));
  const n = columns.length;
  // Repeated values (timestamps, ids, states) share one string; also stops slices pinning whole lines.
  const seen = columns.map(() => new Map());
  async function* rows() {
    for await (const line of it) {
      const cells = splitLine(line);
      const row = {};
      for (let k = 0; k < n; k++) {
        let v = idx[k] >= 0 ? cells[idx[k]] : undefined;
        if (v !== undefined) {
          const m = seen[k], s = m.get(v);
          if (s !== undefined) v = s; else if (m.size < 50000) m.set(v, v);
        }
        row[columns[k]] = v;
      }
      yield row;
    }
  }
  return { fields, rows: rows() };
}

// Collects the rows into an array (what toFrames consumes). Returns { data, fields }.
export async function loadCsv(url, columns, opts) {
  const { fields, rows } = await streamCsv(url, columns, opts);
  const data = [];
  for await (const row of rows) data.push(row);
  return { data, fields };
}
