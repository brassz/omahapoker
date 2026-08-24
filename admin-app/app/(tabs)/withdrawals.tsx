import { useCallback, useEffect, useState } from 'react';
import { FlatList, RefreshControl, StyleSheet, Text, View } from 'react-native';
import { Btn, Empty, Msg, Panel, Screen } from '@/src/components/ui';
import { adminApi } from '@/src/lib/adminApi';
import { colors, money } from '@/src/theme';

type Withdrawal = {
  id: string;
  user_id: string;
  amount: number;
  pix_key: string;
  status: string;
  display_name?: string;
  email?: string;
};

export default function WithdrawalsScreen() {
  const [rows, setRows] = useState<Withdrawal[]>([]);
  const [msg, setMsg] = useState('');
  const [kind, setKind] = useState<'ok' | 'err'>('ok');
  const [refreshing, setRefreshing] = useState(false);
  const [busyId, setBusyId] = useState<string | null>(null);

  const load = useCallback(async () => {
    setRefreshing(true);
    try {
      setRows(await adminApi.adminListWithdrawals());
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

  const markPaid = async (id: string) => {
    setBusyId(id);
    try {
      const pay = await adminApi.adminPayWithdrawalPix(id);
      setKind('ok');
      setMsg(pay?.status === 'paid' ? 'PIX pago automaticamente' : 'PIX enviado. Aguardando CajuPay.');
      await load();
    } catch (e: any) {
      setKind('err');
      setMsg(e?.message || 'Falha');
    } finally {
      setBusyId(null);
    }
  };

  const reject = async (id: string) => {
    setBusyId(id);
    try {
      await adminApi.adminRejectWithdrawal(id, 'Recusado pelo admin app');
      setKind('ok');
      setMsg('Saque recusado e saldo devolvido');
      await load();
    } catch (e: any) {
      setKind('err');
      setMsg(e?.message || 'Falha');
    } finally {
      setBusyId(null);
    }
  };

  return (
    <Screen>
      <Panel title="★ SAQUES">
        <Msg text={msg} kind={kind} />
        <FlatList
          data={rows}
          keyExtractor={(item) => item.id}
          refreshControl={
            <RefreshControl refreshing={refreshing} onRefresh={load} tintColor={colors.cyan} />
          }
          ListEmptyComponent={<Empty text="Nenhum saque." />}
          renderItem={({ item }) => (
            <View style={styles.card}>
              <Text style={styles.name}>{item.display_name || item.email || item.user_id}</Text>
              <Text style={styles.meta}>
                {money(item.amount)} · {String(item.status).toUpperCase()}
              </Text>
              <Text style={styles.meta} numberOfLines={1}>
                PIX: {item.pix_key}
              </Text>
              {item.status === 'pending' ? (
                <View style={styles.actions}>
                  <Btn
                    label={busyId === item.id ? '...' : 'PAGAR PIX'}
                    onPress={() => markPaid(item.id)}
                    disabled={busyId === item.id}
                  />
                  <Btn
                    label="RECUSAR"
                    onPress={() => reject(item.id)}
                    variant="danger"
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
  card: {
    borderWidth: 1,
    borderColor: colors.borderSoft,
    borderRadius: 12,
    padding: 10,
    marginBottom: 10,
  },
  name: { color: colors.text, fontWeight: '900' },
  meta: { color: colors.muted, fontWeight: '700', fontSize: 12, marginTop: 2 },
  actions: { flexDirection: 'row', gap: 8, marginTop: 10 },
});
