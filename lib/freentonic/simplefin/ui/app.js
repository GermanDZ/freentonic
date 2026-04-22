(() => {
  const $ = (sel) => document.querySelector(sel);
  const profilesEl = $("#profiles");
  const newPanel = $("#new-profile-panel");
  const credPanel = $("#credentials-panel");
  const tokenPanel = $("#setup-token-panel");
  const tokenValue = $("#setup-token-value");

  let workflowsCache = null;

  async function api(path, opts = {}) {
    const res = await fetch(path, {
      credentials: "same-origin",
      headers: Object.assign(
        { "Content-Type": "application/json" },
        opts.headers || {}
      ),
      method: opts.method || "GET",
      body: opts.body ? JSON.stringify(opts.body) : undefined,
    });
    if (res.status === 401) {
      window.location.href = "/admin/login";
      return null;
    }
    if (!res.ok) {
      const txt = await res.text();
      throw new Error(`${res.status} ${txt}`);
    }
    return res.json();
  }

  function el(tag, attrs = {}, ...children) {
    const node = document.createElement(tag);
    Object.entries(attrs).forEach(([k, v]) => {
      if (k === "class") node.className = v;
      else if (k === "text") node.textContent = v;
      else if (k.startsWith("on")) node.addEventListener(k.slice(2), v);
      else if (v !== undefined && v !== null) node.setAttribute(k, v);
    });
    for (const child of children) {
      if (child == null) continue;
      if (typeof child === "string") node.appendChild(document.createTextNode(child));
      else node.appendChild(child);
    }
    return node;
  }

  function renderProfiles(profiles) {
    profilesEl.innerHTML = "";
    if (!profiles.length) {
      profilesEl.appendChild(el("p", { class: "profile-meta" }, "No profiles yet. Click “+ New profile” above."));
      return;
    }
    for (const p of profiles) {
      const left = el("div", {},
        el("div", {},
          el("strong", { text: p.display_name || p.profile_key }),
          el("span", { class: `state-pill state-${p.state}` }, p.state.replaceAll("_", " "))
        ),
        el("div", { class: "profile-meta" },
          el("span", {}, p.workflow),
          el("span", {}, `lookback ${p.lookback_days}d`),
          p.sync_interval_seconds ? el("span", {}, `auto-sync every ${formatInterval(p.sync_interval_seconds)}`) : null,
          p.last_synced_at ? el("span", {}, `last synced ${new Date(p.last_synced_at).toLocaleString()}`) : null,
          p.last_error ? el("span", { style: "color:#b03030" }, p.last_error) : null,
          p.access_url_configured ? el("span", {}, "access URL ✓") : el("span", {}, "access URL pending"),
          p.credential_names.length ? el("span", {}, `${p.credential_names.length} secret${p.credential_names.length > 1 ? "s" : ""}`) : null,
          p.hidden_accounts && p.hidden_accounts.length ? el("span", {}, `${p.hidden_accounts.length} hidden account${p.hidden_accounts.length > 1 ? "s" : ""}`) : null
        )
      );

      const actions = el("div", { class: "profile-actions" },
        el("button", { onclick: () => openCredentials(p) }, "Credentials"),
        el("button", { onclick: () => mintSetupToken(p.profile_key) }, "Setup token"),
        el("button", { onclick: () => triggerSync(p.profile_key, false) }, "Sync now"),
        p.state === "needs_reauth"
          ? el("button", { class: "primary", onclick: () => triggerSync(p.profile_key, true) }, "Re-authenticate (VNC)")
          : null,
        el("button", { onclick: () => toggleRuns(p.profile_key) }, "Runs"),
        el("button", { onclick: () => rotateAccessUrl(p.profile_key) }, "Rotate URL"),
        el("button", { onclick: () => deleteProfile(p.profile_key) }, "Delete")
      );

      const runsPanel = el("div", {
        class: "runs-panel hidden",
        "data-runs-for": p.profile_key
      });

      profilesEl.appendChild(el("div", { class: "profile-row" }, left, actions));
      profilesEl.appendChild(runsPanel);
    }
  }

  async function toggleRuns(key) {
    const panel = document.querySelector(`[data-runs-for="${CSS.escape(key)}"]`);
    if (!panel) return;
    if (!panel.classList.contains("hidden")) {
      panel.classList.add("hidden");
      return;
    }
    panel.innerHTML = "Loading…";
    try {
      const data = await api(`/admin/api/profiles/${encodeURIComponent(key)}/runs`);
      panel.innerHTML = "";
      if (!data.runs.length) {
        panel.appendChild(el("p", { class: "profile-meta" }, "No runs yet."));
      } else {
        for (const run of data.runs) {
          panel.appendChild(renderRun(key, run));
        }
      }
      panel.classList.remove("hidden");
    } catch (e) {
      panel.innerHTML = `<p class="err">Failed to load runs: ${e.message}</p>`;
    }
  }

  function renderRun(key, run) {
    const status = run.outcome || (run.exit_code === 0 ? "ready" : "error");
    const row = el("div", { class: "run-row" },
      el("div", { class: "run-row-head" },
        el("span", { class: `state-pill state-${status}` }, status.replaceAll("_", " ")),
        el("span", {}, run.run_id),
        el("span", { class: "profile-meta" }, run.started_at ? new Date(run.started_at).toLocaleString() : ""),
        run.duration_ms != null ? el("span", { class: "profile-meta" }, `${run.duration_ms}ms`) : null,
        el("button", { onclick: (e) => toggleRunLog(key, run.run_id, e.target.closest(".run-row")) }, "Log")
      ),
      run.message ? el("div", { class: "profile-meta" }, run.message) : null,
      el("pre", { class: "run-log hidden" }, "")
    );
    return row;
  }

  async function toggleRunLog(key, runId, rowEl) {
    const pre = rowEl.querySelector(".run-log");
    if (!pre.classList.contains("hidden")) {
      pre.classList.add("hidden");
      return;
    }
    pre.textContent = "Loading…";
    pre.classList.remove("hidden");
    try {
      const data = await api(`/admin/api/profiles/${encodeURIComponent(key)}/runs/${encodeURIComponent(runId)}/log`);
      pre.textContent = data.log || "(empty log)";
      if (data.truncated) {
        pre.textContent = "…(earlier output truncated)\n" + pre.textContent;
      }
    } catch (e) {
      pre.textContent = `Failed to load log: ${e.message}`;
    }
  }

  function formatInterval(seconds) {
    if (seconds < 3600) return `${Math.round(seconds / 60)}m`;
    if (seconds < 86400) return `${(seconds / 3600).toFixed(1).replace(/\.0$/, "")}h`;
    return `${Math.round(seconds / 86400)}d`;
  }

  let liveLogTimer = null;
  let liveLogRunId = null;
  let liveLogProfile = null;

  async function refresh() {
    try {
      const data = await api("/admin/api/status");
      if (!data) return;
      renderProfiles(data.profiles);
      renderActiveJob(data.active_job);
    } catch (e) {
      console.error(e);
    }
  }

  function renderActiveJob(job) {
    const existing = document.getElementById("active-job-banner");
    if (!job) {
      if (existing) existing.remove();
      stopLiveLog();
      return;
    }

    const startedAt = job.started_at ? new Date(job.started_at).toLocaleTimeString() : "—";
    const banner = el("section", { id: "active-job-banner", class: "panel" },
      el("h2", {}, `Running: ${job.profile_key}`),
      el("div", { class: "profile-meta" },
        el("span", {}, `run ${job.run_id}`),
        el("span", {}, `started ${startedAt}`),
        el("span", {}, job.headed ? "headed (visible in VNC)" : "headless"),
        job.trigger ? el("span", {}, `trigger: ${job.trigger}`) : null
      ),
      el("div", { class: "row" },
        job.vnc_url
          ? el("a", { href: job.vnc_url, target: "_blank", rel: "noreferrer", class: "button-link" }, "Watch live (VNC)")
          : null,
        el("button", { onclick: () => toggleLiveLog(job.profile_key, job.run_id) }, "Live log")
      ),
      el("pre", { id: "active-job-log", class: "run-log hidden" }, "")
    );

    if (existing) {
      existing.replaceWith(banner);
    } else {
      document.querySelector("main").prepend(banner);
    }
  }

  async function toggleLiveLog(profileKey, runId) {
    const pre = document.getElementById("active-job-log");
    if (!pre) return;
    if (liveLogTimer && liveLogRunId === runId) {
      stopLiveLog();
      return;
    }
    liveLogProfile = profileKey;
    liveLogRunId = runId;
    pre.classList.remove("hidden");
    pre.textContent = "Loading…";
    await fetchLiveLog();
    liveLogTimer = setInterval(fetchLiveLog, 2000);
  }

  async function fetchLiveLog() {
    if (!liveLogRunId || !liveLogProfile) return;
    const pre = document.getElementById("active-job-log");
    if (!pre) { stopLiveLog(); return; }
    try {
      const data = await api(`/admin/api/profiles/${encodeURIComponent(liveLogProfile)}/runs/${encodeURIComponent(liveLogRunId)}/log`);
      const prefix = data.truncated ? "…(earlier output truncated)\n" : "";
      pre.textContent = prefix + (data.log || "(log is empty so far)");
      pre.scrollTop = pre.scrollHeight;
    } catch (e) {
      pre.textContent = `Log fetch failed: ${e.message}`;
    }
  }

  function stopLiveLog() {
    if (liveLogTimer) {
      clearInterval(liveLogTimer);
      liveLogTimer = null;
    }
    liveLogRunId = null;
    liveLogProfile = null;
  }

  async function loadWorkflows() {
    if (workflowsCache) return workflowsCache;
    const data = await api("/admin/api/workflows");
    workflowsCache = data.workflows;
    return workflowsCache;
  }

  async function openNewProfile() {
    const sel = $("#new-profile-form [name=workflow]");
    sel.innerHTML = "";
    const wfs = await loadWorkflows();
    for (const wf of wfs) {
      sel.appendChild(el("option", { value: wf.workflow }, wf.workflow));
    }
    newPanel.classList.remove("hidden");
  }

  $("#new-profile-btn").addEventListener("click", openNewProfile);
  $("#new-profile-cancel").addEventListener("click", () => newPanel.classList.add("hidden"));

  $("#new-profile-form").addEventListener("submit", async (e) => {
    e.preventDefault();
    const form = new FormData(e.target);
    try {
      const interval = parseInt(form.get("sync_interval_seconds"), 10);
      await api("/admin/api/profiles", {
        method: "POST",
        body: {
          profile_key: form.get("profile_key"),
          display_name: form.get("display_name"),
          workflow: form.get("workflow"),
          lookback_days: parseInt(form.get("lookback_days"), 10) || 30,
          sync_interval_seconds: Number.isFinite(interval) && interval > 0 ? interval : null,
        },
      });
      newPanel.classList.add("hidden");
      e.target.reset();
      refresh();
    } catch (err) {
      alert(`Create failed: ${err.message}`);
    }
  });

  async function openCredentials(profile) {
    const wfs = await loadWorkflows();
    const wf = wfs.find((w) => w.workflow === profile.workflow);
    const secrets = wf ? wf.secrets : [];
    $("#cred-profile").textContent = profile.profile_key;
    const form = $("#credentials-form");
    form.innerHTML = "";
    if (!secrets.length) {
      form.appendChild(el("p", {}, "This workflow does not declare any secrets."));
    } else {
      for (const name of secrets) {
        form.appendChild(el("label", {},
          name,
          el("input", { name, type: "password", autocomplete: "off" })
        ));
      }
      form.appendChild(el("div", { class: "row" },
        el("button", { type: "submit", class: "primary" }, "Save"),
        el("button", { type: "button", onclick: () => credPanel.classList.add("hidden") }, "Cancel")
      ));
      form.onsubmit = async (e) => {
        e.preventDefault();
        const payload = {};
        for (const name of secrets) {
          const val = form.elements[name].value;
          if (val) payload[name] = val;
        }
        try {
          await api(`/admin/api/profiles/${encodeURIComponent(profile.profile_key)}/credentials`, {
            method: "POST",
            body: { secrets: payload },
          });
          credPanel.classList.add("hidden");
          refresh();
        } catch (err) {
          alert(`Save failed: ${err.message}`);
        }
      };
    }
    credPanel.classList.remove("hidden");
  }

  async function mintSetupToken(key) {
    try {
      const data = await api(`/admin/api/profiles/${encodeURIComponent(key)}/setup-token`, { method: "POST" });
      tokenValue.value = data.setup_token;
      tokenPanel.classList.remove("hidden");
    } catch (e) { alert(e.message); }
  }

  $("#copy-setup-token").addEventListener("click", () => {
    tokenValue.select();
    document.execCommand("copy");
  });

  async function triggerSync(key, headed) {
    try {
      const data = await api(`/admin/api/profiles/${encodeURIComponent(key)}/sync`, {
        method: "POST",
        body: { headed },
      });
      if (headed && data && data.vnc_password) {
        showVncInstructions(data);
      }
      refresh();
    } catch (e) { alert(e.message); }
  }

  function showVncInstructions(data) {
    // Drop a transient card above the profiles list with the one-shot VNC
    // password + a direct noVNC link. Persists until the operator dismisses
    // it — a polling refresh must not wipe it out.
    const existing = document.getElementById("vnc-banner");
    if (existing) existing.remove();
    const banner = el("section", { id: "vnc-banner", class: "panel" },
      el("h2", {}, `Re-authenticate ${data.profile_key} via VNC`),
      el("p", {},
        "A headed sync has been queued. Open noVNC in a new tab and paste this one-shot password — it is discarded as soon as the sync finishes:"
      ),
      el("pre", { class: "vnc-password" }, data.vnc_password),
      data.vnc_url
        ? el("p", {},
            el("a", { href: data.vnc_url, target: "_blank", rel: "noreferrer" }, "Open noVNC"),
            " (autoconnect uses the password above)"
          )
        : null,
      el("button", { onclick: () => banner.remove() }, "Dismiss")
    );
    document.querySelector("main").prepend(banner);
  }

  async function rotateAccessUrl(key) {
    if (!confirm(`Rotate access URL for ${key}? The user will need to re-link in Actual.`)) return;
    try {
      await api(`/admin/api/profiles/${encodeURIComponent(key)}/rotate-access-url`, { method: "POST" });
      refresh();
    } catch (e) { alert(e.message); }
  }

  async function deleteProfile(key) {
    if (!confirm(`Delete profile ${key}? This cannot be undone.`)) return;
    try {
      await api(`/admin/api/profiles/${encodeURIComponent(key)}`, { method: "DELETE" });
      refresh();
    } catch (e) { alert(e.message); }
  }

  refresh();
  setInterval(refresh, 2000);
})();
