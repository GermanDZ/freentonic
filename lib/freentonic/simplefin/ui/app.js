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
          p.last_synced_at ? el("span", {}, `last synced ${new Date(p.last_synced_at).toLocaleString()}`) : null,
          p.last_error ? el("span", { style: "color:#b03030" }, p.last_error) : null,
          p.access_url_configured ? el("span", {}, "access URL ✓") : el("span", {}, "access URL pending"),
          p.credential_names.length ? el("span", {}, `${p.credential_names.length} secret${p.credential_names.length > 1 ? "s" : ""}`) : null
        )
      );

      const actions = el("div", { class: "profile-actions" },
        el("button", { onclick: () => openCredentials(p) }, "Credentials"),
        el("button", { onclick: () => mintSetupToken(p.profile_key) }, "Setup token"),
        el("button", { onclick: () => triggerSync(p.profile_key, false) }, "Sync now"),
        p.state === "needs_reauth"
          ? el("button", { class: "primary", onclick: () => triggerSync(p.profile_key, true) }, "Re-authenticate (VNC)")
          : null,
        el("button", { onclick: () => rotateAccessUrl(p.profile_key) }, "Rotate URL"),
        el("button", { onclick: () => deleteProfile(p.profile_key) }, "Delete")
      );

      profilesEl.appendChild(el("div", { class: "profile-row" }, left, actions));
    }
  }

  async function refresh() {
    try {
      const data = await api("/admin/api/status");
      if (data) renderProfiles(data.profiles);
    } catch (e) {
      console.error(e);
    }
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
      await api("/admin/api/profiles", {
        method: "POST",
        body: {
          profile_key: form.get("profile_key"),
          display_name: form.get("display_name"),
          workflow: form.get("workflow"),
          lookback_days: parseInt(form.get("lookback_days"), 10) || 30,
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
      await api(`/admin/api/profiles/${encodeURIComponent(key)}/sync`, {
        method: "POST",
        body: { headed },
      });
      refresh();
    } catch (e) { alert(e.message); }
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
