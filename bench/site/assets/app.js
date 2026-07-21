"use strict";

const METRICS = {
  native_mhz: { label: "Prove MHz", unit: "MHz", decimals: 3, higher: true },
  request_native_mhz: { label: "Request MHz", unit: "MHz", decimals: 3, higher: true },
  prove_seconds: { label: "Prove time", unit: "s", decimals: 4, higher: false },
  request_seconds: { label: "Total time", unit: "s", decimals: 4, higher: false },
  verify_seconds: { label: "Verify time", unit: "s", decimals: 5, higher: false },
  peak_rss_kib: { label: "Peak memory", unit: "MiB", decimals: 1, higher: false },
};

const state = {
  catalog: null,
  runId: null,
  tab: "overview",
  metric: "native_mhz",
  workloadId: null,
};

let toastTimer = null;

function element(tag, className, text) {
  const node = document.createElement(tag);
  if (className) node.className = className;
  if (text !== undefined) node.textContent = text;
  return node;
}

function clear(node) {
  node.replaceChildren();
  return node;
}

function selectedRun() {
  return state.catalog.runs.find((run) => run.id === state.runId) || state.catalog.runs[0];
}

function shortCommit(commit) {
  return String(commit).slice(0, 10);
}

function dateTime(value) {
  const date = new Date(value);
  return new Intl.DateTimeFormat("en", {
    dateStyle: "medium",
    timeStyle: "short",
    timeZone: "UTC",
  }).format(date) + " UTC";
}

function compactDate(value) {
  return new Intl.DateTimeFormat("en", {
    month: "short",
    day: "2-digit",
    hour: "2-digit",
    minute: "2-digit",
    timeZone: "UTC",
    hour12: false,
  }).format(new Date(value));
}

function formatParameters(parameters) {
  return Object.entries(parameters)
    .map(([key, value]) => `${key}=${value}`)
    .join(" · ");
}

function metricValue(row, laneName, metricName) {
  const value = row.lanes[laneName].metrics[metricName].median;
  return metricName === "peak_rss_kib" ? value / 1024 : value;
}

function formatMetric(value, metricName, includeUnit = true) {
  const metric = METRICS[metricName];
  const formatted = Number(value).toFixed(metric.decimals);
  return includeUnit ? `${formatted} ${metric.unit}` : formatted;
}

function ratioFor(row, metricName) {
  const cpu = metricValue(row, "cpu", metricName);
  const metal = metricValue(row, "metal", metricName);
  return cpu === 0 ? 0 : metal / cpu;
}

function ratioClass(ratio, higherIsBetter) {
  if (Math.abs(ratio - 1) < 0.000001) return "";
  const metalImproves = higherIsBetter ? ratio > 1 : ratio < 1;
  return metalImproves ? "outcome-positive" : "outcome-negative";
}

function appendDefinition(list, term, value) {
  const row = element("div");
  row.append(element("dt", "", term), element("dd", "", String(value)));
  list.append(row);
}

function showToast(message) {
  const toast = document.getElementById("toast");
  toast.textContent = message;
  toast.classList.add("is-visible");
  window.clearTimeout(toastTimer);
  toastTimer = window.setTimeout(() => toast.classList.remove("is-visible"), 1800);
}

function renderRunOptions() {
  const select = clear(document.getElementById("run-select"));
  state.catalog.runs.forEach((run, index) => {
    const label = `${compactDate(run.captured_at)} · ${shortCommit(run.revision.git_commit)}${index === 0 ? " · latest" : ""}`;
    const option = element("option", "", label);
    option.value = run.id;
    option.selected = run.id === state.runId;
    select.append(option);
  });
}

function renderRunStrip(run) {
  const commit = document.getElementById("commit-copy");
  commit.textContent = shortCommit(run.revision.git_commit);
  commit.title = `Copy ${run.revision.git_commit}`;
  document.getElementById("captured-at").textContent = dateTime(run.captured_at);
  document.getElementById("captured-at").dateTime = run.captured_at;
  document.getElementById("machine-name").textContent = `${run.machine.chip} · ${run.machine.model}`;
  document.getElementById("protocol-name").textContent = `${run.settings.proof_protocol} · ${run.settings.metal_runtime}`;
  document.getElementById("evidence-state").textContent = "oracle verified";
}

function kpi(label, value, note, className = "") {
  const node = element("article", `kpi ${className}`.trim());
  node.append(
    element("span", "kpi-label", label),
    element("strong", "kpi-value", value),
    element("span", "kpi-note", note),
  );
  return node;
}

function renderKpis(run) {
  const summary = run.summary;
  const grid = clear(document.getElementById("kpi-grid"));
  grid.append(
    kpi("CPU/SIMD median", `${summary.median_cpu_mhz.toFixed(3)} MHz`, `${summary.headline_rows} headline rows`, "cpu-kpi"),
    kpi("Metal median", `${summary.median_metal_mhz.toFixed(3)} MHz`, `${summary.metal_wins} workload wins`, "metal-kpi"),
    kpi("Metal / CPU median", `${summary.median_metal_speedup.toFixed(3)}x`, "headline-eligible rows"),
    kpi("Verified proofs", summary.verified_proofs.toLocaleString(), "CPU + Metal samples"),
  );
}

function renderComparison(run) {
  const chart = clear(document.getElementById("comparison-chart"));
  const max = Math.max(...run.rows.flatMap((row) => [
    metricValue(row, "cpu", "native_mhz"),
    metricValue(row, "metal", "native_mhz"),
  ]));
  run.rows.forEach((row) => {
    const cpu = metricValue(row, "cpu", "native_mhz");
    const metal = metricValue(row, "metal", "native_mhz");
    const container = element("div", "comparison-row");
    const label = element("div", "workload-label", row.workload.name.replaceAll("_", " "));
    label.append(element("span", "workload-shape", formatParameters(row.workload.parameters)));
    const pair = element("div", "bar-pair");
    [["cpu", cpu], ["metal", metal]].forEach(([lane, value]) => {
      const track = element("div", "bar-track");
      const bar = element("div", `bar ${lane}`);
      bar.style.width = `${Math.max((value / max) * 100, 0.4).toFixed(3)}%`;
      bar.title = `${lane === "cpu" ? "CPU/SIMD" : "Metal"}: ${value.toFixed(6)} MHz`;
      track.append(bar);
      pair.append(track);
    });
    const value = element("div", "bar-value");
    value.append(
      element("span", "value-cpu", cpu.toFixed(3)),
      element("span", "value-metal", metal.toFixed(3)),
    );
    container.append(label, pair, value);
    chart.append(container);
  });
}

function renderMetricTabs() {
  const tabs = clear(document.getElementById("metric-tabs"));
  Object.entries(METRICS).forEach(([name, definition]) => {
    const button = element("button", `metric-tab${name === state.metric ? " is-active" : ""}`, definition.label);
    button.type = "button";
    button.role = "tab";
    button.dataset.metric = name;
    button.ariaSelected = name === state.metric ? "true" : "false";
    tabs.append(button);
  });
}

function renderWorkloadTable(run) {
  const body = clear(document.querySelector("#workload-table tbody"));
  document.getElementById("cpu-metric-heading").textContent = `CPU ${METRICS[state.metric].label}`;
  document.getElementById("metal-metric-heading").textContent = `Metal ${METRICS[state.metric].label}`;
  run.rows.forEach((row) => {
    const cpu = metricValue(row, "cpu", state.metric);
    const metal = metricValue(row, "metal", state.metric);
    const ratio = ratioFor(row, state.metric);
    const tr = element("tr", row.id === state.workloadId ? "is-selected" : "");
    tr.dataset.workload = row.id;
    tr.tabIndex = 0;
    const evidence = row.headline_eligible ? "formal" : "diagnostic";
    const cells = [
      [row.workload.name.replaceAll("_", " "), ""],
      [formatParameters(row.workload.parameters), ""],
      [formatMetric(cpu, state.metric), "value-cpu"],
      [formatMetric(metal, state.metric), "value-metal"],
      [`${ratio.toFixed(3)}x`, ratioClass(ratio, METRICS[state.metric].higher)],
      [evidence, row.headline_eligible ? "outcome-positive" : ""],
    ];
    cells.forEach(([text, className]) => tr.append(element("td", className, text)));
    body.append(tr);
  });
}

function renderWorkloadDetail(run) {
  const row = run.rows.find((candidate) => candidate.id === state.workloadId) || run.rows[0];
  state.workloadId = row.id;
  const detail = clear(document.getElementById("workload-detail"));
  const heading = element("div", "detail-heading");
  heading.append(element("p", "eyebrow", `Row ${String(row.index + 1).padStart(2, "0")}`));
  heading.append(element("h2", "", row.workload.name.replaceAll("_", " ")));
  const badges = element("div", "badge-row");
  badges.append(element("span", `badge ${row.headline_eligible ? "formal" : "diagnostic"}`, row.headline_eligible ? "headline" : "diagnostic"));
  badges.append(element("span", "badge", `${row.workload.trace_rows.toLocaleString()} rows`));
  badges.append(element("span", "badge", `${row.workload.committed_columns.toLocaleString()} columns`));
  heading.append(badges);
  detail.append(heading);

  const metrics = element("dl", "detail-metrics");
  appendDefinition(metrics, "CPU prove", formatMetric(metricValue(row, "cpu", "prove_seconds"), "prove_seconds"));
  appendDefinition(metrics, "Metal prove", formatMetric(metricValue(row, "metal", "prove_seconds"), "prove_seconds"));
  appendDefinition(metrics, "CPU throughput", formatMetric(metricValue(row, "cpu", "native_mhz"), "native_mhz"));
  appendDefinition(metrics, "Metal throughput", formatMetric(metricValue(row, "metal", "native_mhz"), "native_mhz"));
  appendDefinition(metrics, "Committed cells", row.workload.committed_trace_cells.toLocaleString());
  appendDefinition(metrics, "Proof size", `${(row.proof.bytes / 1024).toFixed(1)} KiB`);
  appendDefinition(metrics, "Rust oracle", `verified @ ${shortCommit(row.proof.rust_upstream_commit)}`);
  ["cpu", "metal"].forEach((laneName) => {
    const resources = row.lanes[laneName].request_resources;
    if (!resources?.complete) return;
    const requests = resources.measured_warmups + resources.measured_samples;
    const footprint = resources.lifetime_peak_physical_footprint_bytes / (1024 * 1024);
    const energy = resources.energy_nj / requests / 1e9;
    const instructions = resources.instructions / requests / 1e6;
    const cycles = resources.cycles / requests / 1e6;
    const label = laneName === "cpu" ? "CPU batch" : "Metal batch";
    appendDefinition(
      metrics,
      label,
      `${footprint.toFixed(1)} MiB · ${energy.toFixed(3)} J/request · ${instructions.toFixed(1)}M inst · ${cycles.toFixed(1)}M cycles`,
    );
  });
  detail.append(metrics);
  const digest = element("span", "proof-digest", `proof ${row.proof.sha256}`);
  digest.title = row.proof.sha256;
  detail.append(digest);
}

function percentChange(current, baseline) {
  return baseline === 0 ? 0 : ((current / baseline) - 1) * 100;
}

function renderHistory() {
  const current = selectedRun();
  const position = state.catalog.runs.findIndex((run) => run.id === current.id);
  const currentSuite = current.rows
    .map((row) => `${row.descriptor_sha256}:${row.headline_eligible}`)
    .join(":");
  const baseline = state.catalog.runs.slice(position + 1).find(
    (run) => run.rows
      .map((row) => `${row.descriptor_sha256}:${row.headline_eligible}`)
      .join(":") === currentSuite,
  ) || null;
  const summary = clear(document.getElementById("history-summary"));
  summary.append(element("p", "eyebrow", baseline ? "Observed against preceding same-suite run" : "No same-suite predecessor"));
  summary.append(element("h2", "", baseline ? `${shortCommit(current.revision.git_commit)} vs ${shortCommit(baseline.revision.git_commit)}` : shortCommit(current.revision.git_commit)));
  const comparisons = [
    ["CPU median MHz", "median_cpu_mhz", true],
    ["Metal median MHz", "median_metal_mhz", true],
    ["Metal / CPU median", "median_metal_speedup", true],
    ["Verified proofs", "verified_proofs", true],
  ];
  comparisons.forEach(([label, key, higher]) => {
    const row = element("div", "history-delta");
    row.append(element("span", "history-delta-label", label));
    let text = "baseline";
    let className = "history-delta-value";
    if (baseline) {
      const delta = percentChange(current.summary[key], baseline.summary[key]);
      text = `${delta >= 0 ? "+" : ""}${delta.toFixed(2)}%`;
      className += ` ${ratioClass(1 + delta / 100, higher)}`;
    }
    row.append(element("strong", className, text));
    summary.append(row);
  });

  const body = clear(document.querySelector("#history-table tbody"));
  state.catalog.runs.forEach((run) => {
    const tr = element("tr", run.id === current.id ? "is-selected" : "");
    tr.dataset.run = run.id;
    tr.tabIndex = 0;
    [
      compactDate(run.captured_at),
      shortCommit(run.revision.git_commit),
      run.machine.chip,
      `${run.summary.median_cpu_mhz.toFixed(3)} MHz`,
      `${run.summary.median_metal_mhz.toFixed(3)} MHz`,
      run.summary.verified_proofs.toLocaleString(),
    ].forEach((text, index) => tr.append(element("td", index === 3 ? "value-cpu" : index === 4 ? "value-metal" : "", text)));
    body.append(tr);
  });
}

function provenanceCard(title, entries, className = "") {
  const card = element("section", `surface provenance-card ${className}`.trim());
  card.append(element("p", "eyebrow", "Bound evidence"), element("h2", "", title));
  const list = element("dl", "provenance-list");
  entries.forEach(([term, value]) => appendDefinition(list, term, value));
  card.append(list);
  return card;
}

function renderProvenance(run) {
  const layout = clear(document.getElementById("provenance-layout"));
  layout.append(provenanceCard("Revision", [
    ["Measurement commit", run.revision.git_commit],
    ["Worktree", run.revision.git_dirty ? "dirty" : "clean"],
    ["Captured", dateTime(run.captured_at)],
    ["Target", run.revision.target],
    ["Optimization", run.revision.optimization],
    ["SIMD pack", String(run.revision.simd_pack_width)],
  ]));
  layout.append(provenanceCard("Machine", [
    ["Host", run.machine.name],
    ["Model", run.machine.model],
    ["Chip", run.machine.chip],
    ["Logical CPUs", String(run.machine.logical_cpu_count)],
    ["Memory", run.machine.physical_memory],
    ["GPU", run.machine.gpu.name],
    ["GPU cores", run.machine.gpu.gpu_cores],
  ]));
  layout.append(provenanceCard("Toolchain", [
    ["Zig", run.toolchain.zig_version],
    ["Rust", run.toolchain.rust_version],
    ["Rust channel", run.toolchain.rust_toolchain],
    ["macOS SDK", run.toolchain.macos_sdk_version],
    ["OS", `${run.machine.platform.system} ${run.machine.platform.os_product_version}`],
    ["OS build", run.machine.platform.os_build_version],
  ]));
  layout.append(provenanceCard("Method", [
    ["Protocol", run.settings.proof_protocol],
    ["Metal runtime", run.settings.metal_runtime],
    ["Execution", run.settings.execution],
    ["Warmups / lane", String(run.settings.warmups_per_lane)],
    ["Samples / lane", String(run.settings.samples_per_lane)],
    ["Cooldown", `${run.settings.cooldown_seconds}s`],
  ]));
  layout.append(provenanceCard("Publication evidence", [
    ["Report", run.source.path],
    ["Report SHA-256", run.source.sha256],
    ["Report bytes", run.source.bytes.toLocaleString()],
    ["History index", state.catalog.source.index_path],
    ["Index SHA-256", state.catalog.source.index_sha256],
    ["Catalog schema", state.catalog.schema],
  ], "evidence"));
  const exclusions = state.catalog.excluded_runs;
  layout.append(provenanceCard("Retained legacy runs", exclusions.length ? exclusions.flatMap((item) => [
    [`${compactDate(item.captured_at)} · ${shortCommit(item.git_commit || "unknown")}`, item.reasons.join("; ")],
  ]) : [["Status", "none"]], "exclusions"));
}

function renderAll() {
  const run = selectedRun();
  state.runId = run.id;
  if (!run.rows.some((row) => row.id === state.workloadId)) state.workloadId = run.rows[0].id;
  renderRunOptions();
  renderRunStrip(run);
  renderKpis(run);
  renderComparison(run);
  renderMetricTabs();
  renderWorkloadTable(run);
  renderWorkloadDetail(run);
  renderHistory();
  renderProvenance(run);
  document.getElementById("catalog-status").textContent = `${state.catalog.runs.length} formal runs · ${state.catalog.excluded_runs.length} retained legacy · ${state.catalog.source.index_sha256.slice(0, 10)}`;
}

function activateTab(name, focus = false) {
  if (!document.getElementById(`${name}-tab`)) return;
  state.tab = name;
  document.querySelectorAll(".tab").forEach((tab) => {
    const active = tab.dataset.tab === name;
    tab.classList.toggle("is-active", active);
    tab.ariaSelected = active ? "true" : "false";
    if (active && focus) tab.focus();
  });
  document.querySelectorAll(".tab-panel").forEach((panel) => {
    const active = panel.id === `${name}-panel`;
    panel.hidden = !active;
    panel.classList.toggle("is-active", active);
  });
  history.replaceState(null, "", `#${name}`);
}

function bindEvents() {
  document.getElementById("run-select").addEventListener("change", (event) => {
    state.runId = event.target.value;
    state.workloadId = null;
    renderAll();
  });
  document.getElementById("commit-copy").addEventListener("click", async () => {
    const commit = selectedRun().revision.git_commit;
    try {
      await navigator.clipboard.writeText(commit);
      showToast("Measurement commit copied");
    } catch (_) {
      showToast(commit);
    }
  });
  document.querySelector(".tab-bar").addEventListener("click", (event) => {
    const tab = event.target.closest("[data-tab]");
    if (tab) activateTab(tab.dataset.tab);
  });
  document.querySelector(".tab-bar").addEventListener("keydown", (event) => {
    if (!['ArrowLeft', 'ArrowRight', 'Home', 'End'].includes(event.key)) return;
    const tabs = [...document.querySelectorAll(".tab")];
    const current = tabs.findIndex((tab) => tab.dataset.tab === state.tab);
    let target = current;
    if (event.key === "ArrowLeft") target = (current - 1 + tabs.length) % tabs.length;
    if (event.key === "ArrowRight") target = (current + 1) % tabs.length;
    if (event.key === "Home") target = 0;
    if (event.key === "End") target = tabs.length - 1;
    event.preventDefault();
    activateTab(tabs[target].dataset.tab, true);
  });
  document.getElementById("metric-tabs").addEventListener("click", (event) => {
    const tab = event.target.closest("[data-metric]");
    if (!tab) return;
    state.metric = tab.dataset.metric;
    renderMetricTabs();
    renderWorkloadTable(selectedRun());
  });
  document.querySelector("#workload-table tbody").addEventListener("click", (event) => {
    const row = event.target.closest("[data-workload]");
    if (!row) return;
    state.workloadId = row.dataset.workload;
    renderWorkloadTable(selectedRun());
    renderWorkloadDetail(selectedRun());
  });
  document.querySelector("#workload-table tbody").addEventListener("keydown", (event) => {
    if (event.key === "Enter" || event.key === " ") event.target.click();
  });
  document.querySelector("#history-table tbody").addEventListener("click", (event) => {
    const row = event.target.closest("[data-run]");
    if (!row) return;
    state.runId = row.dataset.run;
    state.workloadId = null;
    renderAll();
  });
}

async function start() {
  bindEvents();
  const requestedTab = location.hash.slice(1);
  if (requestedTab) activateTab(requestedTab);
  try {
    const response = await fetch("data/catalog.json", { cache: "no-store" });
    if (!response.ok) throw new Error(`HTTP ${response.status}`);
    const catalog = await response.json();
    if (catalog.schema !== "stwo_benchmark_catalog_v1" || !catalog.runs?.length) {
      throw new Error("catalog contract is unsupported");
    }
    state.catalog = catalog;
    state.runId = catalog.latest_run_id;
    renderAll();
  } catch (error) {
    document.querySelectorAll(".tab-panel").forEach((panel) => { panel.hidden = true; });
    document.getElementById("load-error").hidden = false;
    document.getElementById("load-error-detail").textContent = String(error.message || error);
    document.getElementById("evidence-state").textContent = "unavailable";
  }
}

start();
