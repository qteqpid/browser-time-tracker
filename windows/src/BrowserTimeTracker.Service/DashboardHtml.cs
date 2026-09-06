namespace BrowserTimeTracker.Service;

public static class DashboardHtml
{
    public const string Value = """
<!doctype html>
<html lang="en">
<head>
  <meta charset="utf-8">
  <meta name="viewport" content="width=device-width, initial-scale=1">
  <title>Browser Time Tracker</title>
  <style>
    :root { color-scheme: light dark; --bg: #f6f7f4; --ink: #20231f; --muted: #6d756c; --line: rgba(38,48,35,.14); --surface: rgba(255,255,252,.9); --accent: #0f766e; --accent-2: #9f5b14; font-family: "Segoe UI", system-ui, sans-serif; }
    @media (prefers-color-scheme: dark) { :root { --bg: #11140f; --ink: #f3f5ef; --muted: #a6afa2; --line: rgba(243,245,239,.14); --surface: rgba(25,29,23,.9); --accent: #2dd4bf; --accent-2: #f59e0b; } }
    * { box-sizing: border-box; }
    body { margin: 0; min-height: 100vh; background: var(--bg); color: var(--ink); }
    main { max-width: 1120px; margin: 0 auto; padding: 34px 22px 42px; }
    header { display: flex; justify-content: space-between; gap: 18px; align-items: flex-start; padding-bottom: 18px; border-bottom: 1px solid var(--line); margin-bottom: 22px; }
    h1 { margin: 0; font-size: 30px; line-height: 1.08; letter-spacing: 0; }
    .subtitle { margin-top: 8px; color: var(--muted); font-size: 13px; }
    .controls { display: flex; gap: 8px; flex-wrap: wrap; justify-content: flex-end; }
    input, select, button { height: 34px; border: 1px solid var(--line); border-radius: 6px; background: var(--surface); color: var(--ink); padding: 0 10px; font: inherit; }
    button { cursor: pointer; }
    .summary { display: grid; grid-template-columns: minmax(220px,300px) minmax(0,1fr); gap: 18px; margin-bottom: 18px; }
    .metric, .chart, section { border: 1px solid var(--line); border-radius: 8px; background: var(--surface); box-shadow: 0 16px 42px rgba(38,48,35,.09); }
    .metric-stack { display: grid; gap: 12px; }
    .metric { min-height: 83px; padding: 16px 18px; display: flex; flex-direction: column; justify-content: space-between; }
    .metric-label, h2, .chart-title { margin: 0 0 14px; color: var(--muted); font-size: 12px; font-weight: 700; letter-spacing: .04em; text-transform: uppercase; }
    .total { font-size: clamp(30px,5vw,42px); color: var(--accent); font-weight: 780; line-height: .95; font-variant-numeric: tabular-nums; }
    .total.app { color: var(--accent-2); }
    .chart, section { padding: 18px; }
    .bars { display: grid; grid-template-columns: repeat(24,minmax(0,1fr)); gap: 4px; height: 146px; align-items: end; border-bottom: 1px solid var(--line); }
    .day-bars { display: grid; grid-template-columns: repeat(7,minmax(0,1fr)); gap: 10px; height: 162px; align-items: end; border-bottom: 1px solid var(--line); }
    .bar, .day-bar { width: 100%; height: var(--height); min-height: 0; border: 0; border-radius: 5px 5px 0 0; background: var(--accent); opacity: .88; padding: 0; }
    .bar.empty, .day-bar.empty { background: var(--line); cursor: default; }
    .ticks, .day-ticks { display: grid; gap: 4px; margin-top: 9px; color: var(--muted); font-size: 11px; text-align: center; font-variant-numeric: tabular-nums; }
    .ticks { grid-template-columns: repeat(24,minmax(0,1fr)); }
    .day-ticks { grid-template-columns: repeat(7,minmax(0,1fr)); gap: 10px; font-weight: 650; }
    .grid { display: grid; grid-template-columns: repeat(2,minmax(0,1fr)); gap: 18px; }
    .row { display: grid; grid-template-columns: minmax(0,1fr) auto; gap: 14px; align-items: center; min-height: 44px; padding: 10px 8px; border-top: 1px solid var(--line); }
    .row:first-child { border-top: 0; }
    .label { overflow: hidden; text-overflow: ellipsis; white-space: nowrap; }
    .secondary { color: var(--muted); font-size: 12px; overflow: hidden; text-overflow: ellipsis; white-space: nowrap; margin-top: 3px; }
    .time { color: var(--accent); font-weight: 760; font-variant-numeric: tabular-nums; }
    .time.app { color: var(--accent-2); }
    .timeline-row { grid-template-columns: 105px minmax(0,1fr) auto; }
    .range { color: var(--muted); font-size: 12px; font-variant-numeric: tabular-nums; white-space: nowrap; }
    a { color: inherit; text-decoration: none; }
    a:hover { text-decoration: underline; }
    @media (max-width: 760px) { main { padding: 22px 14px 30px; } header { display: block; } .controls { justify-content: flex-start; margin-top: 14px; } .summary, .grid { grid-template-columns: 1fr; } .timeline-row { grid-template-columns: 1fr auto; } .range { grid-column: 1 / -1; } }
  </style>
</head>
<body>
  <main>
    <header>
      <div>
        <h1>Browser Time Tracker</h1>
        <div class="subtitle" id="window">Today</div>
      </div>
      <div class="controls">
        <input id="date" type="date">
        <select id="hour"></select>
        <button id="today" type="button">Today</button>
      </div>
    </header>
    <div class="summary">
      <div class="metric-stack">
        <div class="metric">
          <div class="metric-label">Program time</div>
          <div class="total app" id="appTotal">0m</div>
        </div>
        <div class="metric">
          <div class="metric-label">Browser page time</div>
          <div class="total" id="browserTotal">0m</div>
        </div>
      </div>
      <div class="chart">
        <div class="chart-title">Browser daily usage</div>
        <div class="day-bars" id="dayBars"></div>
        <div class="day-ticks" id="dayTicks"></div>
      </div>
    </div>
    <div class="chart">
      <div class="chart-title">Browser hourly usage</div>
      <div class="bars" id="bars"></div>
      <div class="ticks" id="hourTicks"></div>
    </div>
    <div class="grid" style="margin-top:18px">
      <section><h2>Top Users</h2><div id="users"></div></section>
      <section><h2>Top Programs</h2><div id="apps"></div></section>
      <section><h2>Top Windows</h2><div id="appWindows"></div></section>
      <section><h2>Top Websites</h2><div id="domains"></div></section>
      <section><h2>Top Pages</h2><div id="pages"></div></section>
    </div>
    <div class="grid" style="margin-top:18px">
      <section><h2>Program Sessions</h2><div id="appTimeline"></div></section>
      <section><h2>Page Sessions</h2><div id="pageTimeline"></div></section>
    </div>
  </main>
  <script>
    const format = seconds => {
      const minutes = Math.floor(seconds / 60);
      return minutes < 60 ? `${minutes}m` : `${Math.floor(minutes / 60)}h ${minutes % 60}m`;
    };
    const formatClock = seconds => new Date(seconds * 1000).toLocaleTimeString([], { hour: '2-digit', minute: '2-digit' });
    const escapeHtml = value => String(value ?? '').replace(/[&<>"']/g, c => ({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#39;'}[c]));
    const localDateValue = date => new Date(date.getTime() - date.getTimezoneOffset() * 60000).toISOString().slice(0, 10);
    const dateInput = document.getElementById('date');
    const hourSelect = document.getElementById('hour');
    hourSelect.innerHTML = '<option value="all">All day</option>' + Array.from({length: 24}, (_, hour) => `<option value="${hour}">${String(hour).padStart(2, '0')}:00-${String(hour + 1).padStart(2, '0')}:00</option>`).join('');
    dateInput.value = localDateValue(new Date());
    document.getElementById('hourTicks').innerHTML = Array.from({length: 24}, (_, hour) => `<span>${hour % 3 === 0 ? String(hour).padStart(2, '0') : ''}</span>`).join('');

    const renderList = (id, items) => {
      const node = document.getElementById(id);
      node.innerHTML = items.length ? items.map(item => {
        const label = item.url ? `<a class="label" href="${escapeHtml(item.url)}" target="_blank" rel="noreferrer">${escapeHtml(item.label)}</a>` : `<span class="label">${escapeHtml(item.label)}</span>`;
        return `<div class="row">${label}<span class="time">${format(item.seconds)}</span></div>`;
      }).join('') : '<div class="row"><span class="label">No data yet</span><span class="time">0m</span></div>';
    };

    const renderTimeline = (id, items, kind) => {
      const node = document.getElementById(id);
      node.innerHTML = items.length ? items.map(item => {
        const label = item.url ? `<a class="label" href="${escapeHtml(item.url)}" target="_blank" rel="noreferrer">${escapeHtml(item.label)}</a>` : `<span class="label">${escapeHtml(item.label)}</span>`;
        const secondary = item.secondary ? `<div class="secondary">${escapeHtml(item.secondary)}</div>` : '';
        return `<div class="row timeline-row"><span class="range">${formatClock(item.startedAt)}-${formatClock(item.endedAt)}</span><div>${label}${secondary}</div><span class="time ${kind === 'app' ? 'app' : ''}">${format(item.seconds)}</span></div>`;
      }).join('') : '<div class="row"><span class="label">No sessions yet</span><span class="time">0m</span></div>';
    };

    const renderBars = (id, items, key) => {
      const max = Math.max(...items.map(item => item.seconds), 0);
      document.getElementById(id).innerHTML = items.map(item => {
        const percent = max > 0 ? Math.max(4, Math.round(item.seconds / max * 100)) : 0;
        return `<button class="${key === 'hour' ? 'bar' : 'day-bar'} ${item.seconds === 0 ? 'empty' : ''}" data-value="${item[key]}" title="${escapeHtml(item.date || String(item.hour).padStart(2, '0'))} ${format(item.seconds)}" style="--height:${percent}%"></button>`;
      }).join('');
    };

    const refresh = async () => {
      const params = new URLSearchParams({ date: dateInput.value, hour: hourSelect.value });
      const response = await fetch(`/api/summary?${params}`);
      const data = await response.json();
      document.getElementById('window').textContent = data.windowLabel;
      document.getElementById('appTotal').textContent = format(data.appTotalSeconds);
      document.getElementById('browserTotal').textContent = format(data.totalSeconds);
      renderBars('bars', data.hours, 'hour');
      renderBars('dayBars', data.days, 'date');
      document.getElementById('dayTicks').innerHTML = data.days.map(item => `<span>${escapeHtml(item.label)}</span>`).join('');
      document.querySelectorAll('.bar').forEach(bar => bar.addEventListener('click', () => { hourSelect.value = bar.dataset.value; refresh(); }));
      document.querySelectorAll('.day-bar').forEach(bar => bar.addEventListener('click', () => { dateInput.value = bar.dataset.value; hourSelect.value = 'all'; refresh(); }));
      renderList('users', data.users);
      renderList('apps', data.apps);
      renderList('appWindows', data.appWindows);
      renderList('domains', data.domains);
      renderList('pages', data.pages);
      renderTimeline('appTimeline', data.appTimeline, 'app');
      renderTimeline('pageTimeline', data.pageTimeline, 'page');
    };

    dateInput.addEventListener('change', refresh);
    hourSelect.addEventListener('change', refresh);
    document.getElementById('today').addEventListener('click', () => { dateInput.value = localDateValue(new Date()); hourSelect.value = 'all'; refresh(); });
    refresh();
    setInterval(refresh, 30000);
  </script>
</body>
</html>
""";
}
