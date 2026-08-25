"use strict";

const $ = (selector) => document.querySelector(selector);
const $$ = (selector) => [...document.querySelectorAll(selector)];
const state = {
  bootstrap: null, settings: null, token: "", book: null, epub: null, rendition: null,
  location: null, bookmarks: [], saveTimer: 0, hideTimer: 0, searchGeneration: 0,
  restoreCfi: "", percentage: 0, turning: false, turnTimer: 0,
};

function toast(message) {
  const node = $("#toast");
  node.textContent = message;
  node.classList.add("show");
  clearTimeout(node._timer);
  node._timer = setTimeout(() => node.classList.remove("show"), 1800);
}

async function api(path, options = {}) {
  const headers = { ...(options.headers || {}) };
  if (options.body) headers["Content-Type"] = "application/json";
  if (state.token) headers["X-Leaf-Token"] = state.token;
  const response = await fetch(path, { ...options, headers });
  const payload = await response.json().catch(() => ({}));
  if (!response.ok) throw new Error(payload.error || `Request failed (${response.status})`);
  return payload;
}

function activeBookProgress(bookId = state.book?.id) {
  return state.bootstrap?.progressState?.books?.[bookId] || {};
}

function setTheme(name) {
  document.querySelector("#app").className = `theme-${name}`;
  $$("#themeChoices button").forEach(button => button.classList.toggle("active", button.dataset.value === name));
}

function contentTheme() {
  const map = {
    paper: {
      body: { color: "#28231f", background: "#fffdf8" },
      "body *": { color: "#28231f !important" }, "a, a *": { color: "#8c5731 !important" },
    },
    sepia: {
      body: { color: "#372c22", background: "#f4ead6" },
      "body *": { color: "#372c22 !important" }, "a, a *": { color: "#8a552f !important" },
    },
    slate: {
      body: { color: "#e8edef", background: "#313c43" },
      "body *": { color: "#e8edef !important" }, "a, a *": { color: "#a9cad8 !important" },
    },
    night: {
      body: { color: "#dedad3", background: "#1d1d1d" },
      "body *": { color: "#dedad3 !important" }, "a, a *": { color: "#d4a576 !important" },
    },
  };
  return map[state.settings.theme];
}

function applyAppearance(redisplay = true) {
  if (!state.settings) return;
  setTheme(state.settings.theme);
  $("#fontSizeLabel").textContent = `${state.settings.fontSize} px`;
  $("#lineHeight").value = state.settings.lineHeight;
  $("#lineHeightLabel").textContent = Number(state.settings.lineHeight).toFixed(2);
  $("#pageWidth").value = state.settings.pageWidth;
  $("#pageWidthLabel").textContent = `${state.settings.pageWidth} px`;
  document.documentElement.style.setProperty("--reader-width", `${state.settings.pageWidth}px`);
  $$("#fontChoices button").forEach(button => button.classList.toggle("active", button.dataset.value === state.settings.fontFamily));
  $$("#flowChoices button").forEach(button => button.classList.toggle("active", button.dataset.value === state.settings.flow));
  $$("#pageTurnChoices button").forEach(button => button.classList.toggle("active", (button.dataset.value === "true") === state.settings.pageTurn));
  if (!state.rendition) return;
  state.rendition.themes.default(contentTheme());
  const family = state.settings.fontFamily === "publisher" ? "inherit" :
    state.settings.fontFamily === "sans" ? '"Noto Sans", ui-sans-serif, sans-serif' :
      '"Noto Serif", ui-serif, serif';
  state.rendition.themes.override("font-family", family, true);
  state.rendition.themes.override("font-size", `${state.settings.fontSize}px`, true);
  state.rendition.themes.override("line-height", String(state.settings.lineHeight), true);
  state.rendition.themes.override("font-kerning", "normal", true);
  state.rendition.themes.override("text-rendering", "optimizeLegibility", true);
  if (redisplay && state.location?.start?.cfi) state.rendition.display(state.location.start.cfi);
}

async function saveSettings(change) {
  state.settings = { ...state.settings, ...change };
  applyAppearance(false);
  try {
    const payload = await api("/api/settings", { method: "POST", body: JSON.stringify(change) });
    state.settings = payload.settings;
    applyAppearance(false);
  } catch (error) { toast(error.message); }
}

function showError(error) {
  console.error("Leaf Reader open failure", error);
  $("#loading").hidden = true;
  let detail = error?.message || String(error || "Unknown reader error");
  if (!detail || detail === "[object Object]") {
    try { detail = JSON.stringify(error); } catch (_) { detail = "Unknown reader error"; }
  }
  $("#errorText").textContent = detail;
  $("#error").hidden = false;
}

function closeDrawers() {
  $$(".drawer").forEach(drawer => { drawer.classList.remove("open"); drawer.setAttribute("aria-hidden", "true"); });
  $("#scrim").hidden = true;
}

function drawersOpen() {
  return $$(".drawer.open").length > 0;
}

function openDrawer(selector) {
  closeDrawers();
  const drawer = $(selector);
  drawer.classList.add("open");
  drawer.setAttribute("aria-hidden", "false");
  $("#scrim").hidden = false;
  document.body.classList.remove("chrome-hidden");
  if (selector === "#libraryDrawer") {
    renderLibrary();
    setTimeout(() => $("#librarySearch").focus(), 180);
  }
  if (selector === "#searchDrawer") setTimeout(() => $("#bookSearch").focus(), 180);
}

function chromeAwake() {
  document.body.classList.remove("chrome-hidden");
  clearTimeout(state.hideTimer);
  if (!drawersOpen()) state.hideTimer = setTimeout(() => document.body.classList.add("chrome-hidden"), 3600);
}

function toggleChrome() {
  clearTimeout(state.hideTimer);
  if (document.body.classList.contains("chrome-hidden")) chromeAwake();
  else document.body.classList.add("chrome-hidden");
}

function bookCard(book) {
  const button = document.createElement("button");
  button.className = "book-card";
  button.dataset.id = book.id;
  button.innerHTML = `
    <div class="cover-wrap">
      ${book.cover ? `<img class="book-cover" src="/api/cover/${encodeURIComponent(book.id)}" alt="" loading="lazy" decoding="async">` : `<span class="cover-fallback"></span>`}
      <span class="card-progress"><span style="width:${Math.round((book.progress || 0) * 100)}%"></span></span>
    </div>
    <strong></strong><small></small>`;
  button.querySelector("strong").textContent = book.title;
  button.querySelector("small").textContent = book.author;
  const fallback = button.querySelector(".cover-fallback");
  if (fallback) fallback.textContent = book.title;
  button.addEventListener("click", () => openBook(book.id));
  return button;
}

function renderLibrary() {
  const query = $("#librarySearch").value.trim().toLowerCase();
  const allMatches = state.bootstrap.books.filter(book => `${book.title} ${book.author}`.toLowerCase().includes(query));
  const books = allMatches.slice(0, 80);
  const grid = $("#libraryGrid");
  grid.replaceChildren(...books.map(bookCard));
  $("#emptyLibrary").hidden = books.length > 0;
}

function flattenToc(items, depth = 0, result = []) {
  for (const item of items || []) {
    result.push({ ...item, depth });
    flattenToc(item.subitems, depth + 1, result);
  }
  return result;
}

function renderToc() {
  const list = $("#tocList");
  const items = flattenToc(state.epub?.navigation?.toc || []);
  list.replaceChildren(...items.map(item => {
    const button = document.createElement("button");
    button.className = "toc-item";
    button.style.setProperty("--depth", Math.min(item.depth, 3));
    button.textContent = item.label.trim();
    button.addEventListener("click", () => { closeDrawers(); state.rendition.display(item.href); });
    return button;
  }));
}

function renderBookmarks() {
  const list = $("#bookmarkList");
  $("#bookmarkCount").textContent = state.bookmarks.length;
  list.replaceChildren(...state.bookmarks.map((mark, index) => {
    const button = document.createElement("button");
    button.className = "bookmark-item";
    const label = document.createElement("span");
    label.textContent = mark.label || `Bookmark ${index + 1}`;
    const remove = document.createElement("span");
    remove.className = "remove"; remove.textContent = "×"; remove.title = "Remove bookmark";
    remove.addEventListener("click", event => { event.stopPropagation(); removeBookmark(index); });
    button.append(label, remove);
    button.addEventListener("click", () => { closeDrawers(); state.rendition.display(mark.cfi); });
    return button;
  }));
}

async function persistProgress(extra = {}) {
  if (!state.book) return;
  const location = state.location;
  const payload = {
    cfi: location?.start?.cfi || activeBookProgress().cfi || "",
    percentage: Number.isFinite(state.percentage) ? state.percentage : (activeBookProgress().percentage || 0),
    chapter: $("#chapterTitle").textContent || "",
    bookmarks: state.bookmarks,
    ...extra,
  };
  try {
    const result = await api(`/api/progress/${encodeURIComponent(state.book.id)}`, { method: "POST", body: JSON.stringify(payload) });
    state.bootstrap.progressState.books[state.book.id] = result.progress;
    state.bootstrap.progressState.lastBookId = state.book.id;
  } catch (_) { /* a later relocation retries */ }
}

function scheduleProgressSave() {
  clearTimeout(state.saveTimer);
  state.saveTimer = setTimeout(persistProgress, 280);
}

function addBookmark() {
  const cfi = state.location?.start?.cfi;
  if (!cfi) return;
  const existing = state.bookmarks.findIndex(mark => mark.cfi === cfi);
  if (existing >= 0) {
    state.bookmarks.splice(existing, 1);
    toast("Bookmark removed");
  } else {
    state.bookmarks.push({ cfi, label: $("#chapterTitle").textContent || `${$("#percentLabel").textContent} read`, created: new Date().toISOString() });
    toast("Page bookmarked");
  }
  renderBookmarks();
  updateBookmarkButton();
  persistProgress();
}

function removeBookmark(index) {
  state.bookmarks.splice(index, 1);
  renderBookmarks();
  updateBookmarkButton();
  persistProgress();
}

function updateBookmarkButton() {
  const cfi = state.location?.start?.cfi;
  const active = cfi && state.bookmarks.some(mark => mark.cfi === cfi);
  $("#bookmarkButton").classList.toggle("active", Boolean(active));
  $("#bookmarkButton").textContent = active ? "◆" : "◇";
}

async function openBook(bookId) {
  closeDrawers();
  const book = state.bootstrap.books.find(candidate => candidate.id === bookId);
  if (!book) return showError(new Error("That book is no longer in the selected library folder."));
  if (state.rendition) state.rendition.destroy();
  if (state.epub) state.epub.destroy();
  state.book = book;
  state.location = null;
  $("#error").hidden = true;
  $("#loading").hidden = false;
  $("#loadingText").textContent = book.format === "epub" ? "Opening your book…" : `Preparing ${book.format.toUpperCase()}…`;
  $("#bookTitle").textContent = book.title;
  $("#chapterTitle").textContent = book.author;
  history.replaceState(null, "", `?book=${encodeURIComponent(book.id)}`);
  const progress = activeBookProgress(book.id);
  state.restoreCfi = progress.cfi || "";
  state.percentage = Number(progress.percentage || 0);
  state.bookmarks = Array.isArray(progress.bookmarks) ? progress.bookmarks : [];
  renderBookmarks();
  if (book.format === "pdf" && !book.files?.epub) {
    $("#viewer").style.display = "none";
    $("#pdfViewer").style.display = "block";
    $("#pdfViewer").src = `/api/book/${encodeURIComponent(book.id)}`;
    $("#loading").hidden = true;
    $("#pageLabel").textContent = "PDF";
    $("#percentLabel").textContent = `${Math.round((progress.percentage || 0) * 100)}%`;
    await persistProgress();
    return;
  }
  $("#pdfViewer").style.display = "none";
  $("#viewer").style.display = "block";
  try {
    // The API URL intentionally has no filename extension. Feeding EPUB.js an
    // ArrayBuffer makes the archive type explicit and also lets us surface a
    // useful conversion error for Kindle-only formats.
    const response = await fetch(`/api/book/${encodeURIComponent(book.id)}`);
    if (!response.ok) {
      const failure = await response.json().catch(() => ({}));
      throw new Error(failure.error || `Book request failed (${response.status})`);
    }
    state.epub = ePub(await response.arrayBuffer());
    await state.epub.ready;
    const flow = state.settings.flow === "scrolled" ? "scrolled-doc" : "paginated";
    state.rendition = state.epub.renderTo("viewer", {
      width: "100%", height: "100%", flow, spread: "auto", minSpreadWidth: 800,
      allowScriptedContent: false, allowPopups: false,
    });
    applyAppearance(false);
    state.rendition.on("relocated", onRelocated);
    state.rendition.on("rendered", (_, view) => {
      view.contents.on("keydown", onReaderKey);
      view.contents.on("click", chromeAwake);
      view.contents.on("mousemove", chromeAwake);
    });
    await state.rendition.display(progress.cfi || undefined);
    state.epub.locations.generate(1400).catch(() => {});
    await state.epub.loaded.navigation;
    renderToc();
    $("#loading").hidden = true;
    await persistProgress();
  } catch (error) { showError(error); }
}

function onRelocated(location) {
  state.location = location;
  let percentage = location.start?.percentage;
  const saved = activeBookProgress();
  if (state.restoreCfi && location.start?.cfi === state.restoreCfi) {
    percentage = Number(saved.percentage || 0);
  } else {
    if (state.restoreCfi) state.restoreCfi = "";
  }
  if ((!Number.isFinite(percentage) || percentage === 0) && !state.restoreCfi) {
    if (state.epub?.locations?.length()) {
      percentage = state.epub.locations.percentageFromCfi(location.start.cfi);
    } else {
      // Location generation is asynchronous. Preserve the saved percentage
      // when EPUB.js restores the exact CFI before its percentage map exists.
      if (saved.cfi === location.start?.cfi && Number.isFinite(Number(saved.percentage))) {
        percentage = Number(saved.percentage);
      }
    }
  }
  percentage = Number.isFinite(percentage) ? Math.max(0, Math.min(1, percentage)) : 0;
  state.percentage = percentage;
  $("#progressSlider").value = Math.round(percentage * 1000);
  $("#percentLabel").textContent = `${Math.round(percentage * 100)}%`;
  $("#pageLabel").textContent = location.start?.displayed ? `${location.start.displayed.page} / ${location.start.displayed.total}` : "—";
  const href = location.start?.href || "";
  const toc = flattenToc(state.epub?.navigation?.toc || []);
  const entry = toc.find(item => href.includes(item.href.split("#")[0]));
  $("#chapterTitle").textContent = entry?.label?.trim() || state.book.author;
  updateBookmarkButton();
  scheduleProgressSave();
}

function navigate(direction) {
  if (!state.rendition || state.turning) return;
  const reducedMotion = matchMedia("(prefers-reduced-motion: reduce)").matches;
  if (state.settings.flow !== "paginated" || state.settings.pageTurn === false || reducedMotion) {
    direction < 0 ? state.rendition.prev() : state.rendition.next();
    return;
  }
  state.turning = true;
  const effect = $("#pageTurnEffect");
  effect.className = `page-turn-effect active ${direction < 0 ? "turn-previous" : "turn-next"}`;
  const turn = setTimeout(() => {
    direction < 0 ? state.rendition.prev() : state.rendition.next();
  }, 245);
  clearTimeout(state.turnTimer);
  state.turnTimer = setTimeout(() => {
    clearTimeout(turn);
    effect.className = "page-turn-effect";
    state.turning = false;
  }, 540);
}

function onReaderKey(event) { handleKey(event); }
function handleKey(event) {
  if (event.ctrlKey || event.metaKey || event.altKey) return;
  if (event.key === "Escape") {
    event.preventDefault();
    if (drawersOpen()) { closeDrawers(); chromeAwake(); }
    else toggleChrome();
    return;
  }
  const tag = event.target?.tagName?.toLowerCase();
  if (tag === "input" || tag === "textarea") return;
  if (event.key === "ArrowLeft" || event.key === "PageUp") { event.preventDefault(); navigate(-1); }
  else if (event.key === "ArrowRight" || event.key === "PageDown" || event.key === " ") { event.preventDefault(); navigate(1); }
  else if (event.key === "/") openDrawer("#searchDrawer");
  else if (event.key.toLowerCase() === "b") addBookmark();
  else if (event.key.toLowerCase() === "a") openDrawer("#appearanceDrawer");
  else if (event.key.toLowerCase() === "l") openDrawer("#libraryDrawer");
  else if (event.key.toLowerCase() === "t") openDrawer("#tocDrawer");
}

async function searchBook(query) {
  const generation = ++state.searchGeneration;
  const results = $("#searchResults");
  results.replaceChildren();
  if (query.length < 2 || !state.epub) { $("#searchStatus").textContent = "Type at least two characters."; return; }
  $("#searchStatus").textContent = "Searching…";
  const matches = [];
  for (const section of state.epub.spine.spineItems) {
    if (generation !== state.searchGeneration || matches.length >= 100) return;
    try {
      await section.load(state.epub.load.bind(state.epub));
      for (const match of section.find(query).slice(0, 12)) matches.push({ ...match, section: section.index });
      section.unload();
    } catch (_) {}
  }
  if (generation !== state.searchGeneration) return;
  $("#searchStatus").textContent = `${matches.length} result${matches.length === 1 ? "" : "s"}`;
  results.replaceChildren(...matches.map((match, index) => {
    const button = document.createElement("button");
    button.className = "search-result";
    button.innerHTML = `<strong>RESULT ${index + 1}</strong><span></span>`;
    button.querySelector("span").textContent = match.excerpt.replace(/\s+/g, " ").trim();
    button.addEventListener("click", () => { closeDrawers(); state.rendition.display(match.cfi); });
    return button;
  }));
}

function bindControls() {
  $("#previousZone").addEventListener("click", event => { event.stopPropagation(); navigate(-1); });
  $("#nextZone").addEventListener("click", event => { event.stopPropagation(); navigate(1); });
  $("#libraryButton").addEventListener("click", () => openDrawer("#libraryDrawer"));
  $("#tocButton").addEventListener("click", () => openDrawer("#tocDrawer"));
  $("#searchButton").addEventListener("click", () => openDrawer("#searchDrawer"));
  $("#appearanceButton").addEventListener("click", () => openDrawer("#appearanceDrawer"));
  $("#bookmarkButton").addEventListener("click", addBookmark);
  $("#errorLibraryButton").addEventListener("click", () => openDrawer("#libraryDrawer"));
  $("#scrim").addEventListener("click", closeDrawers);
  $$(".close-drawer").forEach(button => button.addEventListener("click", closeDrawers));
  $("#librarySearch").addEventListener("input", renderLibrary);
  let searchTimer;
  $("#bookSearch").addEventListener("input", event => { clearTimeout(searchTimer); searchTimer = setTimeout(() => searchBook(event.target.value.trim()), 280); });
  $("#fontSmaller").addEventListener("click", () => saveSettings({ fontSize: state.settings.fontSize - 1 }));
  $("#fontLarger").addEventListener("click", () => saveSettings({ fontSize: state.settings.fontSize + 1 }));
  $$("#fontChoices button").forEach(button => button.addEventListener("click", () => saveSettings({ fontFamily: button.dataset.value })));
  $$("#themeChoices button").forEach(button => button.addEventListener("click", () => saveSettings({ theme: button.dataset.value })));
  $$("#flowChoices button").forEach(button => button.addEventListener("click", async () => {
    await saveSettings({ flow: button.dataset.value });
    if (state.book) openBook(state.book.id);
  }));
  $$("#pageTurnChoices button").forEach(button => button.addEventListener("click", () => {
    saveSettings({ pageTurn: button.dataset.value === "true" });
  }));
  $("#lineHeight").addEventListener("input", event => { state.settings.lineHeight = Number(event.target.value); applyAppearance(false); });
  $("#lineHeight").addEventListener("change", event => saveSettings({ lineHeight: Number(event.target.value) }));
  $("#pageWidth").addEventListener("input", event => { state.settings.pageWidth = Number(event.target.value); applyAppearance(false); });
  $("#pageWidth").addEventListener("change", event => saveSettings({ pageWidth: Number(event.target.value) }));
  $("#progressSlider").addEventListener("change", event => {
    if (!state.epub?.locations?.length()) return;
    const cfi = state.epub.locations.cfiFromPercentage(Number(event.target.value) / 1000);
    if (cfi) state.rendition.display(cfi);
  });
  document.addEventListener("keydown", handleKey);
  document.addEventListener("mousemove", chromeAwake, { passive: true });
  document.addEventListener("click", event => {
    if (!event.target.closest(".page-zone")) chromeAwake();
  });
}

async function initialize() {
  bindControls();
  chromeAwake();
  try {
    const fragment = new URLSearchParams(location.hash.slice(1));
    state.token = fragment.get("token") || sessionStorage.getItem("leafReaderToken") || "";
    if (state.token) sessionStorage.setItem("leafReaderToken", state.token);
    if (location.hash) history.replaceState(null, "", `${location.pathname}${location.search}`);
    state.bootstrap = await api("/api/bootstrap");
    state.token = "";
    sessionStorage.removeItem("leafReaderToken");
    state.settings = state.bootstrap.settings;
    applyAppearance(false);
    const requested = new URLSearchParams(location.search).get("book");
    const bookId = requested || state.bootstrap.lastBookId || state.bootstrap.books[0]?.id;
    if (!bookId) {
      $("#loadingText").textContent = "Choose a library folder from the Omarchy panel to begin.";
      openDrawer("#libraryDrawer");
      return;
    }
    await openBook(bookId);
  } catch (error) { showError(error); }
}

initialize();
