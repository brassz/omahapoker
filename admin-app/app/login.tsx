import { Redirect, router } from 'expo-router';
import { useState } from 'react';
import { KeyboardAvoidingView, Platform, StyleSheet, Text, View } from 'react-native';
import { Btn, Field, Msg, Screen } from '@/src/components/ui';
import { useAuth } from '@/src/context/AuthContext';
import { colors } from '@/src/theme';

export default function LoginScreen() {
  const { isAdmin, signIn } = useAuth();
  const [email, setEmail] = useState('');
  const [password, setPassword] = useState('');
  const [msg, setMsg] = useState('');
  const [busy, setBusy] = useState(false);

  if (isAdmin) return <Redirect href="/(tabs)/live" />;

  const onSubmit = async () => {
    setMsg('');
    setBusy(true);
    try {
      await signIn(email, password);
      router.replace('/(tabs)/live');
    } catch (e: any) {
      setMsg(e?.message || 'Falha no login');
    } finally {
      setBusy(false);
    }
  };

  return (
    <Screen>
      <KeyboardAvoidingView
        behavior={Platform.OS === 'ios' ? 'padding' : undefined}
        style={styles.wrap}
      >
        <Text style={styles.brand}>NextPlay Club</Text>
        <Text style={styles.tag}>PAINEL ADMIN</Text>
        <View style={styles.card}>
          <Msg text={msg} kind="err" />
          <Field
            label="E-mail"
            value={email}
            onChangeText={setEmail}
            keyboardType="email-address"
            placeholder="admin@..."
          />
          <Field
            label="Senha"
            value={password}
            onChangeText={setPassword}
            secureTextEntry
            placeholder="••••••••"
          />
          <Btn label={busy ? 'ENTRANDO...' : 'ENTRAR'} onPress={onSubmit} disabled={busy} />
        </View>
      </KeyboardAvoidingView>
    </Screen>
  );
}

const styles = StyleSheet.create({
  wrap: { flex: 1, justifyContent: 'center' },
  brand: {
    textAlign: 'center',
    color: colors.gold,
    fontWeight: '900',
    fontSize: 26,
    letterSpacing: 1,
  },
  tag: {
    textAlign: 'center',
    color: colors.cyanBright,
    fontWeight: '900',
    marginBottom: 18,
    marginTop: 6,
  },
  card: {
    backgroundColor: colors.panel,
    borderWidth: 2,
    borderColor: colors.border,
    borderRadius: 16,
    padding: 16,
  },
});
