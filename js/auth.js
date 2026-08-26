(function () {
  const { createClient } = supabase;
  const client = createClient(window.SUPABASE_URL, window.SUPABASE_ANON_KEY, {
    auth: {
      persistSession: true,
      autoRefreshToken: true,
      detectSessionInUrl: true,
    },
  });

  async function parseFunctionInvoke({ data, error }, fallbackMsg) {
    if (data?.error) throw new Error(data.error);
    if (!error) return data;
    let msg = error.message || fallbackMsg;
    try {
      if (error.context && typeof error.context.json === 'function') {
        const body = await error.context.json();
        if (body?.error) msg = body.error;
      }
    } catch (_) {}
    throw new Error(msg);
  }

  window.omahaAuth = {
    client,

    async getSession() {
      const { data, error } = await client.auth.getSession();
      if (error) throw error;
      return data.session;
    },

    async requireUser(redirectTo = 'login.html') {
      const session = await this.getSession();
      if (!session?.user) {
        location.replace(redirectTo);
        return null;
      }
      return session.user;
    },

    getStoredReferralCode() {
      try {
        const q = new URLSearchParams(location.search).get('ref');
        if (q) {
          const code = String(q).trim().toUpperCase();
          sessionStorage.setItem('club_ref', code);
          return code;
        }
        return String(sessionStorage.getItem('club_ref') || '').trim().toUpperCase() || '';
      } catch (_) {
        return '';
      }
    },

    clearStoredReferralCode() {
      try { sessionStorage.removeItem('club_ref'); } catch (_) {}
    },

    async signUp({ email, password, displayName, phone, referralCode }) {
      const phoneDigits = String(phone || '').replace(/\D/g, '');
      if (phoneDigits.length < 10 || phoneDigits.length > 13) {
        throw new Error('Informe um celular válido com DDD (10 ou 11 dígitos).');
      }
      const ref = String(referralCode || this.getStoredReferralCode() || '').trim().toUpperCase();
      const { data, error } = await client.auth.signUp({
        email,
        password,
        options: {
          data: {
            display_name: displayName || email.split('@')[0],
            phone: phoneDigits,
            terms_accepted: true,
            terms_accepted_at: new Date().toISOString(),
            ...(ref ? { ref } : {}),
          },
        },
      });
      if (error) throw error;
      return data;
    },

    async signIn({ email, password }) {
      const { data, error } = await client.auth.signInWithPassword({ email, password });
      if (error) throw error;
      return data;
    },

    async signOut() {
      const { error } = await client.auth.signOut();
      if (error) throw error;
    },

    async getProfile(userId) {
      const { data, error } = await client
        .from('profiles')
        .select('*')
        .eq('id', userId)
        .maybeSingle();
      if (error) throw error;
      return data;
    },

    async ensureProfile(user) {
      let profile = await this.getProfile(user.id);
      const phoneMeta = String(user.user_metadata?.phone || '').replace(/\D/g, '');
      const refMeta = String(user.user_metadata?.ref || this.getStoredReferralCode() || '')
        .trim()
        .toUpperCase();

      if (profile) {
        // Completa telefone se veio no cadastro e ainda não está no perfil
        if (phoneMeta && !profile.phone) {
          const { data, error } = await client
            .from('profiles')
            .update({ phone: phoneMeta })
            .eq('id', user.id)
            .select('*')
            .maybeSingle();
          if (!error && data) profile = data;
        }
        if (refMeta && !profile.referred_by && !profile.is_admin && !profile.is_manager && !profile.is_consultant) {
          try {
            await client.rpc('claim_referral', { p_code: refMeta });
            this.clearStoredReferralCode();
            profile = (await this.getProfile(user.id)) || profile;
          } catch (_) {}
        }
        return profile;
      }

      const displayName =
        user.user_metadata?.display_name ||
        (user.email ? user.email.split('@')[0] : 'Jogador');

      const { data, error } = await client
        .from('profiles')
        .upsert(
          {
            id: user.id,
            email: user.email,
            display_name: displayName,
            phone: phoneMeta || null,
            player_credits: 0,
            bank_credits: 0,
            is_admin: false,
            is_manager: false,
            is_consultant: false,
          },
          { onConflict: 'id' }
        )
        .select('*')
        .single();

      if (error) {
        profile = await this.getProfile(user.id);
        if (profile) return profile;
        throw error;
      }
      profile = data;
      if (refMeta && !profile.referred_by && !profile.is_consultant && !profile.is_manager) {
        try {
          await client.rpc('claim_referral', { p_code: refMeta });
          this.clearStoredReferralCode();
          profile = (await this.getProfile(user.id)) || profile;
        } catch (_) {}
      }
      return profile;
    },

    isAdmin(profile) {
      return !!(profile && profile.is_admin);
    },

    isManager(profile) {
      return !!(profile && profile.is_manager && !profile.is_admin);
    },

    isConsultant(profile) {
      return !!(profile && profile.is_consultant && !profile.is_admin && !profile.is_manager);
    },

    async routeAfterLogin(profile) {
      if (this.isAdmin(profile)) location.replace('admin.html');
      else if (this.isManager(profile)) location.replace('gerente.html');
      else if (this.isConsultant(profile)) location.replace('consultor.html');
      else location.replace('lobby.html');
    },

    async adminListManagers() {
      const { data, error } = await client.rpc('admin_list_managers');
      if (error) throw error;
      return data || [];
    },

    async adminListManagerPlayers(managerId) {
      const { data, error } = await client.rpc('admin_list_manager_players', {
        p_manager_id: managerId,
      });
      if (error) throw error;
      return data || [];
    },

    async adminListManagerConsultants(managerId) {
      const { data, error } = await client.rpc('admin_list_manager_consultants', {
        p_manager_id: managerId,
      });
      if (error) throw error;
      return data || [];
    },

    async adminSetManager(userId, on, percent = 0) {
      const { data, error } = await client.rpc('admin_set_manager', {
        p_user_id: userId,
        p_on: !!on,
        p_percent: Number(percent) || 0,
      });
      if (error) throw error;
      return data;
    },

    async adminCreateManager({ email, password, displayName, phone, percent }) {
      const result = await client.functions.invoke('admin-managers', {
        body: { email, password, displayName, phone, percent: Number(percent) || 0 },
      });
      return parseFunctionInvoke(result, 'Falha ao criar gerente');
    },

    async managerMyCode() {
      const { data, error } = await client.rpc('manager_my_code');
      if (error) throw error;
      return data;
    },

    async managerSummary() {
      const { data, error } = await client.rpc('manager_summary');
      if (error) throw error;
      return data;
    },

    async managerListPlayers() {
      const { data, error } = await client.rpc('manager_list_players');
      if (error) throw error;
      return data || [];
    },

    async managerListDeposits() {
      const { data, error } = await client.rpc('manager_list_deposits');
      if (error) throw error;
      return data || [];
    },

    async managerListWithdrawals() {
      const { data, error } = await client.rpc('manager_list_withdrawals');
      if (error) throw error;
      return data || [];
    },

    async managerListConsultants() {
      const { data, error } = await client.rpc('manager_list_consultants');
      if (error) throw error;
      return data || [];
    },

    async managerSearchPlayers(q) {
      const { data, error } = await client.rpc('manager_search_players', {
        p_q: String(q || ''),
      });
      if (error) throw error;
      return data || [];
    },

    async managerSetConsultant(userId, on, percent = 0) {
      const { data, error } = await client.rpc('manager_set_consultant', {
        p_user_id: userId,
        p_on: !!on,
        p_percent: Number(percent) || 0,
      });
      if (error) throw error;
      return data;
    },

    async managerCreateConsultant({ email, password, displayName, phone, percent }) {
      const result = await client.functions.invoke('manager-consultants', {
        body: { email, password, displayName, phone, percent: Number(percent) },
      });
      return parseFunctionInvoke(result, 'Falha ao criar consultor');
    },

    async consultantMyCode() {
      const { data, error } = await client.rpc('consultant_my_code');
      if (error) throw error;
      return data;
    },

    async consultantSummary() {
      const { data, error } = await client.rpc('consultant_summary');
      if (error) throw error;
      return data;
    },

    async consultantListPlayers() {
      const { data, error } = await client.rpc('consultant_list_players');
      if (error) throw error;
      return data || [];
    },

    async consultantListDeposits() {
      const { data, error } = await client.rpc('consultant_list_deposits');
      if (error) throw error;
      return data || [];
    },

    async consultantListWithdrawals() {
      const { data, error } = await client.rpc('consultant_list_withdrawals');
      if (error) throw error;
      return data || [];
    },

    referralSignupUrl(code) {
      const base = `${location.origin}${location.pathname.replace(/[^/]*$/, '')}login.html`;
      return `${base}?ref=${encodeURIComponent(code)}`;
    },


    async listPlayers() {
      // SECURITY DEFINER: lê todos os profiles (RLS do select normal só vê a própria conta)
      const { data, error } = await client.rpc('admin_list_players');
      if (error) throw error;
      return data || [];
    },

    gameLabel(id) {
      const map = {
        omaha: 'OMAHA5',
        crep: 'CREP',
        bacatela: 'BACATELA',
        bagatela: 'BACATELA',
        roleta: 'ROLETA',
        flyx: 'PONTO MAIOR',
        bacbo: 'PONTO MAIOR',
        escova: 'ESCOVA',
        ronda: 'RONDA',
        caipira: 'CAIPIRA',
        '21': '21',
      };
      const key = String(id || '').toLowerCase();
      return map[key] || (key ? key.toUpperCase() : '—');
    },

    async setPresence(game) {
      const { error } = await client.rpc('set_player_presence', {
        p_game: game ? String(game) : '',
      });
      if (error) throw error;
    },

    startPresence(game) {
      this.stopPresence();
      if (!game) return;
      const beat = () => { this.setPresence(game).catch(() => {}); };
      beat();
      this._presenceTimer = setInterval(beat, 12000);
      this._presenceVis = () => {
        if (document.visibilityState === 'visible') beat();
      };
      document.addEventListener('visibilitychange', this._presenceVis);
    },

    stopPresence() {
      if (this._presenceTimer) {
        clearInterval(this._presenceTimer);
        this._presenceTimer = null;
      }
      if (this._presenceVis) {
        document.removeEventListener('visibilitychange', this._presenceVis);
        this._presenceVis = null;
      }
    },

    async adminAdjustCredits(userId, delta) {
      const { data, error } = await client.rpc('admin_adjust_credits', {
        target_user: userId,
        delta,
      });
      if (error) throw error;
      return data;
    },

    async adminSetCredits(userId, amount) {
      const { data, error } = await client.rpc('admin_set_credits', {
        target_user: userId,
        new_amount: amount,
      });
      if (error) throw error;
      return data;
    },

    async adminDeleteUser(userId) {
      const { error } = await client.rpc('admin_delete_user', {
        target_user: userId,
      });
      if (error) throw error;
    },

    async saveCredits(userId, playerCredits) {
      const { error } = await client
        .from('profiles')
        .update({
          player_credits: Math.max(0, Number(playerCredits) || 0),
        })
        .eq('id', userId);
      if (error) throw error;
    },

    async recordHand(payload) {
      const { error } = await client.from('game_hands').insert(payload);
      if (error) throw error;
    },

    async bumpStats(userId, result) {
      const profile = await this.getProfile(userId);
      if (!profile) return;
      const patch = {
        hands_played: (profile.hands_played || 0) + 1,
      };
      if (result === 'player') patch.hands_won = (profile.hands_won || 0) + 1;
      else if (result === 'bank') patch.hands_lost = (profile.hands_lost || 0) + 1;
      else if (result === 'fold') patch.hands_folded = (profile.hands_folded || 0) + 1;

      const { error } = await client.from('profiles').update(patch).eq('id', userId);
      if (error) throw error;
    },

    async getGameSettings() {
      const { data, error } = await client.rpc('get_game_settings');
      if (error) throw error;
      return data;
    },

    GAME_IDS: [
      'omaha', 'crep', 'bacatela', 'roleta',
      'bacbo', 'escova', 'ronda', 'caipira', '21',
    ],

    normalizeGameId(id) {
      const key = String(id || '').toLowerCase().replace(/\.html$/, '');
      if (key === 'bagatela' || key === 'bacatela') return 'bacatela';
      if (key === '21_index') return '21';
      if (key === 'flyx' || key === 'ponto-maior' || key === 'pontomaior') return 'bacbo';
      return key;
    },

    isGameHidden(gameId) {
      const raw = String(gameId || '').toLowerCase().replace(/\.html$/, '');
      const list = window.CLUB_HIDDEN_GAMES;
      if (!Array.isArray(list) || !raw) return false;
      // Compara o id “de arquivo” sem alias (flyx≠bacbo), para não esconder Ponto Maior.
      return list.map((g) => String(g || '').toLowerCase().replace(/\.html$/, '')).includes(raw);
    },

    getMaintenanceGames(settings) {
      if (!settings) return [];
      const raw = settings.maintenance_games;
      if (Array.isArray(raw) && raw.length) {
        return raw.map((g) => this.normalizeGameId(g)).filter(Boolean);
      }
      const legacy = settings.maintenance;
      if (legacy === true || legacy === 't' || legacy === 1 || legacy === '1') {
        return this.GAME_IDS.slice();
      }
      return [];
    },

    isMaintenance(settings) {
      return this.getMaintenanceGames(settings).length > 0;
    },

    isGameInMaintenance(settings, gameId) {
      const id = this.normalizeGameId(gameId);
      if (!id) return false;
      return this.getMaintenanceGames(settings).includes(id);
    },

    async adminSetMaintenanceGames(gameIds) {
      const list = (Array.isArray(gameIds) ? gameIds : [])
        .map((g) => this.normalizeGameId(g))
        .filter((g) => this.GAME_IDS.includes(g));
      const { data, error } = await client.rpc('admin_set_maintenance_games', {
        p_games: list,
      });
      if (error) throw error;
      return data;
    },

    async adminSetMaintenance(on) {
      const { data, error } = await client.rpc('admin_set_maintenance', {
        p_on: !!on,
      });
      if (error) throw error;
      return data;
    },

    async checkGamesClosed({ gameId, lobbyUrl = 'lobby.html' } = {}) {
      try {
        const settings = await this.getGameSettings();
        if (!this.isGameInMaintenance(settings, gameId)) return false;
        location.replace(lobbyUrl);
        return true;
      } catch (_) {
        return false;
      }
    },

    startMaintenanceWatch({ gameId, lobbyUrl = 'lobby.html', intervalMs = 8000 } = {}) {
      const tick = () => this.checkGamesClosed({ gameId, lobbyUrl });
      tick();
      return setInterval(tick, intervalMs);
    },

    async adminUpdateGameSettings({ enabled, rtpPercent }) {
      const rtp = Math.floor(Number(rtpPercent));
      const { data, error } = await client.rpc('admin_update_game_settings', {
        p_enabled: !!enabled,
        p_rtp_percent: Math.max(0, Math.min(100, Number.isFinite(rtp) ? rtp : 20)),
      });
      if (error) throw error;
      return data;
    },

    async listGameRtp() {
      const { data, error } = await client.rpc('list_game_rtp');
      if (error) {
        const msg = error.message || '';
        if (/could not find|schema cache|list_game_rtp|column .* does not exist/i.test(msg)) {
          throw new Error(`${msg} — Rode supabase/fix-list-game-rtp.sql no SQL Editor do Supabase.`);
        }
        throw error;
      }
      return data || [];
    },

    async adminUpsertGameRtp({ gameId, enabled, rtpPercent }) {
      const rtp = Math.floor(Number(rtpPercent));
      const { data, error } = await client.rpc('admin_upsert_game_rtp', {
        p_game_id: String(gameId || ''),
        p_enabled: !!enabled,
        p_rtp_percent: Math.max(0, Math.min(100, Number.isFinite(rtp) ? rtp : 20)),
      });
      if (error) throw error;
      // PostgREST pode devolver objeto ou string JSON.
      if (typeof data === 'string') {
        try { return JSON.parse(data); } catch (_) { return null; }
      }
      return data;
    },

    async adminResetBetCounter() {
      const { data, error } = await client.rpc('admin_reset_bet_counter');
      if (error) throw error;
      return data;
    },

    async requestWithdrawal(amount, pixKey, document) {
      const { data, error } = await client.rpc('request_withdrawal', {
        p_amount: Number(amount),
        p_pix_key: String(pixKey || '').trim(),
        p_document: String(document || '').replace(/\D/g, '') || null,
      });
      if (error) throw error;
      return data;
    },

    /** Solicita saque e dispara PIX automático (CajuPay) na mesma chamada. */
    async requestAutomaticWithdrawal({ amount, pixKey, document }) {
      return this.invokeCajupay({
        action: 'request-withdraw',
        amount: Number(amount),
        pix_key: String(pixKey || '').trim(),
        document: String(document || '').replace(/\D/g, '') || null,
      });
    },

    async invokeCajupay(payload) {
      const { data, error } = await client.functions.invoke('cajupay', { body: payload });
      if (data?.error) throw new Error(data.error);
      if (error) {
        let msg = error.message || 'Falha na CajuPay';
        try {
          if (error.context && typeof error.context.json === 'function') {
            const body = await error.context.json();
            if (body?.error) msg = body.error;
          }
        } catch (_) {}
        throw new Error(msg);
      }
      return data;
    },

    async createPixDeposit({ amount, document, phone, checkoutUrl }) {
      return this.invokeCajupay({
        action: 'create-pix',
        amount,
        document,
        phone,
        checkout_url: checkoutUrl || (typeof location !== 'undefined' ? location.origin + location.pathname : ''),
      });
    },

    async checkPixDeposit(paymentId) {
      return this.invokeCajupay({ action: 'check-pix', payment_id: paymentId });
    },

    async sendAutomaticPayout(withdrawalId) {
      return this.invokeCajupay({ action: 'payout', withdrawal_id: withdrawalId });
    },

    async adminPayWithdrawalPix(withdrawalId) {
      return this.sendAutomaticPayout(withdrawalId);
    },

    async listMyDeposits() {
      const { data, error } = await client.rpc('list_my_deposits');
      if (error) throw error;
      return data || [];
    },

    async listMyWithdrawals() {
      const { data, error } = await client.rpc('list_my_withdrawals');
      if (error) throw error;
      return data || [];
    },

    async adminListWithdrawals() {
      const { data, error } = await client.rpc('admin_list_withdrawals');
      if (error) throw error;
      return data || [];
    },

    async adminListDeposits() {
      const { data, error } = await client.rpc('admin_list_deposits');
      if (error) throw error;
      return data || [];
    },

    async adminMarkWithdrawalPaid(id) {
      const { data, error } = await client.rpc('admin_mark_withdrawal_paid', {
        p_id: id,
      });
      if (error) throw error;
      return data;
    },

    async adminRejectWithdrawal(id, note) {
      const { data, error } = await client.rpc('admin_reject_withdrawal', {
        p_id: id,
        p_note: note || null,
      });
      if (error) throw error;
      return data;
    },
  };

  window.clubAuth = window.omahaAuth;
})();
