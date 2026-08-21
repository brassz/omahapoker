import { useCallback, useEffect, useState } from 'react';
import {
  Pressable,
  ScrollView,
  StyleSheet,
  Switch,
  Text,
  TextInput,
  View,
} from 'react-native';
import { Btn, Field, Msg, Panel, Screen } from '@/src/components/ui';
import { adminApi, gameLabel } from '@/src/lib/adminApi';
import { GAME_IDS } from '@/src/lib/config';
import { colors } from '@/src/theme';

type GameRtpRow = {
  game_id: string;
  enabled?: boolean;
  rtp_percent?: number;
};

export default function ConfigScreen() {
  const [msg, setMsg] = useState('');
  const [kind, setKind] = useState<'ok' | 'err'>('ok');
  const [maint, setMaint] = useState<string[]>([]);
  const [rtpEnabled, setRtpEnabled] = useState(false);
  const [rtpPercent, setRtpPercent] = useState('20');
  const [counter, setCounter] = useState(0);
  const [gameRtp, setGameRtp] = useState<GameRtpRow[]>([]);

  const load = useCallback(async () => {
    try {
      const [settings, rtpList] = await Promise.all([
        adminApi.getGameSettings(),
        adminApi.listGameRtp().catch(() => []),
      ]);
      setMaint(adminApi.getMaintenanceGames(settings));
      setRtpEnabled(!!settings?.enabled);
      setRtpPercent(String(settings?.rtp_percent ?? 20));
      setCounter(Number(settings?.bet_counter || 0));
      setGameRtp(
        (rtpList || []).map((r: any) => ({
          game_id: r.game_id,
          enabled: !!r.enabled,
          rtp_percent: Number(r.rtp_percent ?? 20),
        }))
      );
      setMsg('');
    } catch (e: any) {
      setKind('err');
      setMsg(e?.message || 'Erro ao carregar config');
    }
  }, []);

  useEffect(() => {
    load();
  }, [load]);

  const toggleMaint = (id: string) => {
    setMaint((prev) => (prev.includes(id) ? prev.filter((x) => x !== id) : [...prev, id]));
  };

  const saveMaint = async () => {
    try {
      await adminApi.adminSetMaintenanceGames(maint);
      setKind('ok');
      setMsg('Manutenção salva');
    } catch (e: any) {
      setKind('err');
      setMsg(e?.message || 'Falha');
    }
  };

  const saveGlobalRtp = async () => {
    try {
      await adminApi.adminUpdateGameSettings({
        enabled: rtpEnabled,
        rtpPercent: Number(rtpPercent),
      });
      setKind('ok');
      setMsg('RTP global salvo');
      await load();
    } catch (e: any) {
      setKind('err');
      setMsg(e?.message || 'Falha');
    }
  };

  const resetCounter = async () => {
    try {
      await adminApi.adminResetBetCounter();
      setKind('ok');
      setMsg('Contador zerado');
      await load();
    } catch (e: any) {
      setKind('err');
      setMsg(e?.message || 'Falha');
    }
  };

  const saveGameRtp = async () => {
    try {
      for (const row of gameRtp) {
        await adminApi.adminUpsertGameRtp({
          gameId: row.game_id,
          enabled: !!row.enabled,
          rtpPercent: Number(row.rtp_percent ?? 20),
        });
      }
      setKind('ok');
      setMsg('RTP por jogo salvo');
      await load();
    } catch (e: any) {
      setKind('err');
      setMsg(e?.message || 'Falha');
    }
  };

  return (
    <Screen style={{ paddingBottom: 0 }}>
      <ScrollView contentContainerStyle={{ paddingBottom: 40 }}>
        <Msg text={msg} kind={kind} />

        <Panel title="★ MANUTENÇÃO POR JOGO">
          {GAME_IDS.map((id) => (
            <Pressable key={id} style={styles.row} onPress={() => toggleMaint(id)}>
              <Text style={styles.rowLabel}>{gameLabel(id)}</Text>
              <Switch
                value={maint.includes(id)}
                onValueChange={() => toggleMaint(id)}
                trackColor={{ true: colors.cyan, false: colors.muted }}
              />
            </Pressable>
          ))}
          <Btn label="SALVAR MANUTENÇÃO" onPress={saveMaint} />
        </Panel>

        <Panel title="★ MANIPULAÇÃO GERAL">
          <View style={styles.row}>
            <Text style={styles.rowLabel}>Ativa</Text>
            <Switch
              value={rtpEnabled}
              onValueChange={setRtpEnabled}
              trackColor={{ true: colors.cyan, false: colors.muted }}
            />
          </View>
          <Field
            label="RTP do jogador (%)"
            value={rtpPercent}
            onChangeText={setRtpPercent}
            keyboardType="numeric"
          />
          <Text style={styles.meta}>Apostas contadas: {counter}</Text>
          <View style={styles.actions}>
            <Btn label="SALVAR" onPress={saveGlobalRtp} />
            <Btn label="ZERAR CONTADOR" onPress={resetCounter} variant="ghost" />
          </View>
        </Panel>

        <Panel title="★ RTP POR JOGO">
          {gameRtp.length === 0 ? (
            <Text style={styles.meta}>Sem dados (rode game-rtp.sql)</Text>
          ) : (
            gameRtp.map((row, idx) => (
              <View key={row.game_id} style={styles.gameRow}>
                <Text style={styles.rowLabel}>{gameLabel(row.game_id)}</Text>
                <View style={styles.row}>
                  <Text style={styles.meta}>Próprio</Text>
                  <Switch
                    value={!!row.enabled}
                    onValueChange={(v) => {
                      setGameRtp((list) =>
                        list.map((r, i) => (i === idx ? { ...r, enabled: v } : r))
                      );
                    }}
                    trackColor={{ true: colors.cyan, false: colors.muted }}
                  />
                </View>
                <TextInput
                  style={styles.input}
                  keyboardType="numeric"
                  value={String(row.rtp_percent ?? 20)}
                  onChangeText={(t) => {
                    setGameRtp((list) =>
                      list.map((r, i) =>
                        i === idx ? { ...r, rtp_percent: Number(t) || 0 } : r
                      )
                    );
                  }}
                />
              </View>
            ))
          )}
          <Btn label="SALVAR POR JOGO" onPress={saveGameRtp} />
        </Panel>
      </ScrollView>
    </Screen>
  );
}

const styles = StyleSheet.create({
  row: {
    flexDirection: 'row',
    alignItems: 'center',
    justifyContent: 'space-between',
    marginBottom: 8,
  },
  rowLabel: { color: colors.text, fontWeight: '800', flex: 1 },
  meta: { color: colors.muted, fontWeight: '700', fontSize: 12 },
  actions: { flexDirection: 'row', gap: 8, marginTop: 8 },
  gameRow: {
    borderWidth: 1,
    borderColor: colors.borderSoft,
    borderRadius: 10,
    padding: 8,
    marginBottom: 8,
  },
  input: {
    backgroundColor: colors.inputBg,
    borderWidth: 1,
    borderColor: colors.borderSoft,
    borderRadius: 8,
    color: colors.text,
    paddingHorizontal: 10,
    paddingVertical: 8,
    fontWeight: '700',
    marginTop: 4,
  },
});
