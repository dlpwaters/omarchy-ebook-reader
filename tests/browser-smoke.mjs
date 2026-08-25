#!/usr/bin/env node

import fs from "node:fs";

const endpoint = process.argv[2];
const screenshotPath = process.argv[3] || "/tmp/leaf-reader-browser-smoke.png";
if (!endpoint) {
  console.error("Usage: node tests/browser-smoke.mjs <devtools-websocket-url> [screenshot-path]");
  process.exit(2);
}

const socket = new WebSocket(endpoint);
let nextId = 1;
const pending = new Map();
const errors = [];

socket.addEventListener("message", event => {
  const message = JSON.parse(event.data);
  if (message.id && pending.has(message.id)) {
    const { resolve, reject } = pending.get(message.id);
    pending.delete(message.id);
    if (message.error) reject(new Error(message.error.message));
    else resolve(message.result || {});
    return;
  }
  if (message.method === "Runtime.exceptionThrown") {
    errors.push(message.params.exceptionDetails?.text || "Unhandled browser exception");
  }
  if (message.method === "Log.entryAdded" && message.params.entry?.level === "error") {
    errors.push(message.params.entry.text);
  }
});

function call(method, params = {}) {
  const id = nextId++;
  socket.send(JSON.stringify({ id, method, params }));
  return new Promise((resolve, reject) => pending.set(id, { resolve, reject }));
}

async function evaluate(expression, awaitPromise = false) {
  const result = await call("Runtime.evaluate", {
    expression,
    awaitPromise,
    returnByValue: true,
    userGesture: true,
  });
  if (result.exceptionDetails) throw new Error(result.exceptionDetails.text || "Evaluation failed");
  return result.result?.value;
}

async function waitFor(expression, timeoutMs = 15000) {
  const deadline = Date.now() + timeoutMs;
  while (Date.now() < deadline) {
    if (await evaluate(expression)) return;
    await new Promise(resolve => setTimeout(resolve, 100));
  }
  throw new Error(`Timed out waiting for: ${expression}`);
}

function assert(condition, message) {
  if (!condition) throw new Error(message);
}

await new Promise((resolve, reject) => {
  socket.addEventListener("open", resolve, { once: true });
  socket.addEventListener("error", () => reject(new Error("Could not connect to Chromium")), { once: true });
});

try {
  await call("Runtime.enable");
  await call("Log.enable");
  await call("Page.enable");
  await waitFor("document.querySelector('#loading')?.hidden === true && document.querySelectorAll('#viewer iframe').length > 0");

  const initial = await evaluate(`(() => {
    const frame = document.querySelector('#viewer iframe');
    return {
      title: document.querySelector('#bookTitle')?.textContent,
      activeTitle: state.book?.title,
      libraryCount: state.bootstrap?.books?.length || 0,
      theme: state.settings.theme,
      flow: state.settings.flow,
      pageTurn: state.settings.pageTurn,
      width: getComputedStyle(document.documentElement).getPropertyValue('--reader-width').trim(),
      viewerWidth: document.querySelector('#viewer')?.getBoundingClientRect().width || 0,
      spreadDivisor: state.rendition?.manager?.layout?.divisor || 0,
      font: frame?.contentDocument ? getComputedStyle(frame.contentDocument.body).fontFamily : '',
      text: frame?.contentDocument?.body?.innerText?.trim() || ''
    };
  })()`);
  assert(initial.title && initial.title === initial.activeTitle, `Unexpected title: ${initial.title}`);
  assert(initial.libraryCount >= 4, `Starter library did not load: ${initial.libraryCount} books`);
  assert(initial.theme === "paper" && initial.flow === "paginated" && initial.pageTurn === true, "Unexpected initial reader settings");
  assert(initial.width === "760px", `Reading width was not applied to the viewport: ${initial.width}`);
  assert(initial.viewerWidth > 1100, `Reader did not open as a two-page spread: ${initial.viewerWidth}px`);
  assert(initial.spreadDivisor === 2, `EPUB layout is not using two pages: divisor ${initial.spreadDivisor}`);
  assert(initial.font.includes("Noto Serif"), `Expected Noto Serif, got: ${initial.font}`);
  assert(initial.text.length > 0, "Initial EPUB page is blank");

  const turnStarted = await evaluate(`(() => {
    document.body.classList.add('chrome-hidden');
    navigate(1);
    return {
      chromeHidden: document.body.classList.contains('chrome-hidden'),
      effectActive: document.querySelector('#pageTurnEffect').classList.contains('active')
    };
  })()`);
  assert(turnStarted.chromeHidden, "A page turn woke the reader controls");
  assert(turnStarted.effectActive, "The page-turn animation did not start");
  await new Promise(resolve => setTimeout(resolve, 650));
  const turnSettled = await evaluate(`({
    chromeHidden: document.body.classList.contains('chrome-hidden'),
    effectActive: document.querySelector('#pageTurnEffect').classList.contains('active'),
    turning: state.turning
  })`);
  assert(turnSettled.chromeHidden, "Reader controls appeared after the page turn");
  assert(!turnSettled.effectActive && !turnSettled.turning, "The page-turn animation did not settle");

  const motionOff = await evaluate(`(async () => {
    await saveSettings({ pageTurn: false });
    document.body.classList.add('chrome-hidden');
    navigate(1);
    return {
      setting: state.settings.pageTurn,
      chromeHidden: document.body.classList.contains('chrome-hidden'),
      effectActive: document.querySelector('#pageTurnEffect').classList.contains('active'),
      turning: state.turning
    };
  })()`, true);
  assert(motionOff.setting === false, "The page-turn off setting was not saved");
  assert(motionOff.chromeHidden, "A motion-free page change woke the reader controls");
  assert(!motionOff.effectActive && !motionOff.turning, "The page-turn effect ran while switched off");
  await evaluate("saveSettings({ pageTurn: true })", true);

  const chapterOpened = await evaluate(`(async () => {
    const toc = flattenToc(state.epub?.navigation?.toc || []);
    const chapter = toc.find(item => /chapter\\s+(1|one|i)\\b/i.test(item.label || ''))
      || toc.find(item => !/(cover|title|contents|imprint|copyright|colophon|dedication|preface|introduction)/i.test(item.label || ''));
    if (!chapter?.href) return '';
    await state.rendition.display(chapter.href);
    return chapter.label || chapter.href;
  })()`, true);
  assert(chapterOpened, "Could not find a readable chapter in the EPUB table of contents");

  let readableText = "";
  for (let index = 0; index < 8; index += 1) {
    readableText = await evaluate(`Array.from(document.querySelectorAll('#viewer iframe'))
      .map(frame => frame.contentDocument?.body?.innerText?.trim() || '')
      .join(' ')`);
    if (readableText.length > 180) break;
    await evaluate("navigate(1)");
    await new Promise(resolve => setTimeout(resolve, 650));
  }
  assert(readableText.length > 180, "Could not reach a readable text page through normal navigation");

  const dark = await evaluate(`(async () => {
    await saveSettings({ theme: 'night' });
    await new Promise(resolve => setTimeout(resolve, 600));
    const frame = document.querySelector('#viewer iframe');
    return {
      appClass: document.querySelector('#app').className,
      pageBackground: getComputedStyle(document.querySelector('#readerShell')).backgroundColor,
      bookBackground: frame?.contentDocument ? getComputedStyle(frame.contentDocument.body).backgroundColor : '',
      bookColor: frame?.contentDocument ? getComputedStyle(frame.contentDocument.body).color : '',
      readableCharacters: Array.from(document.querySelectorAll('#viewer iframe'))
        .map(item => item.contentDocument?.body?.innerText?.trim() || '')
        .join(' ').length
    };
  })()`, true);
  assert(dark.appClass === "theme-night", "Night theme did not activate");
  assert(dark.pageBackground === "rgb(29, 29, 29)", `Unexpected night background: ${dark.pageBackground}`);
  assert(dark.bookBackground === "rgb(29, 29, 29)", `EPUB did not receive night background: ${dark.bookBackground}`);
  assert(dark.readableCharacters > 180, "EPUB text disappeared while applying Night theme");

  const capture = await call("Page.captureScreenshot", { format: "png", fromSurface: true });
  fs.writeFileSync(screenshotPath, Buffer.from(capture.data, "base64"));

  const themeRoundTrip = await evaluate(`(async () => {
    const inspect = () => {
      const frame = document.querySelector('#viewer iframe');
      const sample = frame?.contentDocument?.querySelector('p, h1, h2, h3, li, blockquote');
      return {
        bodyBackground: frame?.contentDocument ? getComputedStyle(frame.contentDocument.body).backgroundColor : '',
        textColor: sample ? getComputedStyle(sample).color : ''
      };
    };
    await saveSettings({ theme: 'sepia' });
    await new Promise(resolve => setTimeout(resolve, 600));
    const sepia = inspect();
    await saveSettings({ theme: 'paper' });
    await new Promise(resolve => setTimeout(resolve, 600));
    const paper = inspect();
    return { sepia, paper };
  })()`, true);
  assert(themeRoundTrip.sepia.bodyBackground === "rgb(244, 234, 214)", `Unexpected Sepia background: ${themeRoundTrip.sepia.bodyBackground}`);
  assert(themeRoundTrip.sepia.textColor === "rgb(55, 44, 34)", `Night text color leaked into Sepia: ${themeRoundTrip.sepia.textColor}`);
  assert(themeRoundTrip.paper.bodyBackground === "rgb(255, 253, 248)", `Unexpected Paper background: ${themeRoundTrip.paper.bodyBackground}`);
  assert(themeRoundTrip.paper.textColor === "rgb(40, 35, 31)", `Night text color leaked into Paper: ${themeRoundTrip.paper.textColor}`);

  assert(errors.length === 0, `Browser errors: ${errors.join(" | ")}`);
  console.log(JSON.stringify({
    ok: true,
    initialTitle: initial.title,
    initialFont: initial.font,
    pageTurnSettled: true,
    pageTurnCanBeDisabled: true,
    spreadDivisor: initial.spreadDivisor,
    viewerWidth: initial.viewerWidth,
    readableChapter: chapterOpened,
    controlsStayedHidden: true,
    readableCharacters: readableText.length,
    nightTheme: dark,
    themeRoundTrip,
    screenshot: screenshotPath,
    browserErrors: errors,
  }, null, 2));
} finally {
  socket.close();
}
