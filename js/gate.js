(function () {
  window.clubAuth = window.omahaAuth;

  let resolveReady;
  window.clubWalletReady = new Promise((resolve) => { resolveReady = resolve; });

  function ensureTheme() {
    if (document.getElementById('clubThemeBacatela')) return;
    const link = document.createElement('link');
    link.id = 'clubThemeBacatela';
    link.rel = 'stylesheet';
    link.href = new URL('../css/theme-bacatela.css?v=11', location.href).href;
    document.head.appendChild(link);
  }

  function injectClubBar(user, profile) {
    if (document.getElementById('clubGateBar')) return;

    const style = document.createElement('style');
    style.textContent = `
      #clubGateBar{
        position:sticky;top:0;z-index:99999;
        display:grid;grid-template-columns:auto 1fr auto;gap:8px;align-items:center;
        padding:6px 8px;margin:0;
        background:#040810;border-bottom:2px solid #17c8ff;color:#fff;
        font-family:Arial,Helvetica,sans-serif;
        box-shadow:0 0 14px #17c8ff88;
        animation:clubGatePulse 1.6s ease-in-out infinite;
      }
      @keyframes clubGatePulse{
        0%,100%{box-shadow:0 0 10px #17c8ff55;border-bottom-color:#17c8ff}
        50%{box-shadow:0 0 22px #00eaffcc;border-bottom-color:#7af0ff}
      }
      #clubGateBar .club-name{
        font-weight:1000;font-size:12px;letter-spacing:1px;color:#17c8ff;
        text-shadow:0 0 10px #17c8ff;
        animation:clubNameBlink 1.1s ease-in-out infinite;
      }
      @keyframes clubNameBlink{
        0%,100%{color:#17c8ff;text-shadow:0 0 6px #17c8ff,0 0 14px #00eaff}
        50%{color:#b8f7ff;text-shadow:0 0 12px #fff,0 0 24px #00eaff}
      }
      #clubGateBar .user{
        display:flex;flex-direction:column;align-items:center;justify-content:center;
        gap:2px;min-width:0;text-align:center;
      }
      #clubGateBar .user .name{
        font-size:13px;font-weight:1000;line-height:1.2;
        max-width:100%;overflow:hidden;text-overflow:ellipsis;white-space:nowrap;
      }
      #clubGateBar .user .saldo{
        font-size:12px;font-weight:1000;color:#17c8ff;line-height:1.2;
        text-shadow:0 0 10px #17c8ff88;
      }
      #clubGateBar button{
        border:0;border-radius:8px;padding:8px 10px;font-weight:900;cursor:pointer;color:#00131b;
        background:linear-gradient(180deg,#0284c7,#17c8ff);font-size:12px;border:2px solid #7dd3fc;
      }
      #clubGateBar button.out{
        color:#fff;background:linear-gradient(180deg,#b40000,#ff3434);border:2px solid #ff8a8a;
      }
    `;
    document.head.appendChild(style);

    const bar = document.createElement('div');
    bar.id = 'clubGateBar';
    const name = profile?.display_name || user?.email || 'Jogador';
    const credits = Number(profile?.player_credits || 0).toLocaleString('pt-BR');
    bar.innerHTML = `
      <div>
        <div class="club-name">CLUBEDEJOGOSCAIPIRA</div>
        <button type="button" id="clubBackLobby">← LOBBY</button>
      </div>
      <div class="user">
        <div class="name">${name}</div>
        <div class="saldo">Saldo: ${credits}</div>
      </div>
      <button type="button" class="out" id="clubLogout">SAIR</button>
    `;
    document.body.prepend(bar);

    document.getElementById('clubBackLobby').onclick = () => {
      location.href = new URL('../lobby.html', location.href).href;
    };
    document.getElementById('clubLogout').onclick = async () => {
      try { await omahaAuth.signOut(); } catch (_) {}
      location.replace(new URL('../login.html', location.href).href);
    };
  }

  function makeWallet(user, profile) {
    let writeChain = Promise.resolve();
    const wallet = {
      userId: user.id,
      credits: Number(profile?.player_credits || 0),
      sealed: false,
      async refresh() {
        const p = await omahaAuth.getProfile(user.id);
        this.credits = Number(p?.player_credits || 0);
        return this.credits;
      },
      async set(credits) {
        this.sealed = true;
        const next = Math.max(0, Number(credits) || 0);
        this.credits = next;
        const run = writeChain.then(async () => {
          await omahaAuth.saveCredits(user.id, next);
          const el = document.querySelector('#clubGateBar .user .saldo');
          if (el) el.textContent = `Saldo: ${next.toLocaleString('pt-BR')}`;
        });
        writeChain = run.catch(() => {});
        await run;
        return this.credits;
      },
      async add(delta) {
        return this.set(this.credits + Number(delta || 0));
      },
    };
    window.clubWallet = wallet;
    return wallet;
  }

  function makePreviewWallet() {
    const wallet = {
      userId: 'preview',
      credits: 1000,
      sealed: false,
      async refresh() { return this.credits; },
      async set(credits) {
        this.sealed = true;
        this.credits = Math.max(0, Number(credits) || 0);
        const el = document.querySelector('#clubGateBar .user .saldo');
        if (el) el.textContent = `Saldo: ${this.credits.toLocaleString('pt-BR')}`;
        return this.credits;
      },
      async add(delta) {
        return this.set(this.credits + Number(delta || 0));
      },
    };
    window.clubWallet = wallet;
    return wallet;
  }

  window.clubGate = {
    async start() {
      ensureTheme();

      /* ?preview=1 — visualizar jogo sem login (só para teste visual) */
      if (new URLSearchParams(location.search).has('preview')) {
        const user = { id: 'preview', email: 'preview@clube.local' };
        const profile = { display_name: 'PREVIEW', player_credits: 1000, is_admin: false };
        injectClubBar(user, profile);
        const wallet = makePreviewWallet();
        resolveReady(wallet);
        return { user, profile, wallet };
      }

      const user = await omahaAuth.requireUser('../login.html');
      if (!user) {
        resolveReady(null);
        return null;
      }
      let profile = null;
      try { profile = await omahaAuth.ensureProfile(user); } catch (_) {}
      if (profile && omahaAuth.isAdmin(profile)) {
        // Admin pode entrar nos jogos, mas o painel é admin.html
      }
      try {
        const settings = await omahaAuth.getGameSettings();
        if (omahaAuth.isMaintenance(settings)) {
          document.body.innerHTML = `
            <div style="min-height:100vh;display:flex;align-items:center;justify-content:center;background:#05070e;color:#fff;font-family:Arial,Helvetica,sans-serif;text-align:center;padding:24px">
              <div>
                <div style="font-size:22px;font-weight:1000;color:#ffd91a;letter-spacing:1px">SITE EM MANUTENÇÃO</div>
                <p style="font-weight:800;color:#d8e7ff;line-height:1.45">Todos os jogos estão fechados.<br>Voltando ao lobby...</p>
              </div>
            </div>`;
          resolveReady(null);
          location.replace('../lobby.html');
          return null;
        }
      } catch (_) {}
      injectClubBar(user, profile);
      const wallet = makeWallet(user, profile);
      if (typeof omahaAuth.startMaintenanceWatch === 'function') {
        omahaAuth.startMaintenanceWatch({ lobbyUrl: '../lobby.html', intervalMs: 8000 });
      }
      if (typeof omahaAuth.startPresence === 'function') {
        const file = (location.pathname.split('/').pop() || '').replace(/\.html$/i, '').toLowerCase();
        const game = file === 'bacatela' || file === 'bagatela' ? 'bacatela'
          : file === '21_index' ? '21'
          : file;
        omahaAuth.startPresence(game);
      }
      resolveReady(wallet);
      return { user, profile, wallet };
    },
  };

  if (document.readyState === 'loading') {
    document.addEventListener('DOMContentLoaded', () => { clubGate.start(); });
  } else {
    clubGate.start();
  }
})();
