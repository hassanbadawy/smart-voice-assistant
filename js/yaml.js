/* ============================================================
   yaml.js — minimal, dependency-free YAML for a known schema:
   nested maps whose leaf values are strings. No external CDN
   (keeps the app air-gap friendly). Handles exactly what the
   config needs: 2–3 levels of `key:` maps and quoted scalars.
   ============================================================ */

const YAML = (() => {

  function quote(v) {
    if (v === null || v === undefined) return '""';
    const s = String(v);
    // Always double-quote leaf strings; escape backslash and quote.
    return '"' + s.replace(/\\/g, '\\\\').replace(/"/g, '\\"') + '"';
  }

  function dump(obj, indent = 0) {
    const pad = '  '.repeat(indent);
    const lines = [];
    for (const [k, v] of Object.entries(obj)) {
      if (v && typeof v === 'object' && !Array.isArray(v)) {
        lines.push(`${pad}${k}:`);
        const inner = dump(v, indent + 1);
        if (inner) lines.push(inner);
      } else {
        lines.push(`${pad}${k}: ${quote(v)}`);
      }
    }
    return lines.join('\n');
  }

  // Parse a scalar value, respecting quotes and stripping inline comments.
  function scalar(rest) {
    rest = rest.trim();
    if (rest.startsWith('"')) {
      let out = '', i = 1;
      while (i < rest.length) {
        const c = rest[i];
        if (c === '\\' && i + 1 < rest.length) { out += rest[i + 1]; i += 2; continue; }
        if (c === '"') return out;
        out += c; i++;
      }
      return out;
    }
    if (rest.startsWith("'")) {
      let out = '', i = 1;
      while (i < rest.length) {
        if (rest[i] === "'") {
          if (rest[i + 1] === "'") { out += "'"; i += 2; continue; }
          return out;
        }
        out += rest[i]; i++;
      }
      return out;
    }
    const h = rest.indexOf(' #');
    if (h !== -1) rest = rest.slice(0, h);
    return rest.trim();
  }

  function parse(text) {
    const root = {};
    const stack = [{ indent: -1, node: root }];

    for (const rawLine of text.split(/\r?\n/)) {
      if (!rawLine.trim() || rawLine.trim().startsWith('#')) continue;
      const indent = rawLine.length - rawLine.replace(/^ +/, '').length;
      const line = rawLine.trim();

      const idx = line.indexOf(':');
      if (idx === -1) continue;
      const key = line.slice(0, idx).trim();
      const rest = line.slice(idx + 1);
      const restTrim = rest.trim();
      const isMap = restTrim === '' || restTrim.startsWith('#');

      while (stack.length > 1 && indent <= stack[stack.length - 1].indent) {
        stack.pop();
      }
      const parent = stack[stack.length - 1].node;

      if (isMap) {
        const child = {};
        parent[key] = child;
        stack.push({ indent, node: child });
      } else {
        parent[key] = scalar(rest);
      }
    }
    return root;
  }

  return { dump, parse };
})();

if (typeof window !== 'undefined') window.YAML = YAML;
