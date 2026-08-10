(function () {
  async function nextOutcome() {
    try {
      const auth = window.omahaAuth;
      if (!auth?.client) return null;
      const { data, error } = await auth.client.rpc('next_bet_outcome');
      if (error) throw error;
      if (data === 'player' || data === 'bank') return data;
      return null; // fair
    } catch (_) {
      return null;
    }
  }

  window.clubHouse = { nextOutcome };
})();
