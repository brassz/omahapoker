import { useCallback, useEffect, useMemo, useState } from 'react';
import {
  Alert,
  FlatList,
  RefreshControl,
  StyleSheet,
  Text,
  TextInput,
  View,
} from 'react-native';
import { Btn, Empty, Field, Msg, Panel, Screen } from '@/src/components/ui';
import { adminApi, Profile } from '@/src/lib/adminApi';
import { colors, money } from '@/src/theme';

export default function PlayersScreen() {
  const [players, setPlayers] = useState<Profile[]>([]);
  const [query, setQuery] = useState('');
  const [msg, setMsg] = useState('');
  const [kind, setKind] = useState<'ok' | 'err'>('ok');
  const [refreshing, setRefreshing] = useState(false);
  const [amounts, setAmounts] = useState<Record<string, string>>({});

  const load = useCallback(async () => {
    setRefreshing(true);
    try {
      setPlayers(await adminApi.listPlayers());
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

  const filtered = useMemo(() => {
    const q = query.trim().toLowerCase();
    if (!q) return players;
    return players.filter((p) => {
      const hay = `${p.display_name || ''} ${p.email || ''} ${p.phone || ''}`.toLowerCase();
      return hay.includes(q);
    });
  }, [players, query]);

  const getAmt = (id: string) => Number(String(amounts[id] || '').replace(',', '.'));

  const adjust = async (id: string, sign: 1 | -1) => {
    const n = getAmt(id);
    if (!Number.isFinite(n) || n <= 0) {
      setKind('err');
      setMsg('Informe um valor > 0');
      return;
    }
    try {
      await adminApi.adminAdjustCredits(id, sign * n);
      setKind('ok');
      setMsg('Créditos atualizados');
      await load();
    } catch (e: any) {
      setKind('err');
      setMsg(e?.message || 'Falha');
    }
  };

  const setCredits = async (id: string) => {
    const n = getAmt(id);
    if (!Number.isFinite(n) || n < 0) {
      setKind('err');
      setMsg('Valor inválido');
      return;
    }
    try {
      await adminApi.adminSetCredits(id, n);
      setKind('ok');
      setMsg('Créditos definidos');
      await load();
    } catch (e: any) {
      setKind('err');
      setMsg(e?.message || 'Falha');
    }
  };

  const remove = (p: Profile) => {
    Alert.alert('Excluir jogador', `Excluir ${p.display_name || p.email}?`, [
      { text: 'Cancelar', style: 'cancel' },
      {
        text: 'Excluir',
        style: 'destructive',
        onPress: async () => {
          try {
            await adminApi.adminDeleteUser(p.id);
            setKind('ok');
            setMsg('Jogador excluído');
            await load();
          } catch (e: any) {
            setKind('err');
            setMsg(e?.message || 'Falha');
          }
        },
      },
    ]);
  };

  return (
    <Screen>
      <Panel title="★ JOGADORES" style={{ flex: 1 }}>
        <Msg text={msg} kind={kind} />
        <Field label="Buscar" value={query} onChangeText={setQuery} placeholder="nome, e-mail, telefone" />
        <FlatList
          style={{ flex: 1 }}
          data={filtered}
          keyExtractor={(item) => item.id}
          refreshControl={
            <RefreshControl refreshing={refreshing} onRefresh={load} tintColor={colors.cyan} />
          }
          ListEmptyComponent={<Empty text="Nenhum jogador." />}
          renderItem={({ item }) => (
            <View style={styles.card}>
              <Text style={styles.name}>{item.display_name || '—'}</Text>
              <Text style={styles.meta}>{item.email}</Text>
              {item.phone ? <Text style={styles.meta}>{item.phone}</Text> : null}
              <Text style={styles.credits}>{money(item.player_credits)}</Text>
              <TextInput
                style={styles.input}
                keyboardType="numeric"
                placeholder="Valor"
                placeholderTextColor={colors.muted}
                value={amounts[item.id] || ''}
                onChangeText={(t) => setAmounts((s) => ({ ...s, [item.id]: t }))}
              />
              <View style={styles.actions}>
                <Btn label="+ CRÉDITO" onPress={() => adjust(item.id, 1)} />
                <Btn label="− CRÉDITO" onPress={() => adjust(item.id, -1)} variant="ghost" />
              </View>
              <View style={styles.actions}>
                <Btn label="= DEFINIR" onPress={() => setCredits(item.id)} variant="ghost" />
                <Btn label="EXCLUIR" onPress={() => remove(item)} variant="danger" />
              </View>
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
  name: { color: colors.text, fontWeight: '900', fontSize: 15 },
  meta: { color: colors.muted, fontWeight: '700', fontSize: 12 },
  credits: { color: colors.gold, fontWeight: '900', marginVertical: 6 },
  input: {
    backgroundColor: colors.inputBg,
    borderWidth: 1,
    borderColor: colors.borderSoft,
    borderRadius: 8,
    color: colors.text,
    paddingHorizontal: 10,
    paddingVertical: 8,
    marginBottom: 8,
    fontWeight: '700',
  },
  actions: { flexDirection: 'row', gap: 8, marginBottom: 6 },
});
