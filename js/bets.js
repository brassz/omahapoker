(function () {
  const MIN = 2;
  const MAX = 200;

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

  window.clubBets = { MIN, MAX, parse, clamp, validate };
})();
