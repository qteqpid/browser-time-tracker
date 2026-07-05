const ENDPOINT = 'http://127.0.0.1:38888/events';
const HEARTBEAT_ALARM = 'browser-time-tracker-heartbeat';
const HEARTBEAT_MINUTES = 0.5;
const IDLE_SECONDS = 300;

let lastActiveTab = null;
let isIdle = false;

const browserName = () => {
  const userAgent = navigator.userAgent;
  if (userAgent.includes('Edg/')) return 'edge';
  if (userAgent.includes('Firefox/')) return 'firefox';
  return 'chrome';
};

const isTrackable = (url) => {
  return typeof url === 'string' && (url.startsWith('http://') || url.startsWith('https://'));
};

const postEvent = async (event, tab = null) => {
  const payload = {
    browser: browserName(),
    event,
    url: tab?.url ?? null,
    title: tab?.title ?? null,
    timestamp: new Date().toISOString()
  };

  try {
    await fetch(ENDPOINT, {
      method: 'POST',
      headers: { 'content-type': 'application/json' },
      body: JSON.stringify(payload)
    });
  } catch {
    // The local service may not be installed or running. Stay quiet; this keeps the
    // extension transparent and avoids noisy retry behavior.
  }
};

const activateTab = async (tab) => {
  if (!tab || !isTrackable(tab.url)) {
    lastActiveTab = null;
    await postEvent('page_hidden');
    return;
  }

  lastActiveTab = {
    id: tab.id,
    windowId: tab.windowId,
    url: tab.url,
    title: tab.title ?? ''
  };

  if (!isIdle) {
    await postEvent('page_active', lastActiveTab);
  }
};

const refreshActiveTab = async () => {
  const [tab] = await chrome.tabs.query({ active: true, lastFocusedWindow: true });
  await activateTab(tab);
};

chrome.runtime.onInstalled.addListener(() => {
  chrome.idle.setDetectionInterval(IDLE_SECONDS);
  chrome.alarms.create(HEARTBEAT_ALARM, { periodInMinutes: HEARTBEAT_MINUTES });
  refreshActiveTab();
});

chrome.runtime.onStartup.addListener(() => {
  chrome.idle.setDetectionInterval(IDLE_SECONDS);
  chrome.alarms.create(HEARTBEAT_ALARM, { periodInMinutes: HEARTBEAT_MINUTES });
  refreshActiveTab();
});

chrome.tabs.onActivated.addListener(async ({ tabId }) => {
  const tab = await chrome.tabs.get(tabId);
  await activateTab(tab);
});

chrome.tabs.onUpdated.addListener(async (tabId, changeInfo, tab) => {
  if (changeInfo.status !== 'complete' && !changeInfo.url) return;
  if (lastActiveTab?.id !== tabId) return;
  await activateTab(tab);
});

chrome.tabs.onRemoved.addListener(async (tabId) => {
  if (lastActiveTab?.id === tabId) {
    lastActiveTab = null;
    await postEvent('page_closed');
  }
});

chrome.windows.onFocusChanged.addListener(async (windowId) => {
  if (windowId === chrome.windows.WINDOW_ID_NONE) {
    await postEvent('browser_blurred');
    return;
  }
  await refreshActiveTab();
});

chrome.idle.onStateChanged.addListener(async (state) => {
  isIdle = state !== 'active';
  if (isIdle) {
    await postEvent('user_idle');
  } else {
    await refreshActiveTab();
  }
});

chrome.alarms.onAlarm.addListener(async (alarm) => {
  if (alarm.name !== HEARTBEAT_ALARM || isIdle || !lastActiveTab) return;
  await postEvent('heartbeat', lastActiveTab);
});
