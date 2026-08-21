import { GAME_IDS } from './config';
import { supabase } from './supabase';

export type Profile = {
  id: string;
  email: string | null;
  display_name: string | null;
  phone?: string | null;
  player_credits: number;
  is_admin?: boolean;
  current_game?: string | null;
  game_seen_at?: string | null;
};

function normalizeGameId(id: string | null | undefined) {
  const key = String(id || '')
    .toLowerCase()
    .replace(/\.html$/, '');
  if (key === 'bagatela' || key === 'bacatela') return 'bacatela';
  if (key === '21_index') return '21';
  if (key === 'flyx' || key === 'ponto-maior' || key === 'pontomaior') return 'bacbo';
  return key;
}

export function gameLabel(id: string | null | undefined) {
  const map: Record<string, string> = {
    omaha: 'OMAHA5',
    crep: 'CREP',
    bacatela: 'BACATELA',
    bagatela: 'BACATELA',
    chuvadepremios: 'CHUVA DE PRÊMIOS',
    roleta: 'ROLETA',
    flyx: 'PONTO MAIOR',
    bacbo: 'PONTO MAIOR',
    ronda: 'RONDA',
    caipira: 'CAIPIRA',
    '21': '21',
  };
  const key = normalizeGameId(id);
  return map[key] || (key ? key.toUpperCase() : '—');
}

function parseJsonMaybe<T>(data: T | string | null): T | null {
  if (data == null) return null;
  if (typeof data === 'string') {
    try {
      return JSON.parse(data) as T;
    } catch {
      return null;
    }
  }
  return data as T;
}

export const adminApi = {
  async signIn(email: string, password: string) {
    const { data, error } = await supabase.auth.signInWithPassword({
      email: email.trim(),
      password,
    });
    if (error) throw error;
    return data;
  },

  async signOut() {
    const { error } = await supabase.auth.signOut();
    if (error) throw error;
  },

  async getSession() {
    const { data, error } = await supabase.auth.getSession();
    if (error) throw error;
    return data.session;
  },

  async getProfile(userId: string): Promise<Profile | null> {
    const { data, error } = await supabase
      .from('profiles')
      .select('*')
      .eq('id', userId)
      .maybeSingle();
    if (error) throw error;
    return data;
  },

  isAdmin(profile: Profile | null | undefined) {
    return !!(profile && profile.is_admin);
  },

  async listPlayers(): Promise<Profile[]> {
    const { data, error } = await supabase.rpc('admin_list_players');
    if (error) throw error;
    return data || [];
  },

  async adminAdjustCredits(userId: string, delta: number) {
    const { data, error } = await supabase.rpc('admin_adjust_credits', {
      target_user: userId,
      delta,
    });
    if (error) throw error;
    return data;
  },

  async adminSetCredits(userId: string, amount: number) {
    const { data, error } = await supabase.rpc('admin_set_credits', {
      target_user: userId,
      new_amount: amount,
    });
    if (error) throw error;
    return data;
  },

  async adminDeleteUser(userId: string) {
    const { error } = await supabase.rpc('admin_delete_user', {
      target_user: userId,
    });
    if (error) throw error;
  },

  async getGameSettings() {
    const { data, error } = await supabase.rpc('get_game_settings');
    if (error) throw error;
    return parseJsonMaybe(data) ?? data;
  },

  getMaintenanceGames(settings: any): string[] {
    if (!settings) return [];
    const raw = settings.maintenance_games;
    if (Array.isArray(raw) && raw.length) {
      return raw.map((g: string) => normalizeGameId(g)).filter(Boolean);
    }
    const legacy = settings.maintenance;
    if (legacy === true || legacy === 't' || legacy === 1 || legacy === '1') {
      return [...GAME_IDS];
    }
    return [];
  },

  async adminSetMaintenanceGames(gameIds: string[]) {
    const list = (Array.isArray(gameIds) ? gameIds : [])
      .map((g) => normalizeGameId(g))
      .filter((g) => (GAME_IDS as readonly string[]).includes(g));
    const { data, error } = await supabase.rpc('admin_set_maintenance_games', {
      p_games: list,
    });
    if (error) throw error;
    return data;
  },

  async adminUpdateGameSettings({
    enabled,
    rtpPercent,
  }: {
    enabled: boolean;
    rtpPercent: number;
  }) {
    const rtp = Math.floor(Number(rtpPercent));
    const { data, error } = await supabase.rpc('admin_update_game_settings', {
      p_enabled: !!enabled,
      p_rtp_percent: Math.max(0, Math.min(100, Number.isFinite(rtp) ? rtp : 20)),
    });
    if (error) throw error;
    return data;
  },

  async listGameRtp() {
    const { data, error } = await supabase.rpc('list_game_rtp');
    if (error) throw error;
    return data || [];
  },

  async adminUpsertGameRtp({
    gameId,
    enabled,
    rtpPercent,
  }: {
    gameId: string;
    enabled: boolean;
    rtpPercent: number;
  }) {
    const rtp = Math.floor(Number(rtpPercent));
    const { data, error } = await supabase.rpc('admin_upsert_game_rtp', {
      p_game_id: String(gameId || ''),
      p_enabled: !!enabled,
      p_rtp_percent: Math.max(0, Math.min(100, Number.isFinite(rtp) ? rtp : 20)),
    });
    if (error) throw error;
    return parseJsonMaybe(data) ?? data;
  },

  async adminResetBetCounter() {
    const { data, error } = await supabase.rpc('admin_reset_bet_counter');
    if (error) throw error;
    return data;
  },

  async adminListDeposits() {
    const { data, error } = await supabase.rpc('admin_list_deposits');
    if (error) throw error;
    return data || [];
  },

  async adminListWithdrawals() {
    const { data, error } = await supabase.rpc('admin_list_withdrawals');
    if (error) throw error;
    return data || [];
  },

  async adminMarkWithdrawalPaid(id: string) {
    const { data, error } = await supabase.rpc('admin_mark_withdrawal_paid', {
      p_id: id,
    });
    if (error) throw error;
    return data;
  },

  async adminRejectWithdrawal(id: string, note?: string) {
    const { data, error } = await supabase.rpc('admin_reject_withdrawal', {
      p_id: id,
      p_note: note || null,
    });
    if (error) throw error;
    return data;
  },

  async checkPixDeposit(paymentId: string) {
    const { data, error } = await supabase.functions.invoke('cajupay', {
      body: { action: 'check-pix', payment_id: paymentId },
    });
    if (data?.error) throw new Error(data.error);
    if (error) throw new Error(error.message || 'Falha na CajuPay');
    return data;
  },

  async adminRegisterPushToken(token: string) {
    const { data, error } = await supabase.rpc('admin_register_push_token', {
      p_token: token,
    });
    if (error) throw error;
    return data;
  },

  async adminListPlayerProfits() {
    const { data, error } = await supabase.rpc('admin_list_player_profits');
    if (error) throw error;
    return data || [];
  },

  async checkPlayerProfitAlerts(userId: string) {
    const { data, error } = await supabase.rpc('check_player_profit_alerts', {
      p_user_id: userId,
    });
    if (error) throw error;
    return parseJsonMaybe(data) ?? data;
  },

  async notifyAdminProfit(payload: {
    userId: string;
    displayName?: string;
    profit?: number;
  }) {
    const { data, error } = await supabase.functions.invoke('notify-admin-profit', {
      body: payload,
    });
    if (data?.error) throw new Error(data.error);
    if (error) throw new Error(error.message || 'Falha ao notificar');
    return data;
  },
};
