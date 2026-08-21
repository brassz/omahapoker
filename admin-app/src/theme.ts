export const colors = {
  bg: '#060912',
  panel: '#080812',
  border: '#17c8ff',
  borderSoft: '#17c8ff55',
  cyan: '#17c8ff',
  cyanBright: '#7af0ff',
  gold: '#f5c542',
  text: '#f2f7ff',
  muted: '#8aa0b8',
  live: '#5cff1a',
  danger: '#ff3434',
  dangerBorder: '#ff8a8a',
  ok: '#22c55e',
  warn: '#f59e0b',
  inputBg: '#0c1220',
};

export function money(n: number | null | undefined) {
  const v = Number(n) || 0;
  return v.toLocaleString('pt-BR', {
    style: 'currency',
    currency: 'BRL',
  });
}
