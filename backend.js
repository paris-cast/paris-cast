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
  /* funcoes do banco (curtidas, enquete, ouvindo agora, limites) */
  window.__rpc = sb ? async function (name, args) {
    await init();
    var r = await sb.rpc(name, args || {});
    if (r.error) { var e = new Error(r.error.message); e.code = r.error.code; throw e; }
    return r.data;
  } : null;
  window.__setAdmin = async function (uid, on) { await init(); var r = await sb.rpc('set_admin', { target: uid, on_: !!on }); if (r.error) throw r.error; };

  /* ---------- Radialistas: senha para dono e equipe ---------- */
  var OWNER_PHONE = '38999232546';
  var mailOf = function (tel) { return String(tel).replace(/\D/g, '') + '@radialistas.pariscast.app'; };
  window.__staff = sb ? {
    ownerPhone: OWNER_PHONE,
    isAnon: function () { var u = session && session.user; return !u || !!u.is_anonymous; },
    /* transforma esta conta (anonima) em conta com telefone + senha, mantendo tudo o que ja e dela */
    create: async function (tel, password) {
      await init();
      if (!session) throw new Error('Sem conexão com o servidor.');
      if (!session.user.is_anonymous) throw new Error('Esta conta já tem senha.');
      var r = await sb.auth.updateUser({ email: mailOf(tel), password: password });
      if (r.error) throw r.error;
      var s2 = await sb.auth.refreshSession();
      if (s2.error || !s2.data || !s2.data.session) throw new Error('Não consegui ativar a conta. Confira se "Confirm email" está desligado no Supabase.');
      session = s2.data.session;
      if (session.user.is_anonymous) throw new Error('Não consegui ativar a conta. Confira se "Confirm email" está desligado no Supabase (ativação).');
      var owner = false;
      if (String(tel).replace(/\D/g, '') === OWNER_PHONE) { var c = await sb.rpc('claim_owner'); owner = !!c.data; }
      return { owner: owner };
    },
    login: async function (tel, password) {
      await init();
      var r = await sb.auth.signInWithPassword({ email: mailOf(tel), password: password });
      if (r.error) throw r.error;
      session = r.data.session;
      return true;
    },
    /* o dono cria a conta de um radialista (telefone + senha escolhidos por ele) sem sair da propria conta */
    createAccount: async function (tel, password) {
      var c = window.supabase.createClient(cfg.url, cfg.anonKey, { auth: { persistSession: false, autoRefreshToken: false, detectSessionInUrl: false, storageKey: 'pc-tmp-' + Date.now() } });
      var r = await c.auth.signUp({ email: mailOf(tel), password: password });
      if (r.error) throw r.error;
      var u = r.data && r.data.user;
      if (!u || !u.identities || !u.identities.length) throw new Error('already registered');
      if (!r.data.session) throw new Error('Não consegui ativar a conta. Confira se "Confirm email" está desligado no Supabase (ativação).');
      return u.id;
    },
    logout: async function () { await sb.auth.signOut(); }
  } : null;

  window.claude = {
    use: async function (name) {
      if (name === 'sample' || !sb) return null;
      var u = await init();
      if (!u) return null;
      return ({ db: db, user: user, assets: assets })[name] || null;
    }
  };

})();
