(function () {
  function inferGameId() {
    try {
      const file = (location.pathname.split('/').pop() || '').replace(/\.html$/i, '');
      if (window.omahaAuth?.normalizeGameId) return omahaAuth.normalizeGameId(file);
      return String(file || '').toLowerCase();
    } catch (_) {
      return '';
    }
  }

  async function nextOutcome(gameId) {
    try {
      const auth = window.omahaAuth;
      if (!auth?.client) return null;
      const gid = gameId || inferGameId() || null;
      const { data, error } = await auth.client.rpc('next_bet_outcome', { p_game_id: gid });
      if (error) throw error;
      if (data === 'player' || data === 'bank') return data;
      return null;
    } catch (_) {
      return null;
    }
  }

  window.clubHouse = { nextOutcome };
})();
