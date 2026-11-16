(function () {
  const MIN = 2;
  let MAX = 200;

  function parse(value) {
    return Math.floor(Number(value) || 0);
  }

  function clamp(value) {
    const n = parse(value);
    if (n < MIN) return MIN;
    if (n > MAX) return MAX;
    return n;
  }

  function validate(value) {
    const n = parse(value);
    if (!(n >= MIN)) {
      return { ok: false, value: n, message: `Aposta mínima: ${MIN}` };
    }
    if (n > MAX) {
      return { ok: false, value: n, message: `Aposta máxima: ${MAX}` };
    }
    return { ok: true, value: n, message: '' };
  }

  function setMax(newMax) {
    const v = Math.floor(Number(newMax));
    if (v >= 0 && v <= 5000) MAX = v;
  }

  async function loadFromSettings() {
    try {
      if (window.omahaAuth?.getGameSettings) {
        const s = await omahaAuth.getGameSettings();
        if (s && s.max_bet != null) setMax(s.max_bet);
      }
    } catch (_) {}
  }

  // Auto-load when wallet is ready (after auth/config are loaded)
  if (window.clubWalletReady) {
    window.clubWalletReady.then(() => loadFromSettings());
  }

  window.clubBets = {
    get MIN() { return MIN; },
    get MAX() { return MAX; },
    parse, clamp, validate, setMax, loadFromSettings,
  };
})();
