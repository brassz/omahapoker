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
          },
          { onConflict: 'id' }
        )
        .select('*')
        .single();

      // Sem policy de insert: o trigger cria o perfil no signup.
      // Se ainda não existir (race), tenta ler de novo.
      if (error) {
        profile = await this.getProfile(user.id);
        if (profile) return profile;
        throw error;
      }
      return data;
    },

    async saveCredits(userId, playerCredits, bankCredits) {
      const { error } = await client
        .from('profiles')
        .update({
          player_credits: playerCredits,
          bank_credits: bankCredits,
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
  };
})();
