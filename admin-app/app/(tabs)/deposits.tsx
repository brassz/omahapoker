import { useCallback, useEffect, useMemo, useState } from 'react';
import { FlatList, RefreshControl, StyleSheet, Text, View } from 'react-native';
import { Btn, Empty, Msg, Panel, Screen } from '@/src/components/ui';
import { adminApi } from '@/src/lib/adminApi';
import { colors, money } from '@/src/theme';

type Deposit = {
  id: string;
  user_id: string;
  amount: number;
  status: string;
  payment_id?: string | null;
  created_at?: string;
  display_name?: string;
  email?: string;
};

export default function DepositsScreen() {
  const [rows, setRows] = useState<Deposit[]>([]);
  const [msg, setMsg] = useState('');
  const [kind, setKind] = useState<'ok' | 'err'>('ok');
  const [refreshing, setRefreshing] = useState(false);
  const [busyId, setBusyId] = useState<string | null>(null);

  const load = useCallback(async () => {
    setRefreshing(true);
    try {
      setRows(await adminApi.adminListDeposits());
      setMsg('');
    } catch (e: any) {
      setKind('err');
      setMsg(e?.message || 'Erro');
    } finally {
      setRefreshing(false);
    }
  }, []);

  useEffect(() => {
    load();
  }, [load]);

  const stats = useMemo(() => {
    const pending = rows.filter((r) => r.status === 'pending').length;
    const paid = rows.filter((r) => r.status === 'paid');
    const sum = paid.reduce((a, r) => a + Number(r.amount || 0), 0);
    return { pending, paidCount: paid.length, sum };
  }, [rows]);

  const verify = async (row: Deposit) => {
    if (!row.payment_id) {
      setKind('err');
      setMsg('Sem payment_id');
      return;
    }
    setBusyId(row.id);
    try {
      await adminApi.checkPixDeposit(row.payment_id);
      setKind('ok');
      setMsg('PIX verificado');
      await load();
    } catch (e: any) {
      setKind('err');
      setMsg(e?.message || 'Falha ao verificar');
    } finally {
      setBusyId(null);
    }
  };

  return (
    <Screen>
      <Panel title="★ DEPÓSITOS PIX">
        <Msg text={msg} kind={kind} />
        <View style={styles.stats}>
          <Text style={styles.stat}>Pendentes: {stats.pending}</Text>
          <Text style={styles.stat}>Creditados: {stats.paidCount}</Text>
          <Text style={styles.stat}>Total: {money(stats.sum)}</Text>
        </View>
        <FlatList
          data={rows}
          keyExtractor={(item) => item.id}
          refreshControl={
            <RefreshControl refreshing={refreshing} onRefresh={load} tintColor={colors.cyan} />
          }
          ListEmptyComponent={<Empty text="Nenhum depósito." />}
          renderItem={({ item }) => (
            <View style={styles.card}>
              <Text style={styles.name}>{item.display_name || item.email || item.user_id}</Text>
              <Text style={styles.meta}>
                {money(item.amount)} · {String(item.status).toUpperCase()}
              </Text>
              {item.payment_id ? (
                <Text style={styles.meta} numberOfLines={1}>
                  {item.payment_id}
                </Text>
              ) : null}
              {item.status === 'pending' && item.payment_id ? (
                <View style={{ marginTop: 8 }}>
                  <Btn
                    label={busyId === item.id ? '...' : 'VERIFICAR PIX'}
                    onPress={() => verify(item)}
                    disabled={busyId === item.id}
                  />
                </View>
              ) : null}
            </View>
          )}
        />
      </Panel>
    </Screen>
  );
}

const styles = StyleSheet.create({
  stats: { flexDirection: 'row', flexWrap: 'wrap', gap: 10, marginBottom: 10 },
  stat: { color: colors.cyanBright, fontWeight: '800', fontSize: 12 },
  card: {
    borderWidth: 1,
    borderColor: colors.borderSoft,
    borderRadius: 12,
    padding: 10,
    marginBottom: 10,
  },
  name: { color: colors.text, fontWeight: '900' },
  meta: { color: colors.muted, fontWeight: '700', fontSize: 12, marginTop: 2 },
});
