import { useCallback, useEffect, useState } from 'react';
import { FlatList, RefreshControl, StyleSheet, Text, View } from 'react-native';
import { Btn, Empty, Msg, Panel, Screen } from '@/src/components/ui';
import { adminApi } from '@/src/lib/adminApi';
import { PROFIT_ALERT_THRESHOLD } from '@/src/lib/config';
import { registerAdminPushToken } from '@/src/lib/push';
import { colors, money } from '@/src/theme';

type ProfitRow = {
  user_id: string;
  email: string | null;
  display_name: string | null;
  phone?: string | null;
  player_credits: number;
  total_deposits: number;
  total_withdrawals: number;
  profit: number;
  alert_active: boolean;
};

export default function ProfitScreen() {
  const [rows, setRows] = useState<ProfitRow[]>([]);
  const [msg, setMsg] = useState('');
  const [kind, setKind] = useState<'ok' | 'err'>('ok');
  const [refreshing, setRefreshing] = useState(false);
  const [pushToken, setPushToken] = useState<string | null>(null);

  const load = useCallback(async () => {
    setRefreshing(true);
    try {
      setRows(await adminApi.adminListPlayerProfits());
      setMsg('');
    } catch (e: any) {
      setKind('err');
      setMsg(e?.message || 'Erro (rode supabase/player-profit.sql)');
    } finally {
      setRefreshing(false);
    }
  }, []);

  useEffect(() => {
    load();
    registerAdminPushToken()
      .then((t) => setPushToken(t))
      .catch(() => setPushToken(null));
  }, [load]);

  const reRegisterPush = async () => {
    try {
      const t = await registerAdminPushToken();
      setPushToken(t);
      setKind('ok');
      setMsg(t ? 'Push token registrado' : 'Permissão de notificação negada');
    } catch (e: any) {
      setKind('err');
      setMsg(e?.message || 'Falha no push');
    }
  };

  const testAlert = async (row: ProfitRow) => {
    try {
      const check = await adminApi.checkPlayerProfitAlerts(row.user_id);
      if (check?.alerted) {
        await adminApi.notifyAdminProfit({
          userId: row.user_id,
          displayName: row.display_name || row.email || 'Jogador',
          profit: Number(row.profit),
        });
      }
      setKind('ok');
      setMsg(
        check?.alerted
          ? `Alerta disparado (${money(row.profit)})`
          : `Sem novo alerta (lucro ${money(check?.profit ?? row.profit)})`
      );
      await load();
    } catch (e: any) {
      setKind('err');
      setMsg(e?.message || 'Falha no teste');
    }
  };

  return (
    <Screen>
      <Panel title="★ LUCRO DOS JOGADORES">
        <Text style={styles.formula}>
          lucro = créditos + saques pagos − depósitos pagos · alerta ≥ {money(PROFIT_ALERT_THRESHOLD)}
        </Text>
        <Msg text={msg} kind={kind} />
        <Text style={styles.meta} numberOfLines={2}>
          Push: {pushToken ? 'registrado' : 'não registrado'}
        </Text>
        <View style={{ marginBottom: 10 }}>
          <Btn label="REGISTRAR PUSH TOKEN" onPress={reRegisterPush} variant="ghost" />
        </View>
        <FlatList
          data={rows}
          keyExtractor={(item) => item.user_id}
          refreshControl={
            <RefreshControl refreshing={refreshing} onRefresh={load} tintColor={colors.cyan} />
          }
          ListEmptyComponent={<Empty text="Sem dados de lucro." />}
          renderItem={({ item }) => {
            const hot = Number(item.profit) >= PROFIT_ALERT_THRESHOLD;
            return (
              <View style={[styles.card, hot && styles.cardHot]}>
                <Text style={styles.name}>{item.display_name || item.email || item.user_id}</Text>
                <Text style={[styles.profit, hot && styles.profitHot]}>
                  Lucro {money(item.profit)}
                  {item.alert_active ? ' · ALERTA' : ''}
                </Text>
                <Text style={styles.meta}>
                  Créditos {money(item.player_credits)} · Dep {money(item.total_deposits)} · Saq{' '}
                  {money(item.total_withdrawals)}
                </Text>
                {hot ? (
                  <View style={{ marginTop: 8 }}>
                    <Btn label="TESTAR / RECHECAR ALERTA" onPress={() => testAlert(item)} variant="ghost" />
                  </View>
                ) : null}
              </View>
            );
          }}
        />
      </Panel>
    </Screen>
  );
}

const styles = StyleSheet.create({
  formula: {
    color: colors.muted,
    fontWeight: '700',
    fontSize: 11,
    marginBottom: 8,
  },
  meta: { color: colors.muted, fontWeight: '700', fontSize: 12, marginBottom: 6 },
  card: {
    borderWidth: 1,
    borderColor: colors.borderSoft,
    borderRadius: 12,
    padding: 10,
    marginBottom: 10,
  },
  cardHot: {
    borderColor: colors.warn,
    backgroundColor: '#1a1408',
  },
  name: { color: colors.text, fontWeight: '900' },
  profit: { color: colors.cyanBright, fontWeight: '900', marginTop: 4 },
  profitHot: { color: colors.warn },
});
