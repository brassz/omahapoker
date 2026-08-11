(function () {
  const { createClient } = supabase;
  const client = createClient(window.SUPABASE_URL, window.SUPABASE_ANON_KEY, {
    auth: {
      persistSession: true,
      autoRefreshToken: true,
      detectSessionInUrl: true,
    },
  });

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

    async signUp({ email, password, displayName }) {
      const { data, error } = await client.auth.signUp({
        email,
        password,
        options: {
          data: { display_name: displayName || email.split('@')[0] },
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
      if (profile) return profile;

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
            player_credits: 0,
            bank_credits: 0,
            is_admin: false,
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
      return data;
    },

    isAdmin(profile) {
      return !!(profile && profile.is_admin);
    },

    async routeAfterLogin(profile) {
      if (this.isAdmin(profile)) location.replace('admin.html');
      else location.replace('lobby.html');
    },

    async listPlayers() {
      // RPC sincroniza profiles faltantes a partir de auth.users
      const rpc = await client.rpc('admin_list_players');
      if (!rpc.error) return rpc.data || [];

      // Fallback se o SQL ainda não foi aplicado no Supabase
      const { data, error } = await client
        .from('profiles')
        .select('id,email,display_name,player_credits,is_admin,created_at,updated_at')
        .order('created_at', { ascending: false })
        .range(0, 4999);
      if (error) throw rpc.error || error;
      return data || [];
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

    async adminUpdateGameSettings({ enabled, betsPerPlayerWin }) {
      const { data, error } = await client.rpc('admin_update_game_settings', {
        p_enabled: !!enabled,
        p_bets_per_player_win: Math.max(1, Math.floor(Number(betsPerPlayerWin) || 1)),
      });
      if (error) throw error;
      return data;
    },

    async adminResetBetCounter() {
      const { data, error } = await client.rpc('admin_reset_bet_counter');
      if (error) throw error;
      return data;
    },
  };

  window.clubAuth = window.omahaAuth;
})();
