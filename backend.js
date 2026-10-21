/* Paris Cast - ligacao do site com o Supabase.
   Faz o site enxergar um "banco de documentos" (doc/collection), o usuario e o envio de audios,
   do mesmo jeito que funcionava dentro do Claude. */
(function () {
  'use strict';
  var cfg = window.PARIS_CONFIG || {};
  var sb = (window.supabase && cfg.url && cfg.anonKey && cfg.url.indexOf('COLE') < 0)
    ? window.supabase.createClient(cfg.url, cfg.anonKey, { auth: { persistSession: true, autoRefreshToken: true, detectSessionInUrl: false } })
    : null;
  var who = { level: 2, owner: false, admin: false };
  var session = null, initP = null;
  var subs = [];
  var clone = function (x) { return x === undefined ? x : JSON.parse(JSON.stringify(x)); };
  var last = function (p) { return p.split('/').pop(); };
  var colOf = function (p) { return p.replace(/\/[^/]+$/, ''); };
  var denied = function (e) { var err = new Error((e && e.message) || 'negado'); err.code = 'invalid_argument'; err.raw = e; return err; };

  function init() {
    if (initP) return initP;
    initP = (async function () {
      if (!sb) return null;
      try {
        var g = await sb.auth.getSession();
        session = g && g.data && g.data.session;
        if (!session) {
          var r = await sb.auth.signInAnonymously();
          if (r.error) { console.warn('login anonimo', r.error); return null; }
          session = r.data.session;
        }
        var w = await sb.rpc('whoami');
        if (w && w.data) who = w.data;
        startRealtime();
        return session.user;
      } catch (e) { console.warn(e); return null; }
    })();
    return initP;
  }

  /* ---------- tempo real ---------- */
  var chan = null, wasUp = false;
  function startRealtime() {
    try {
      chan = sb.channel('docs-all')
        .on('postgres_changes', { event: '*', schema: 'public', table: 'docs' }, function (p) {
          if (p.eventType === 'DELETE') { var o = p.old || {}; if (o.path) applyDelete(o.path); }
          else if (p.new && p.new.path) applyRow(p.new);
        })
        .subscribe(function (status) {
          if (status === 'SUBSCRIBED') { if (wasUp) resyncAll(); wasUp = true; }
        });
    } catch (e) { console.warn('tempo real', e); }
  }
  function snapDoc(path, row) { return { id: last(path), exists: !!row, data: function () { return row ? clone(row.data) : undefined; }, metadata: {} }; }
  function snapCol(sub) {
    var docs = Array.from(sub.cache.values()).sort(function (a, b) { return a.path < b.path ? -1 : 1; }).map(function (r) { return snapDoc(r.path, r); });
    return { docs: docs, size: docs.length, empty: !docs.length, metadata: {} };
  }
  function notify(sub) { try { sub.next(sub.kind === 'doc' ? snapDoc(sub.path, sub.cache.get(sub.path)) : snapCol(sub)); } catch (e) { console.warn(e); } }
  function applyRow(row) {
    var col = row.col || colOf(row.path);
    subs.forEach(function (s) {
      if (s.kind === 'doc' ? s.path === row.path : s.path === col) {
        if (!s.ready) { s.buf.push({ row: row }); return; }
        s.cache.set(row.path, { path: row.path, data: row.data }); notify(s);
      }
    });
  }
  function applyDelete(path) {
    var col = colOf(path);
    subs.forEach(function (s) {
      if (s.kind === 'doc' ? s.path === path : s.path === col) {
        if (!s.ready) { s.buf.push({ del: path }); return; }
        if (s.cache.delete(path)) notify(s);
      }
    });
  }
  async function fetchCol(path) {
    var out = [], from = 0, step = 1000;
    for (;;) {
      var r = await sb.from('docs').select('path,data').eq('col', path).range(from, from + step - 1);
      if (r.error) throw r.error;
      out = out.concat(r.data || []);
      if (!r.data || r.data.length < step) break;
      from += step;
    }
    return out;
  }
  async function fetchDoc(path) {
    var r = await sb.from('docs').select('path,data').eq('path', path).maybeSingle();
    if (r.error) throw r.error;
    return r.data || null;
  }
  async function load(sub) {
    var rows = sub.kind === 'doc' ? [await fetchDoc(sub.path)].filter(Boolean) : await fetchCol(sub.path);
    sub.cache = new Map(rows.map(function (r) { return [r.path, r]; }));
    sub.ready = true;
    var b = sub.buf; sub.buf = [];
    b.forEach(function (e) { if (e.row) sub.cache.set(e.row.path, { path: e.row.path, data: e.row.data }); else sub.cache.delete(e.del); });
    notify(sub);
  }
  function resyncAll() { subs.forEach(function (s) { load(s).catch(function (e) { console.warn(e); }); }); }
  function subscribe(kind, path, next) {
    var sub = { kind: kind, path: path, next: next, cache: new Map(), buf: [], ready: false };
    subs.push(sub);
    init().then(function () { return load(sub); }).catch(function (e) { console.warn(path, e); });
    return function () { subs = subs.filter(function (x) { return x !== sub; }); };
  }

  /* ---------- banco de documentos ---------- */
  var rid = function () { var a = new Uint8Array(10); crypto.getRandomValues(a); return Array.from(a, function (b) { return (b % 36).toString(36); }).join(''); };
  function docRef(path) {
    return {
      id: last(path), path: path,
      get: async function () { await init(); return snapDoc(path, await fetchDoc(path)); },
      set: async function (d) {
        await init();
        var row = { path: path, data: clone(d) };
        var r = await sb.from('docs').upsert(row, { onConflict: 'path' });
        if (r.error) throw denied(r.error);
        applyRow({ path: path, col: colOf(path), data: clone(d) });
      },
      update: async function (d) {
        await init();
        var r = await sb.rpc('doc_merge', { p: path, d: clone(d) });
        if (r.error) throw denied(r.error);
        var row = await fetchDoc(path);
        if (row) applyRow({ path: path, col: colOf(path), data: row.data });
      },
      delete: async function () {
        await init();
        var r = await sb.from('docs').delete().eq('path', path);
        if (r.error) throw denied(r.error);
        applyDelete(path);
      },
      collection: function (p) { return colRef(path + '/' + p); },
      onSnapshot: function (next) { return subscribe('doc', path, next); }
    };
  }
  function colRef(path) {
    return {
      path: path,
      doc: function (id) { return docRef(path + '/' + (id || rid())); },
      add: async function (d) { var r = this.doc(); await r.set(d); return r; },
      get: async function () { await init(); var rows = await fetchCol(path); var s = { kind: 'col', cache: new Map(rows.map(function (r) { return [r.path, r]; })) }; return snapCol(s); },
      onSnapshot: function (next) { return subscribe('col', path, next); }
    };
  }
  var db = { doc: docRef, collection: colRef };

  /* ---------- usuario ---------- */
  function avatarOf(id) {
    var h = 0; for (var i = 0; i < id.length; i++) h = (h * 31 + id.charCodeAt(i)) % 360;
    var svg = '<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 4 4"><rect width="4" height="4" fill="hsl(' + h + ',32%,50%)"/></svg>';
    return 'data:image/svg+xml,' + encodeURIComponent(svg);
  }
  var user = {
    isOwner: async function () { await init(); return !!who.owner; },
    canEdit: async function () { await init(); return !!who.admin; },
    can: async function () { return true; },
    id: async function () { await init(); return session ? session.user.id : null; },
    me: async function () {
      await init();
      var u = session && session.user, md = (u && u.user_metadata) || {};
      var name = md.name || (u && u.email ? u.email.split('@')[0] : '');
      return { id: u ? u.id : '', name: name, avatarUrl: avatarOf(u ? u.id : 'x'), color: '#a66', email: (u && u.email) || null };
    },
    profiles: async function (ids) {
      var o = {}, me = session ? session.user.id : null;
      [].concat(ids || []).forEach(function (i) { o[i] = { id: i, name: '', avatarUrl: avatarOf(i), color: '#a66', isMe: i === me }; });
      return o;
    },
    search: async function () { return []; }
  };

  /* ---------- audios ---------- */
  var assets = {
    upload: async function (file, opts) {
      await init();
      var ext = (String(file.name || '').match(/\.([A-Za-z0-9]+)$/) || [, 'm4a'])[1].toLowerCase();
      var id = (crypto.randomUUID ? crypto.randomUUID() : rid() + rid()) + '.' + ext;
      var r = await sb.storage.from('audio').upload(id, file, { contentType: (opts && opts.type) || file.type || 'video/mp4', upsert: false });
      if (r.error) { var e = new Error(r.error.message); e.code = (r.error.statusCode == 413 || /size|large|exceed/i.test(r.error.message || '')) ? 'too_large' : 'upload_failed'; throw e; }
      return { id: id, url: window.__assetUrl(id), sizeBytes: file.size, contentType: (opts && opts.type) || file.type };
    },
    list: async function () { return { assets: [], usage: {} }; },
    delete: async function (id) { await init(); await sb.storage.from('audio').remove([id]); return { deleted: true }; }
  };
  window.__assetUrl = function (id) { return sb ? sb.storage.from('audio').getPublicUrl(id).data.publicUrl : '/_blob/' + id; };
  window.__setAdmin = async function (uid, on) { await init(); var r = await sb.rpc('set_admin', { target: uid, on_: !!on }); if (r.error) throw r.error; };

  window.claude = {
    use: async function (name) {
      if (name === 'sample' || !sb) return null;
      var u = await init();
      if (!u) return null;
      return ({ db: db, user: user, assets: assets })[name] || null;
    }
  };

  /* ---------- acesso do dono (abra o site com #dono no fim do endereco) ---------- */
  function ownerPanel() {
    if (!sb) return;
    var isEmail = false;
    init().then(function () { isEmail = !!(session && session.user && session.user.email); if (isEmail || location.hash === '#dono') mount(); });
    window.addEventListener('hashchange', function () { if (location.hash === '#dono') mount(); });
    function mount() {
      if (document.getElementById('ownerBtn')) return;
      var b = document.createElement('button');
      b.id = 'ownerBtn'; b.type = 'button';
      b.textContent = isEmail ? (who.owner ? 'Dono · sair' : 'Conta · sair') : 'Acesso do dono';
      b.style.cssText = 'position:fixed;right:12px;bottom:12px;z-index:60;padding:7px 12px;border-radius:999px;border:1px solid var(--line,#6b5646);background:var(--panel,#2a1e17);color:var(--ink-2,#cbb8a4);font:600 12px var(--f-body,system-ui);cursor:pointer;opacity:.9';
      b.onclick = function () { if (isEmail) { sb.auth.signOut().then(function () { location.hash = ''; location.reload(); }); } else open(); };
      document.body.appendChild(b);
    }
    function open() {
      var w = document.createElement('div');
      w.style.cssText = 'position:fixed;inset:0;z-index:80;display:grid;place-items:center;background:rgba(10,6,4,.7);padding:16px';
      w.innerHTML = '<form style="width:min(380px,100%);display:grid;gap:12px;padding:22px;border-radius:14px;background:var(--panel,#2a1e17);color:var(--ink,#f3e6d6);border:1px solid var(--line,#6b5646);font:15px var(--f-body,system-ui)">' +
        '<h2 style="margin:0;font:600 24px var(--f-display,serif)">Acesso do dono</h2>' +
        '<p style="margin:0;color:var(--ink-2,#cbb8a4);font-size:13px">Primeira vez: escolha e-mail e senha e toque em <b>Criar conta de dono</b>. Depois use <b>Entrar</b>.</p>' +
        '<input id="oe" type="email" placeholder="E-mail" autocomplete="username" required style="padding:11px;border-radius:9px;border:1px solid var(--line,#6b5646);background:var(--ground,#1a120d);color:inherit">' +
        '<input id="op" type="password" placeholder="Senha (6 ou mais caracteres)" autocomplete="current-password" required minlength="6" style="padding:11px;border-radius:9px;border:1px solid var(--line,#6b5646);background:var(--ground,#1a120d);color:inherit">' +
        '<div id="om" role="status" style="min-height:18px;font-size:13px;color:#e8a07a"></div>' +
        '<div style="display:flex;gap:8px;flex-wrap:wrap"><button id="oin" class="btn pri" type="submit">Entrar</button><button id="ocr" class="btn" type="button">Criar conta de dono</button><button id="oc" class="btn ghost" type="button">Fechar</button></div></form>';
      document.body.appendChild(w);
      var f = w.querySelector('form'), m = w.querySelector('#om');
      var say = function (t) { m.textContent = t; };
      w.querySelector('#oc').onclick = function () { w.remove(); };
      f.onsubmit = async function (e) {
        e.preventDefault(); say('Entrando…');
        var r = await sb.auth.signInWithPassword({ email: f.oe.value.trim(), password: f.op.value });
        if (r.error) { say('Não deu certo: ' + r.error.message); return; }
        var c = await sb.rpc('claim_owner');
        location.hash = ''; location.reload();
      };
      w.querySelector('#ocr').onclick = async function () {
        say('Criando…');
        var r = await sb.auth.signUp({ email: f.oe.value.trim(), password: f.op.value });
        if (r.error) { say('Não deu certo: ' + r.error.message); return; }
        if (!r.data.session) { say('Conta criada. Confirme o e-mail que chegou e depois toque em Entrar. (Dica: desligue "Confirm email" no Supabase.)'); return; }
        var c = await sb.rpc('claim_owner');
        say(c.data ? 'Pronto! Você é o dono.' : 'Conta criada, mas já existe um dono.');
        setTimeout(function () { location.hash = ''; location.reload(); }, 900);
      };
    }
  }
  if (document.readyState === 'loading') document.addEventListener('DOMContentLoaded', ownerPanel); else ownerPanel();
})();
