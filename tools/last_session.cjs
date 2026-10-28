#!/usr/bin/env node
/**
 * last_session.cjs — «снимок» предыдущей сессии DeepSeek Harness.
 *
 * Зачем: при старте новой сессии агент не видит диалог прошлой. Скрипт достаёт
 * из лога предыдущей сессии последние реплики (по умолчанию 10) и складывает их
 * в docs/LAST_SESSION.md, который агент читает в начале работы (правило в AGENTS.md).
 *
 * Откуда данные: ~/.dsh/sessions/<рабочий каталог>/<session-id>/session.v4.jsonl.zstd
 * Формат: zstd-поток из множества кадров, внутри — JSONL событий сессии.
 *
 * Запуск:
 *   node tools/last_session.cjs                 # записать docs/LAST_SESSION.md
 *   node tools/last_session.cjs --limit 20      # больше реплик
 *   node tools/last_session.cjs --stdout        # только показать, не писать
 *   node tools/last_session.cjs --session <id>  # конкретная сессия
 *
 * Зависимостей нет: zstd распаковывается встроенным модулем zlib (Node 22.15+).
 */
'use strict';

const fs = require('fs');
const path = require('path');
const os = require('os');
const zlib = require('zlib');

const PROJECT_ROOT = path.resolve(__dirname, '..');
const DEFAULT_LIMIT = 10;
const USER_CUT = 1200;
const ASSIST_CUT = 600;
const MAGIC = Buffer.from([0x28, 0xb5, 0x2f, 0xfd]);
const FILE_HEADER = '<!-- Файл генерируется tools/last_session.cjs. Правки вручную будут перезаписаны. -->';

// ---------------------------------------------------------------- аргументы

function parseArgs(argv) {
  const args = { limit: DEFAULT_LIMIT, out: path.join(PROJECT_ROOT, 'docs', 'LAST_SESSION.md'), stdout: false, session: null };
  for (let i = 0; i < argv.length; i++) {
    const a = argv[i];
    if (a === '--stdout') args.stdout = true;
    else if (a === '--limit') args.limit = Number(argv[++i]) || DEFAULT_LIMIT;
    else if (a === '--out') args.out = path.resolve(argv[++i]);
    else if (a === '--session') args.session = argv[++i];
    else if (a === '--help' || a === '-h') { console.log(fs.readFileSync(__filename, 'utf8').split('*/')[0]); process.exit(0); }
  }
  return args;
}

// ------------------------------------------------------------ поиск сессий

function dshHome() {
  return process.env.DSH_HOME || path.join(os.homedir(), '.dsh');
}

function listSessionFiles(root) {
  const files = [];
  let workspaces = [];
  try { workspaces = fs.readdirSync(root, { withFileTypes: true }); } catch { return files; }
  for (const ws of workspaces) {
    if (!ws.isDirectory()) continue;
    const wsDir = path.join(root, ws.name);
    let sessions = [];
    try { sessions = fs.readdirSync(wsDir, { withFileTypes: true }); } catch { continue; }
    for (const s of sessions) {
      if (!s.isDirectory()) continue;
      const sDir = path.join(wsDir, s.name);
      let entries = [];
      try { entries = fs.readdirSync(sDir); } catch { continue; }
      for (const name of entries) {
        if (!/^session\..*jsonl\.zstd$/.test(name)) continue;
        const full = path.join(sDir, name);
        let st;
        try { st = fs.statSync(full); } catch { continue; }
        files.push({ path: full, id: s.name, mtime: st.mtimeMs, size: st.size });
      }
    }
  }
  return files;
}

function decompressAll(buf) {
  const positions = [];
  for (let i = buf.indexOf(MAGIC); i !== -1; i = buf.indexOf(MAGIC, i + 1)) positions.push(i);
  if (positions.length === 0) return buf;
  if (positions[0] !== 0) positions.unshift(0);
  const chunks = [];
  let i = 0;
  while (i < positions.length) {
    let j = i + 1;
    let data = null;
    while (j <= positions.length) {
      const end = j < positions.length ? positions[j] : buf.length;
      try { data = zlib.zstdDecompressSync(buf.subarray(positions[i], end)); break; } catch { j++; }
    }
    if (data) { chunks.push(data); i = j; } else { i++; }
  }
  return Buffer.concat(chunks);
}

function readEvents(file) {
  const text = decompressAll(fs.readFileSync(file)).toString('utf8');
  const events = [];
  for (const line of text.split('\n')) {
    if (!line.trim()) continue;
    try { events.push(JSON.parse(line)); } catch { /* битая строка — пропускаем */ }
  }
  return events;
}

function normalize(p) {
  if (!p) return '';
  return path.resolve(p).replace(/[\\/]+$/, '').toLowerCase();
}

function isSameOrAncestor(candidate, target) {
  const c = normalize(candidate);
  const t = normalize(target);
  if (!c || !t) return false;
  return t === c || t.startsWith(c + path.sep.toLowerCase()) || t.startsWith(c + '/');
}

// -------------------------------------------------------------- сообщения

function textOf(content) {
  if (typeof content === 'string') return content.trim();
  if (!Array.isArray(content)) return '';
  return content
    .filter((part) => part && part.type === 'text' && typeof part.text === 'string')
    .map((part) => part.text)
    .join('\n')
    .trim();
}

function messagesOf(events) {
  const out = [];
  for (const ev of events) {
    if (!ev || !ev.data) continue;
    if (ev.type === 'user/message') {
      const source = ev.data.source;
      if (!source || source.kind !== 'user') continue; // время, служебные вставки и т.п.
      const text = textOf(ev.data.content);
      if (text) out.push({ role: 'user', time: ev.time, text });
    } else if (ev.type === 'assistant/message') {
      const message = ev.data.message;
      const text = message ? textOf(message.content) : '';
      if (text) out.push({ role: 'assistant', time: ev.time, text });
    }
  }
  return out;
}

// ---------------------------------------------------------------- вывод

function cut(text, limit) {
  const flat = text.replace(/\r/g, '').trim();
  if (flat.length <= limit) return flat;
  const slice = flat.slice(0, limit);
  const atSpace = slice.lastIndexOf(' ');
  return (atSpace > limit * 0.6 ? slice.slice(0, atSpace) : slice).replace(/\s+$/, '') + ' …';
}

function fmtTime(ms) {
  if (!ms) return '—';
  const d = new Date(ms);
  const pad = (n) => String(n).padStart(2, '0');
  return `${pad(d.getDate())}.${pad(d.getMonth() + 1)}.${d.getFullYear()} ${pad(d.getHours())}:${pad(d.getMinutes())}`;
}

function gitInfo() {
  try {
    const gitDir = path.join(PROJECT_ROOT, '.git');
    const head = fs.readFileSync(path.join(gitDir, 'HEAD'), 'utf8').trim();
    let branch = head;
    let sha = '';
    if (head.startsWith('ref: ')) {
      const ref = head.slice(5).trim();
      branch = ref.replace(/^refs\/heads\//, '');
      try { sha = fs.readFileSync(path.join(gitDir, ref), 'utf8').trim(); }
      catch {
        const packed = fs.readFileSync(path.join(gitDir, 'packed-refs'), 'utf8');
        const line = packed.split('\n').find((l) => l.endsWith(' ' + ref));
        if (line) sha = line.split(' ')[0];
      }
    } else {
      branch = '(detached)';
      sha = head;
    }
    return { branch, sha: sha.slice(0, 7) };
  } catch {
    return null;
  }
}

function render(session, messages, limit) {
  const header = session.header || {};
  const events = session.events || [];
  const turns = events.filter((e) => e.type === 'turn/end').length;
  const firstTime = header.createdAt || (events[0] && events[0].time);
  const lastTime = events.length ? events[events.length - 1].time : null;
  const git = gitInfo();
  const tail = messages.slice(-limit);

  const lines = [];
  lines.push(FILE_HEADER);
  lines.push('');
  lines.push('# Последняя сессия — автоснимок');
  lines.push('');
  lines.push('> Контекст из предыдущей сессии DeepSeek Harness в этом рабочем каталоге.');
  lines.push('> Читать в начале работы; в git не попадает (см. `.gitignore`).');
  lines.push('');
  lines.push('| Параметр | Значение |');
  lines.push('|---|---|');
  lines.push(`| Сессия | \`${header.id || session.id}\` |`);
  lines.push(`| Начата | ${fmtTime(firstTime)} |`);
  lines.push(`| Последняя активность | ${fmtTime(lastTime)} |`);
  lines.push(`| Ходов | ${turns} |`);
  lines.push(`| Реплик в диалоге | ${messages.length} |`);
  if (git) lines.push(`| Ветка / коммит | \`${git.branch}\` / \`${git.sha}\` |`);
  lines.push(`| Снимок сделан | ${fmtTime(Date.now())} |`);
  lines.push('');
  lines.push(`## Последние ${tail.length} ${plural(tail.length)}`);
  lines.push('');
  tail.forEach((m, index) => {
    const who = m.role === 'user' ? 'Вы' : 'Ответ';
    const limitChars = m.role === 'user' ? USER_CUT : ASSIST_CUT;
    lines.push(`### ${index + 1}. ${who} — ${fmtTime(m.time)}`);
    lines.push('');
    for (const line of cut(m.text, limitChars).split('\n')) lines.push(line ? '> ' + line : '>');
    lines.push('');
  });
  return lines.join('\n') + '\n';
}

function plural(n) {
  const mod10 = n % 10;
  const mod100 = n % 100;
  if (mod10 === 1 && mod100 !== 11) return 'сообщение';
  if (mod10 >= 2 && mod10 <= 4 && (mod100 < 12 || mod100 > 14)) return 'сообщения';
  return 'сообщений';
}

// ------------------------------------------------------------------ main

function main() {
  const args = parseArgs(process.argv.slice(2));
  const root = path.join(dshHome(), 'sessions');
  if (!fs.existsSync(root)) {
    console.error(`Нет каталога сессий: ${root}`);
    process.exit(1);
  }

  const currentId = process.env.DSH_SESSION_ID || '';
  const candidates = [];
  for (const file of listSessionFiles(root)) {
    if (args.session) {
      if (file.id !== args.session) continue;
    } else if (currentId && file.id === currentId) {
      continue; // текущая сессия — не «предыдущая»
    }
    candidates.push(file);
  }
  candidates.sort((a, b) => b.mtime - a.mtime);

  let picked = null;
  for (const file of candidates) {
    let events;
    try { events = readEvents(file.path); } catch { continue; }
    const header = events[0] && events[0].type === 'session' ? events[0] : null;
    if (!args.session && header && !isSameOrAncestor(header.cwd, PROJECT_ROOT)) continue;
    picked = { file, header, events };
    break;
  }

  if (!picked) {
    console.error('Предыдущая сессия для этого каталога не найдена.');
    process.exit(2);
  }

  const messages = messagesOf(picked.events);
  const out = render({ id: picked.file.id, header: picked.header, events: picked.events }, messages, args.limit);

  if (args.stdout) {
    process.stdout.write(out);
    return;
  }
  // Песочница DSH может запретить запись в каталог проекта (низкий уровень целостности).
  // В этом случае пишем во временный каталог и сообщаем путь: агент перенесёт файл своим инструментом.
  let target = args.out;
  try {
    fs.mkdirSync(path.dirname(target), { recursive: true });
    fs.writeFileSync(target, out, 'utf8');
    console.log(`Записано: ${target}`);
  } catch (error) {
    target = path.join(os.tmpdir(), 'lcm_last_session.md');
    fs.writeFileSync(target, out, 'utf8');
    console.log(`FALLBACK ${target}`);
    console.log(`(прямая запись в ${args.out} недоступна: ${error.code || error.message})`);
  }
  console.log(`Сессия: ${picked.header ? picked.header.id : picked.file.id}, реплик в диалоге: ${messages.length}, в снимок попало: ${Math.min(args.limit, messages.length)}`);
}

main();
