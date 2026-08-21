import { useCallback, useEffect, useState } from 'react';
import { FlatList, RefreshControl, StyleSheet, Text, View } from 'react-native';
import { Empty, Msg, Panel, Screen } from '@/src/components/ui';
import { adminApi, gameLabel, Profile } from '@/src/lib/adminApi';
import { colors, money } from '@/src/theme';

const LIVE_MS = 45000;

function isLive(p: Profile) {
  if (!p.game_seen_at || !p.current_game) return false;
  const t = new Date(p.game_seen_at).getTime();
  return Number.isFinite(t) && Date.now() - t < LIVE_MS;
}

export default function LiveScreen() {
  const [players, setPlayers] = useState<Profile[]>([]);
  const [msg, setMsg] = useState('');
  const [refreshing, setRefreshing] = useState(false);

  const load = useCallback(async (silent = false) => {
    if (!silent) setRefreshing(true);
    try {
      const list = await adminApi.listPlayers();
      setPlayers(list.filter(isLive));
      setMsg('');
    } catch (e: any) {
      setMsg(e?.message || 'Erro ao listar');
    } finally {
      setRefreshing(false);
    }
  }, []);

  useEffect(() => {
    load();
    const id = setInterval(() => load(true), 8000);
    return () => clearInterval(id);
  }, [load]);

  return (
    <Screen>
      <Panel title="★ EM JOGO AGORA" style={{ flex: 1 }}>
        <Msg text={msg} kind="err" />
        <Text style={styles.hint}>Presença recente (&lt; 45s)</Text>
        <FlatList
          style={{ flex: 1 }}
          data={players}
          keyExtractor={(item) => item.id}
          refreshControl={
            <RefreshControl refreshing={refreshing} onRefresh={() => load()} tintColor={colors.cyan} />
          }
          ListEmptyComponent={<Empty text="Ninguém em jogo no momento." />}
          renderItem={({ item }) => (
            <View style={styles.row}>
              <View style={{ flex: 1 }}>
                <Text style={styles.name}>{item.display_name || item.email}</Text>
                <Text style={styles.meta}>{item.email}</Text>
              </View>
              <View style={{ alignItems: 'flex-end' }}>
                <Text style={styles.live}>{gameLabel(item.current_game)}</Text>
                <Text style={styles.credits}>{money(item.player_credits)}</Text>
              </View>
            </View>
          )}
        />
      </Panel>
    </Screen>
  );
}

const styles = StyleSheet.create({
  hint: { color: colors.muted, fontWeight: '700', marginBottom: 8, fontSize: 12 },
  row: {
    flexDirection: 'row',
    gap: 8,
    paddingVertical: 10,
    borderBottomWidth: 1,
    borderBottomColor: colors.borderSoft,
  },
  name: { color: colors.text, fontWeight: '900' },
  meta: { color: colors.muted, fontSize: 12, fontWeight: '700' },
  live: { color: colors.live, fontWeight: '900' },
  credits: { color: colors.cyanBright, fontWeight: '800', marginTop: 2 },
});
