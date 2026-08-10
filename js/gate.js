(function () {
  window.clubAuth = window.omahaAuth;

  let resolveReady;
  window.clubWalletReady = new Promise((resolve) => { resolveReady = resolve; });

  function ensureTheme() {
    if (document.getElementById('clubThemeBacatela')) return;
    const link = document.createElement('link');
    link.id = 'clubThemeBacatela';
    link.rel = 'stylesheet';
    link.href = new URL('../css/theme-bacatela.css', location.href).href;
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
        background:#060912;border-bottom:2px solid #ff2bd6;color:#fff;
        font-family:Arial,Helvetica,sans-serif;
        box-shadow:0 0 14px #ff2bd655;
      }
      #clubGateBar .club-name{
        font-weight:1000;font-size:12px;letter-spacing:1px;color:#ffd91a;
        text-shadow:0 0 10px #ffd91a;
      }
      #clubGateBar .user{font-size:12px;font-weight:800;text-align:center;opacity:.95}
      #clubGateBar .saldo{color:#17c8ff;font-weight:1000}
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
      <div class="user">${name}<div class="saldo">Saldo: ${credits}</div></div>
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
    const wallet = {
      userId: user.id,
      credits: Number(profile?.player_credits || 0),
      async refresh() {
        const p = await omahaAuth.getProfile(user.id);
        this.credits = Number(p?.player_credits || 0);
        return this.credits;
      },
      async set(credits) {
        this.credits = Math.max(0, Number(credits) || 0);
        await omahaAuth.saveCredits(user.id, this.credits);
        const el = document.querySelector('#clubGateBar .saldo');
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
      injectClubBar(user, profile);
      const wallet = makeWallet(user, profile);
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
