// Adapted from open-browser-use (MIT, Copyright (c) 2026 Leo); see LICENSE.open-browser-use.

const NATIVE_HOST_NAME = "sk.lubomirdlhy.opencomputeruse.browser";
const NATIVE_HOST_STATUS_KEY = "OCU_BROWSER_NATIVE_HOST_STATUS";
const SESSION_STATE_KEY = "OCU_BROWSER_SESSION_STATE";
const PROFILE_TOKEN_KEY = "OCU_BROWSER_PROFILE_TOKEN";
const RECONNECT_ALARM_NAME = "ocu-browser-native-reconnect";
const HEARTBEAT_ALARM_NAME = "ocu-browser-heartbeat";
const DEFAULT_CDP_TIMEOUT_MS = 10_000;
const MAX_USER_TABS = 500;
const SESSION_GROUP_TITLE = "OCU";
const DELIVERABLE_GROUP_TITLE = "OCU ✓";
const FORWARDED_CDP_EVENTS = new Set(["Page.javascriptDialogOpening", "Page.javascriptDialogClosed", "Input.dragIntercepted"]);

class JsonRpcPeer {
  constructor(transport, handlers) {
    this.transport = transport;
    this.handlers = handlers;
    this.transport.setMessageCallback((message) => {
      void this.handleMessage(message);
    });
  }

  async handleMessage(message) {
    if (!message || typeof message !== "object" || typeof message.method !== "string") {
      return;
    }
    const id = message.id;
    try {
      const handler = this.handlers[message.method];
      if (typeof handler !== "function" || message.method.startsWith("handle") || message.method === "constructor") {
        throw new Error(`No handler registered for method: ${message.method}`);
      }
      const result = await handler.call(this.handlers, message.params ?? {});
      if (id !== undefined) {
        this.transport.sendMessage({ jsonrpc: "2.0", id, result: result ?? {} });
      }
    } catch (error) {
      if (id !== undefined) {
        this.transport.sendMessage({
          jsonrpc: "2.0",
          id,
          error: { code: -32000, message: error instanceof Error ? error.message : String(error) }
        });
      }
    }
  }

  sendNotification(method, params) {
    this.transport.sendMessage({ jsonrpc: "2.0", method, params });
  }
}

class NativeTransport {
  constructor(hostName) {
    this.hostName = hostName;
    this.port = null;
    this.messageCallback = null;
    this.reconnectAttempt = 0;
    this.status = { hostName, state: "disconnected" };
    this.connect();
    chrome.alarms.onAlarm.addListener((alarm) => {
      if (alarm.name === RECONNECT_ALARM_NAME && !this.port) {
        this.connect();
      }
    });
  }

  setMessageCallback(callback) {
    this.messageCallback = callback;
  }

  sendMessage(message) {
    if (!this.port) {
      this.scheduleReconnect("native host disconnected");
      throw new Error("Native host is disconnected");
    }
    this.port.postMessage(message);
  }

  connect() {
    if (this.port) {
      return;
    }
    try {
      const port = chrome.runtime.connectNative(this.hostName);
      this.port = port;
      this.reconnectAttempt = 0;
      this.setStatus({ state: "connected" });
      port.onMessage.addListener((message) => this.messageCallback?.(message));
      port.onDisconnect.addListener(() => {
        this.port = null;
        this.scheduleReconnect(chrome.runtime.lastError?.message ?? "native host disconnected");
      });
    } catch (error) {
      this.port = null;
      this.scheduleReconnect(error instanceof Error ? error.message : String(error));
    }
  }

  scheduleReconnect(error) {
    this.reconnectAttempt += 1;
    this.setStatus({ state: "reconnecting", error });
    // Alarms fire at most every 30 s; a restarted host is usually back within a second.
    if (this.reconnectAttempt <= 5) {
      setTimeout(() => this.connect(), 1000 * this.reconnectAttempt);
    }
    chrome.alarms.create(RECONNECT_ALARM_NAME, { periodInMinutes: 0.1 }).catch(() => {});
  }

  setStatus(status) {
    this.status = { hostName: this.hostName, lastChecked: Date.now(), reconnectAttempt: this.reconnectAttempt, ...status };
    chrome.storage.local.set({ [NATIVE_HOST_STATUS_KEY]: this.status }).catch(() => {});
  }
}

class SessionStore {
  constructor() {
    this.state = { sessions: {}, deliverableGroupId: null };
    this.ready = this.load();
  }

  async load() {
    const value = (await chrome.storage.local.get(SESSION_STATE_KEY))[SESSION_STATE_KEY];
    if (value && typeof value === "object") {
      this.state = {
        sessions: value.sessions && typeof value.sessions === "object" ? value.sessions : {},
        deliverableGroupId: typeof value.deliverableGroupId === "number" ? value.deliverableGroupId : null
      };
    }
  }

  async save() {
    await chrome.storage.local.set({ [SESSION_STATE_KEY]: this.state });
  }

  async getSession(sessionId) {
    await this.ready;
    const existing = this.state.sessions[sessionId];
    if (existing && typeof existing === "object") {
      return existing;
    }
    const created = { chromeGroupId: null, tabOrigins: {} };
    this.state.sessions[sessionId] = created;
    await this.save();
    return created;
  }

  async removeSession(sessionId) {
    await this.ready;
    delete this.state.sessions[sessionId];
    await this.save();
  }

  async findSessionByGroup(groupId) {
    await this.ready;
    for (const [sessionId, session] of Object.entries(this.state.sessions)) {
      if (session.chromeGroupId === groupId) {
        return { sessionId, session };
      }
    }
    return null;
  }
}

class BrowserBackend {
  constructor() {
    this.store = new SessionStore();
    this.attachedTabs = new Set();
    this.downloadsById = new Map();
    this.downloadWaiters = new Set();
    this.fileChoosersById = new Map();
    this.fileChooserWaitersByTabId = new Map();
    chrome.debugger.onDetach.addListener((source) => {
      if (typeof source.tabId === "number") {
        this.attachedTabs.delete(source.tabId);
      }
    });
  }

  ping() {
    return "pong";
  }

  async getInfo() {
    return {
      name: "Open Computer Use Browser",
      version: chrome.runtime.getManifest().version,
      extensionId: chrome.runtime.id,
      nativeHostName: NATIVE_HOST_NAME,
      profileToken: await profileToken()
    };
  }

  // Opens a tab without selecting it, so Chrome never comes forward.
  async createTab(params) {
    const session = await this.requireSession(params);
    const url = typeof params.url === "string" && params.url ? params.url : "about:blank";
    const tab = await createBackgroundTab(url);
    await this.ensureSessionGroup(session.sessionId, tab.id, "agent");
    return toBrowserTab(tab);
  }

  async getTabs(params) {
    const session = await this.requireSession(params);
    const tabs = await this.getSessionTabs(session.sessionId);
    const origins = (await this.store.getSession(session.sessionId)).tabOrigins;
    return tabs.map((tab) => ({ ...toBrowserTab(tab), origin: origins[String(tab.id)] ?? "user" }));
  }

  async getUserTabs(params) {
    await this.requireSession(params);
    const tabs = (await chrome.tabs.query({})).filter(hasTabId).sort(compareLastAccessed).slice(0, MAX_USER_TABS);
    return tabs.map((tab) => ({
      id: tab.id,
      windowId: tab.windowId,
      active: tab.active,
      ...(tab.title ? { title: tab.title } : {}),
      ...(tab.url ? { url: tab.url } : {})
    }));
  }

  async claimUserTab(params) {
    const session = await this.requireSession(params);
    const tabId = requireTabId(params, "claimUserTab");
    const tab = await chrome.tabs.get(tabId);
    if (tab.url?.startsWith("chrome://")) {
      throw new Error(`Chrome internal tab ${tabId} cannot be claimed`);
    }
    if (typeof tab.groupId === "number" && tab.groupId !== -1) {
      const owner = await this.store.findSessionByGroup(tab.groupId);
      if (owner && owner.sessionId !== session.sessionId) {
        throw new Error(`Tab ${tabId} is in use by another agent`);
      }
      if (owner) {
        return toBrowserTab(tab);
      }
      // A tab in the user's own group stays there; it is tracked without regrouping.
      const sessionState = await this.store.getSession(session.sessionId);
      sessionState.ungroupedTabs = [...new Set([...(sessionState.ungroupedTabs ?? []), tabId])];
      sessionState.tabOrigins[String(tabId)] = "user";
      await this.store.save();
      return toBrowserTab(tab);
    }
    await this.ensureSessionGroup(session.sessionId, tab.id, "user");
    return toBrowserTab(tab);
  }

  // Navigation through the tabs API: it never selects the tab or focuses the window.
  async tabCommand(params) {
    await this.requireSessionTab(params, "tabCommand");
    const tabId = params.tabId;
    switch (params.command) {
      case "navigate":
        await chrome.tabs.update(tabId, { url: requireNonEmptyString(params.url, "navigate requires url") });
        break;
      case "back":
        await chrome.tabs.goBack(tabId);
        break;
      case "forward":
        await chrome.tabs.goForward(tabId);
        break;
      case "reload":
        await chrome.tabs.reload(tabId);
        break;
      case "close": {
        const session = await this.store.getSession(params.session_id);
        if (session.tabOrigins[String(tabId)] !== "agent") {
          throw new Error(`Tab ${tabId} belongs to the user; release it instead of closing it`);
        }
        await this.detachTab(tabId).catch(() => {});
        await chrome.tabs.remove(tabId);
        delete session.tabOrigins[String(tabId)];
        await this.store.save();
        return {};
      }
      case "show": {
        const tab = await chrome.tabs.update(tabId, { active: true });
        await chrome.windows.update(tab.windowId, { focused: true });
        break;
      }
      default:
        throw new Error(`Unknown tab command ${String(params.command)}`);
    }
    return toBrowserTab(await chrome.tabs.get(tabId));
  }

  // Marks are stored at once so a client that exits without finalizing still keeps them.
  async markTab(params) {
    await this.requireSessionTab(params, "markTab");
    if (params.status !== "handoff" && params.status !== "deliverable") {
      throw new Error(`markTab received invalid status ${String(params.status)}`);
    }
    const session = await this.store.getSession(params.session_id);
    session.keep = { ...(session.keep ?? {}), [String(params.tabId)]: params.status };
    await this.store.save();
    return {};
  }

  async finalizeTabs(params) {
    const session = await this.requireSession(params);
    const keep = new Map();
    const stored = (await this.store.getSession(session.sessionId)).keep ?? {};
    for (const [tabId, status] of Object.entries(stored)) {
      keep.set(Number(tabId), status);
    }
    for (const entry of Array.isArray(params.keep) ? params.keep : []) {
      const tabId = requireTabId(entry, "finalizeTabs");
      if (entry.status !== "handoff" && entry.status !== "deliverable") {
        throw new Error(`finalizeTabs received invalid status ${String(entry.status)}`);
      }
      keep.set(tabId, entry.status);
    }
    const tabs = await this.getSessionTabs(session.sessionId);
    const sessionState = await this.store.getSession(session.sessionId);
    const close = [];
    const release = [];
    const deliverable = [];
    const handoff = [];
    for (const tab of tabs) {
      const kept = keep.get(tab.id);
      if (kept === "handoff") handoff.push(tab.id);
      else if (kept === "deliverable") deliverable.push(tab.id);
      else if (sessionState.tabOrigins[String(tab.id)] === "agent") close.push(tab.id);
      else release.push(tab.id);
    }
    // Detached even when kept: an attached debugger keeps Chrome's "is debugging this browser" bar up.
    await this.detachMany(tabs.map((tab) => tab.id));
    if (close.length > 0) {
      await chrome.tabs.remove(close).catch(() => {});
    }
    const ungrouped = new Set(sessionState.ungroupedTabs ?? []);
    const toUngroup = release.filter((tabId) => !ungrouped.has(tabId));
    if (toUngroup.length > 0) {
      await chrome.tabs.ungroup(toUngroup).catch(() => {});
    }
    if (deliverable.length > 0) {
      await this.moveToDeliverables(deliverable);
    }
    if (handoff.length > 0) {
      for (const tabId of [...close, ...release, ...deliverable]) {
        delete sessionState.tabOrigins[String(tabId)];
      }
      sessionState.ungroupedTabs = [...ungrouped].filter((tabId) => handoff.includes(tabId));
      sessionState.keep = {};
      await this.store.save();
    } else {
      await this.store.removeSession(session.sessionId);
    }
    return { closed: close.length, released: release.length, kept: deliverable.length + handoff.length };
  }

  async executeCdp(params) {
    await this.requireSessionTab(params, "executeCdp");
    const tabId = params.tabId;
    if (typeof params.method !== "string") {
      throw new Error("executeCdp requires method");
    }
    const timeoutMs = typeof params.timeoutMs === "number" && params.timeoutMs > 0 ? params.timeoutMs : DEFAULT_CDP_TIMEOUT_MS;
    const send = async () => {
      await this.attachTab(tabId);
      return await withTimeout(timeoutMs, () => chrome.debugger.sendCommand({ tabId }, params.method, params.commandParams ?? {}));
    };
    try {
      return await send();
    } catch (error) {
      // Chrome drops the debugger when another extension (a password manager) puts its own frame in the page.
      if (!/chrome-extension:\/\/|Detached while handling|not attached/i.test(String(error?.message ?? error))) {
        throw error;
      }
      this.attachedTabs.delete(tabId);
      await removeForeignExtensionFrames(tabId);
      return await send();
    }
  }

  async listSessions() {
    await this.store.ready;
    return Object.keys(this.store.state.sessions);
  }

  async reloadExtension() {
    setTimeout(() => chrome.runtime.reload(), 100);
    return {};
  }

  async detach(params) {
    await this.requireSessionTab(params, "detach");
    await this.detachTab(params.tabId);
  }

  async waitForFileChooser(params) {
    await this.requireSessionTab(params, "waitForFileChooser");
    const tabId = params.tabId;
    await this.attachTab(tabId);
    const timeoutMs = typeof params.timeoutMs === "number" && params.timeoutMs > 0 ? params.timeoutMs : DEFAULT_CDP_TIMEOUT_MS;
    const waitForEvent = this.waitForFileChooserEvent(tabId);
    try {
      await chrome.debugger.sendCommand({ tabId }, "Page.setInterceptFileChooserDialog", { enabled: true });
      return await withTimeout(timeoutMs, () => waitForEvent);
    } finally {
      this.fileChooserWaitersByTabId.delete(tabId);
      await chrome.debugger.sendCommand({ tabId }, "Page.setInterceptFileChooserDialog", { enabled: false }).catch(() => {});
    }
  }

  async setFileChooserFiles(params) {
    await this.requireSession(params);
    const chooser = this.fileChoosersById.get(params.fileChooserId);
    if (!chooser) {
      throw new Error(`Unknown file chooser id "${params.fileChooserId}"`);
    }
    if (!Array.isArray(params.files) || params.files.length === 0 || params.files.some((file) => typeof file !== "string" || !file)) {
      throw new Error("setFileChooserFiles requires at least one file path");
    }
    if (!chooser.isMultiple && params.files.length > 1) {
      throw new Error("File chooser does not accept multiple files");
    }
    await chrome.debugger.sendCommand({ tabId: chooser.tabId }, "DOM.setFileInputFiles", {
      backendNodeId: chooser.backendNodeId,
      files: params.files
    });
    this.fileChoosersById.delete(params.fileChooserId);
  }

  // Resolves with the first download that starts after `since` (ms since epoch) and finishes.
  async waitForDownload(params) {
    await this.requireSession(params);
    const since = typeof params.since === "number" ? params.since : 0;
    const timeoutMs = typeof params.timeoutMs === "number" && params.timeoutMs > 0 ? params.timeoutMs : 30_000;
    const done = (item) => item.startedAt >= since && (item.status === "complete" || item.status === "failed" || item.status === "canceled");
    for (const item of this.downloadsById.values()) {
      if (done(item)) return item;
    }
    return await new Promise((resolve, reject) => {
      const waiter = {
        check: (item) => {
          if (!done(item)) return;
          clearTimeout(timer);
          this.downloadWaiters.delete(waiter);
          resolve(item);
        }
      };
      const timer = setTimeout(() => {
        this.downloadWaiters.delete(waiter);
        reject(new Error("Timed out waiting for a download to finish."));
      }, timeoutMs);
      this.downloadWaiters.add(waiter);
    });
  }

  async turnEnded(params) {
    const session = await this.requireSession(params);
    const tabs = await this.getSessionTabs(session.sessionId);
    await this.detachMany(tabs.map((tab) => tab.id));
  }

  handleDownloadCreated(item) {
    if (!Number.isInteger(item?.id)) return;
    this.updateDownload(item.id, {
      id: String(item.id),
      url: item.finalUrl || item.url || "",
      filename: item.filename || "",
      status: "in_progress",
      startedAt: Date.parse(item.startTime) || Date.now()
    });
  }

  handleDownloadChanged(delta) {
    if (!Number.isInteger(delta?.id)) return;
    const change = {};
    if (typeof delta.filename?.current === "string") change.filename = delta.filename.current;
    const state = delta.state?.current;
    if (state === "complete") change.status = "complete";
    else if (state === "interrupted") change.status = delta.error?.current === "USER_CANCELED" ? "canceled" : "failed";
    this.updateDownload(delta.id, change);
  }

  updateDownload(id, change) {
    const item = { ...(this.downloadsById.get(id) ?? { id: String(id), startedAt: Date.now() }), ...change };
    this.downloadsById.set(id, item);
    for (const waiter of [...this.downloadWaiters]) waiter.check(item);
    if (this.downloadsById.size > 100) {
      this.downloadsById.delete(this.downloadsById.keys().next().value);
    }
  }

  handleCdpEvent(source, method, params) {
    if (method !== "Page.fileChooserOpened" || typeof source?.tabId !== "number") {
      return;
    }
    this.fileChooserWaitersByTabId.get(source.tabId)?.(params ?? {});
  }

  waitForFileChooserEvent(tabId) {
    if (this.fileChooserWaitersByTabId.has(tabId)) {
      throw new Error(`Already waiting for a file chooser in tab ${tabId}`);
    }
    return new Promise((resolve, reject) => {
      this.fileChooserWaitersByTabId.set(tabId, (event) => {
        this.fileChooserWaitersByTabId.delete(tabId);
        if (!Number.isInteger(event.backendNodeId)) {
          reject(new Error("File chooser event did not include backendNodeId"));
          return;
        }
        const fileChooserId = crypto.randomUUID();
        const isMultiple = event.mode === "selectMultiple";
        this.fileChoosersById.set(fileChooserId, { tabId, backendNodeId: event.backendNodeId, isMultiple });
        resolve({ fileChooserId, isMultiple });
      });
    });
  }

  async ensureSessionGroup(sessionId, tabId, origin) {
    const session = await this.store.getSession(sessionId);
    let groupId = session.chromeGroupId;
    if (typeof groupId === "number") {
      try {
        await chrome.tabGroups.get(groupId);
        await chrome.tabs.group({ groupId, tabIds: [tabId] });
      } catch {
        groupId = null;
      }
    }
    if (typeof groupId !== "number") {
      groupId = await chrome.tabs.group({ tabIds: [tabId] });
      session.chromeGroupId = groupId;
    }
    session.tabOrigins[String(tabId)] = origin;
    await this.store.save();
    await chrome.tabGroups.update(groupId, { title: SESSION_GROUP_TITLE, color: "blue", collapsed: false }).catch(() => {});
  }

  async getSessionTabs(sessionId) {
    const session = await this.store.getSession(sessionId);
    const tabs = [];
    if (typeof session.chromeGroupId === "number") {
      try {
        tabs.push(...(await chrome.tabs.query({ groupId: session.chromeGroupId })));
      } catch {
        session.chromeGroupId = null;
      }
    }
    for (const tabId of session.ungroupedTabs ?? []) {
      const tab = await chrome.tabs.get(tabId).catch(() => null);
      if (tab) tabs.push(tab);
    }
    return tabs.filter((tab) => hasTabId(tab) && !tab.url?.startsWith("chrome://"));
  }

  async requireSession(params) {
    if (!params || typeof params.session_id !== "string") {
      throw new Error("Missing required browser session_id");
    }
    await this.store.getSession(params.session_id);
    return { sessionId: params.session_id };
  }

  async requireSessionTab(params, command) {
    const session = await this.requireSession(params);
    const tabId = requireTabId(params, command);
    const tabs = await this.getSessionTabs(session.sessionId);
    if (!tabs.some((tab) => tab.id === tabId)) {
      throw new Error(`Tab ${tabId} is not open in this session; open it or claim it first`);
    }
  }

  async moveToDeliverables(tabIds) {
    const tabs = (await Promise.all(tabIds.map((id) => chrome.tabs.get(id).catch(() => null)))).filter(hasTabId);
    const byWindow = new Map();
    for (const tab of tabs) {
      byWindow.set(tab.windowId, [...(byWindow.get(tab.windowId) ?? []), tab.id]);
    }
    for (const [windowId, ids] of byWindow) {
      const existing = await chrome.tabGroups.query({ windowId, title: DELIVERABLE_GROUP_TITLE }).catch(() => []);
      let groupId = existing[0]?.id;
      try {
        groupId = await chrome.tabs.group(typeof groupId === "number" ? { groupId, tabIds: ids } : { tabIds: ids });
      } catch {
        groupId = await chrome.tabs.group({ tabIds: ids });
      }
      await chrome.tabGroups.update(groupId, { title: DELIVERABLE_GROUP_TITLE, color: "green", collapsed: false }).catch(() => {});
      this.store.state.deliverableGroupId = groupId;
    }
    await this.store.save();
  }

  async attachTab(tabId) {
    if (this.attachedTabs.has(tabId)) {
      return;
    }
    try {
      await chrome.debugger.attach({ tabId }, "1.3");
    } catch (error) {
      const message = String(error?.message ?? error);
      if (message.includes("chrome-extension://")) {
        await removeForeignExtensionFrames(tabId);
        await chrome.debugger.attach({ tabId }, "1.3");
      } else if (!message.includes("Another debugger")) {
        throw error;
      }
    }
    this.attachedTabs.add(tabId);
    // Dialog events need the Page domain; a background tab otherwise reports no focus.
    await chrome.debugger.sendCommand({ tabId }, "Page.enable").catch(() => {});
    await chrome.debugger.sendCommand({ tabId }, "Emulation.setFocusEmulationEnabled", { enabled: true }).catch(() => {});
  }

  async detachMany(tabIds) {
    await Promise.allSettled(tabIds.map((tabId) => this.detachTab(tabId)));
  }

  async detachTab(tabId) {
    try {
      if (this.attachedTabs.has(tabId)) {
        await chrome.debugger.detach({ tabId });
      }
    } finally {
      this.attachedTabs.delete(tabId);
      for (const [id, chooser] of this.fileChoosersById) {
        if (chooser.tabId === tabId) this.fileChoosersById.delete(id);
      }
    }
  }
}

function hasTabId(tab) {
  return typeof tab?.id === "number";
}

function toBrowserTab(tab) {
  return { id: tab.id, title: tab.title, url: tab.pendingUrl || tab.url, status: tab.status };
}

function requireTabId(params, command) {
  if (!Number.isInteger(params?.tabId)) {
    throw new Error(`${command} requires an integer tabId`);
  }
  return params.tabId;
}

function requireNonEmptyString(value, message) {
  if (typeof value !== "string" || !value.trim()) {
    throw new Error(message);
  }
  return value;
}

// Open Computer Use finds this token in the profile's storage files to tell which profile it is.
async function profileToken() {
  const stored = (await chrome.storage.local.get(PROFILE_TOKEN_KEY))[PROFILE_TOKEN_KEY];
  if (stored) return stored;
  const token = `ocu-profile-${crypto.randomUUID()}`;
  await chrome.storage.local.set({ [PROFILE_TOKEN_KEY]: token });
  return token;
}

async function createBackgroundTab(url) {
  const windows = await chrome.windows.getAll({ windowTypes: ["normal"] });
  const window = windows.find((win) => win.focused) ?? windows[0];
  if (typeof window?.id === "number") {
    const tab = await chrome.tabs.create({ active: false, url, windowId: window.id });
    if (hasTabId(tab)) return tab;
  }
  // A profile with no window: minimised so it never covers the user's windows (Chrome on macOS
  // ignores state "minimized" at creation).
  const created = await chrome.windows.create({ focused: false, type: "normal", url });
  await chrome.windows.update(created.id, { state: "minimized" }).catch(() => {});
  const tab = created.tabs?.find(hasTabId);
  if (!tab) throw new Error("Created Chrome window has no tab");
  return tab;
}

async function removeForeignExtensionFrames(tabId) {
  const own = `chrome-extension://${chrome.runtime.id}/`;
  await chrome.scripting.executeScript({
    target: { tabId, allFrames: true },
    world: "MAIN",
    args: [own],
    func: (ownOrigin) => {
      const walk = (root) => {
        for (const frame of root.querySelectorAll("iframe, embed, object")) {
          const src = frame.src || frame.data || "";
          if (src.startsWith("chrome-extension://") && !src.startsWith(ownOrigin)) frame.remove();
        }
        for (const el of root.querySelectorAll("*")) if (el.shadowRoot) walk(el.shadowRoot);
      };
      walk(document);
    }
  }).catch(() => {});
}

function compareLastAccessed(left, right) {
  return (right.lastAccessed ?? 0) - (left.lastAccessed ?? 0);
}

async function withTimeout(timeoutMs, fn) {
  let timeout;
  try {
    return await Promise.race([
      fn(),
      new Promise((_, reject) => {
        timeout = setTimeout(() => reject(new Error(`Timed out after ${timeoutMs}ms waiting for Chrome.`)), timeoutMs);
      })
    ]);
  } finally {
    clearTimeout(timeout);
  }
}

function safeSendNotification(peer, method, params) {
  try {
    peer.sendNotification(method, params);
  } catch {}
}

const backend = new BrowserBackend();
const transport = new NativeTransport(NATIVE_HOST_NAME);
const peer = new JsonRpcPeer(transport, backend);
chrome.runtime.onMessage.addListener((message, _sender, sendResponse) => {
  if (message?.type === "GET_NATIVE_HOST_STATUS") {
    sendResponse({ ok: transport.status.state === "connected", status: transport.status });
    return true;
  }
  return false;
});
chrome.debugger.onEvent.addListener((source, method, params) => {
  backend.handleCdpEvent(source, method, params);
  if (FORWARDED_CDP_EVENTS.has(method)) {
    safeSendNotification(peer, "onCDPEvent", { source, method, params });
  }
});
chrome.downloads.onCreated.addListener((item) => backend.handleDownloadCreated(item));
chrome.downloads.onChanged.addListener((delta) => backend.handleDownloadChanged(delta));
chrome.alarms.create(HEARTBEAT_ALARM_NAME, { periodInMinutes: 0.5 }).catch(() => {});
// Wakes the worker, and with it the native connection, as soon as the profile starts.
chrome.runtime.onStartup.addListener(() => {});
chrome.alarms.onAlarm.addListener((alarm) => {
  if (alarm.name === HEARTBEAT_ALARM_NAME) {
    safeSendNotification(peer, "heartbeat", { at: new Date().toISOString() });
  }
});
