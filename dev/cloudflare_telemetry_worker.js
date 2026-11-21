/**
 * Zapret2 Kotek — Бесплатный сборщик анонимных логов (Cloudflare Worker -> Telegram Bot)
 *
 * Как развернуть за 3 минуты (0 руб, без VPS и банковской карты):
 * 1. В Telegram напиши @BotFather -> /newbot -> получи BOT_TOKEN.
 *    Узнай свой CHAT_ID (напиши @userinfobot или добавь бота в закрытую группу).
 * 2. Зайди на https://dash.cloudflare.com -> Workers & Pages -> Create -> Create Worker.
 * 3. Вставь весь этот код и нажми Deploy.
 * 4. Открой Settings -> Variables and Secrets -> Add Secret:
 *      - BOT_TOKEN  = твой токен от @BotFather
 *      - CHAT_ID    = твой Telegram ID (или -100... для группы)
 *      - INGEST_KEY = (опционально) секрет для заголовка X-Kotek-Key; если не задан, проверка отключена
 * 5. Скопируй URL воркера (https://<name>.<user>.workers.dev) и впиши в utils/telemetry.conf:
 *      endpoint=https://<name>.<user>.workers.dev
 */

const MAX_BODY_BYTES = 32768;
const MAX_TG_LEN = 4096;
const MAX_DETAIL_PARTS = 2;
const ALLOWED_EVENTS = new Set(['autosetup', 'hybrid', 'deep', 'optin', 'diag', 'crash', 'error', 'update', 'test']);

// Простой per-IP лимит в памяти воркера (без KV/D1): не более 10 запросов в минуту с одного IP
const RATE_WINDOW_MS = 60_000;
const RATE_MAX_REQ = 10;
const ipHits = new Map();

function isRateLimited(ip) {
  const now = Date.now();
  if (ipHits.size > 500) {
    for (const [k, arr] of ipHits) {
      const fresh = arr.filter((t) => now - t < RATE_WINDOW_MS);
      if (fresh.length === 0) ipHits.delete(k);
      else ipHits.set(k, fresh);
    }
  }
  const prev = (ipHits.get(ip) || []).filter((t) => now - t < RATE_WINDOW_MS);
  if (prev.length >= RATE_MAX_REQ) {
    ipHits.set(ip, prev);
    return true;
  }
  prev.push(now);
  ipHits.set(ip, prev);
  return false;
}

function escHtml(s) {
  return String(s ?? '')
    .replace(/&/g, '&amp;')
    .replace(/</g, '&lt;')
    .replace(/>/g, '&gt;');
}

function clipField(val, maxLen) {
  if (val === undefined || val === null) return '';
  const str = typeof val === 'string' ? val : String(val);
  return str.trim().slice(0, maxLen);
}

// Режет текст так, чтобы HTML-экранированный результат гарантированно влез в maxEscLen (без обрыва &lt;/&amp;)
function splitEscapedChunks(rawText, firstBudget, nextBudget, maxParts) {
  const chunks = [];
  let pos = 0;
  const total = rawText.length;

  for (let part = 0; part < maxParts && pos < total; part++) {
    const budget = part === 0 ? firstBudget : nextBudget;
    if (budget <= 32) break;

    let esc = '';
    let lastBreakPos = -1;
    let lastBreakEscLen = 0;
    const startPos = pos;

    while (pos < total) {
      const ch = rawText[pos];
      const add = ch === '&' ? '&amp;' : ch === '<' ? '&lt;' : ch === '>' ? '&gt;' : ch;
      if (esc.length + add.length > budget) break;
      esc += add;
      pos++;
      if (ch === '\n') {
        lastBreakPos = pos;
        lastBreakEscLen = esc.length;
      }
    }

    // Если есть перенос строки в последней трети чанка — режем красиво по строке
    if (pos < total && lastBreakPos > startPos && lastBreakEscLen >= Math.floor(budget * 0.65)) {
      esc = esc.slice(0, lastBreakEscLen);
      pos = lastBreakPos;
    }

    chunks.push(esc.trimEnd());
  }

  const truncated = pos < total;
  return { chunks, truncated };
}

async function sendTgMessage(tgUrl, chatId, text) {
  const res = await fetch(tgUrl, {
    method: 'POST',
    headers: { 'Content-Type': 'application/json' },
    signal: AbortSignal.timeout(5000),
    body: JSON.stringify({
      chat_id: chatId,
      text: text.slice(0, MAX_TG_LEN),
      parse_mode: 'HTML',
      disable_web_page_preview: true,
    }),
  });
  return res.ok;
}

export default {
  async fetch(request, env) {
    if (request.method === 'GET') {
      return new Response('Zapret2 Kotek Telemetry OK', { status: 200 });
    }
    if (request.method !== 'POST') {
      return new Response('Method Not Allowed', {
        status: 405,
        headers: { Allow: 'GET, POST' },
      });
    }

    if (!env.BOT_TOKEN || !env.CHAT_ID) {
      return new Response('Worker Misconfigured', { status: 500 });
    }

    // Опциональная защита ключом (включится автоматически, если добавить секрет INGEST_KEY)
    if (env.INGEST_KEY && request.headers.get('X-Kotek-Key') !== env.INGEST_KEY) {
      return new Response('Unauthorized', { status: 401 });
    }

    const clientIp = request.headers.get('CF-Connecting-IP') || 'unknown';
    if (isRateLimited(clientIp)) {
      return new Response('Too Many Requests', { status: 429 });
    }

    const cl = Number(request.headers.get('content-length') || 0);
    if (Number.isFinite(cl) && cl > MAX_BODY_BYTES) {
      return new Response('Payload Too Large', { status: 413 });
    }

    const raw = await request.text();
    if (!raw) {
      return new Response('Empty Payload', { status: 400 });
    }
    if (new TextEncoder().encode(raw).length > MAX_BODY_BYTES) {
      return new Response('Payload Too Large', { status: 413 });
    }

    let p;
    try {
      p = JSON.parse(raw);
    } catch {
      return new Response('Invalid JSON', { status: 400 });
    }

    if (!p || typeof p !== 'object' || p.app !== 'zapret2-kotek') {
      return new Response('Invalid Payload', { status: 400 });
    }

    const evName = clipField(p.event, 32).toLowerCase();
    if (!evName || !ALLOWED_EVENTS.has(evName)) {
      return new Response('Invalid Event', { status: 400 });
    }

    const ver      = clipField(p.ver || '?', 32);
    const id       = clipField(p.id || '-', 48);
    const os       = clipField(p.os || '-', 48);
    const strategy = clipField(p.strategy, 128);
    const score    = clipField(p.score, 64);
    const code     = (p.code !== undefined && p.code !== null && String(p.code) !== '') ? clipField(p.code, 48) : '';

    const icon =
      evName === 'crash' || evName === 'error' ? '❌' :
      evName === 'diag' ? '🩺' : '✅';

    const headerLines = [
      `${icon} <b>Zapret2 Kotek v${escHtml(ver)}</b> · <code>${escHtml(evName)}</code>`,
      `ID: <code>${escHtml(id)}</code> · Win: <code>${escHtml(os)}</code>`,
    ];
    if (strategy) headerLines.push(`Стратегия: <code>${escHtml(strategy)}</code>`);
    if (score)    headerLines.push(`Результат: <b>${escHtml(score)}</b>`);
    if (code)     headerLines.push(`Код: <code>${escHtml(code)}</code>`);
    const header = headerLines.join('\n');

    const messages = [];
    const detailRaw = (p.detail !== undefined && p.detail !== null)
      ? (typeof p.detail === 'string' ? p.detail : JSON.stringify(p.detail)).trim()
      : '';

    if (!detailRaw) {
      messages.push(header);
    } else {
      // Оставляем запас под теги \n<pre>...</pre> и возможную пометку [1/2] / ...(обрезано)
      const firstBudget = MAX_TG_LEN - header.length - 64;
      const nextBudget  = MAX_TG_LEN - 96;
      const { chunks, truncated } = splitEscapedChunks(detailRaw, firstBudget, nextBudget, MAX_DETAIL_PARTS);

      if (chunks.length === 0) {
        messages.push(header);
      } else if (chunks.length === 1) {
        const suffix = truncated ? '\n<i>…(лог обрезан по лимиту)</i>' : '';
        messages.push(`${header}\n\n<pre>${chunks[0]}</pre>${suffix}`);
      } else {
        messages.push(`${header}\n\n<b>[Часть 1/${chunks.length}]</b>\n<pre>${chunks[0]}</pre>`);
        for (let i = 1; i < chunks.length; i++) {
          const isLast = i === chunks.length - 1;
          const suffix = (isLast && truncated) ? '\n<i>…(лог обрезан по лимиту)</i>' : '';
          messages.push(`📄 <b>Zapret2 Kotek</b> · <code>${escHtml(id)}</code> <b>[Часть ${i + 1}/${chunks.length}]</b>\n<pre>${chunks[i]}</pre>${suffix}`);
        }
      }
    }

    const tgUrl = `https://api.telegram.org/bot${env.BOT_TOKEN}/sendMessage`;
    try {
      for (const msg of messages) {
        const ok = await sendTgMessage(tgUrl, env.CHAT_ID, msg);
        if (!ok) {
          return new Response('Upstream Error', { status: 502 });
        }
      }
      return new Response('OK', { status: 200 });
    } catch {
      return new Response('Upstream Timeout', { status: 502 });
    }
  },
};