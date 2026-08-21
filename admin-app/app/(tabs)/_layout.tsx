import { Redirect, Tabs } from 'expo-router';
import { Text } from 'react-native';
import { useAuth } from '@/src/context/AuthContext';
import { colors } from '@/src/theme';

function TabIcon({ label }: { label: string }) {
  return (
    <Text style={{ color: colors.cyanBright, fontSize: 10, fontWeight: '900' }}>
      {label}
    </Text>
  );
}

export default function TabsLayout() {
  const { isAdmin, signOut } = useAuth();

  if (!isAdmin) return <Redirect href="/login" />;

  return (
    <Tabs
      screenOptions={{
        headerStyle: { backgroundColor: colors.bg },
        headerTintColor: colors.gold,
        headerTitleStyle: { fontWeight: '900' },
        headerRight: () => (
          <Text
            onPress={() => signOut()}
            style={{ color: colors.danger, fontWeight: '900', marginRight: 12 }}
          >
            SAIR
          </Text>
        ),
        tabBarStyle: {
          backgroundColor: colors.bg,
          borderTopColor: colors.border,
        },
        tabBarActiveTintColor: colors.cyan,
        tabBarInactiveTintColor: colors.muted,
        tabBarLabelStyle: { fontWeight: '800', fontSize: 10 },
      }}
    >
      <Tabs.Screen
        name="live"
        options={{
          title: 'Em jogo',
          tabBarIcon: () => <TabIcon label="●" />,
        }}
      />
      <Tabs.Screen
        name="players"
        options={{
          title: 'Jogadores',
          tabBarIcon: () => <TabIcon label="☺" />,
        }}
      />
      <Tabs.Screen
        name="deposits"
        options={{
          title: 'Depósitos',
          tabBarIcon: () => <TabIcon label="↓" />,
        }}
      />
      <Tabs.Screen
        name="withdrawals"
        options={{
          title: 'Saques',
          tabBarIcon: () => <TabIcon label="↑" />,
        }}
      />
      <Tabs.Screen
        name="config"
        options={{
          title: 'Config',
          tabBarIcon: () => <TabIcon label="⚙" />,
        }}
      />
      <Tabs.Screen
        name="profit"
        options={{
          title: 'Lucro',
          tabBarIcon: () => <TabIcon label="$" />,
        }}
      />
    </Tabs>
  );
}
