import { Redirect } from 'expo-router';
import { useAuth } from '@/src/context/AuthContext';
import { Loading } from '@/src/components/ui';

export default function Index() {
  const { loading, isAdmin } = useAuth();
  if (loading) return <Loading />;
  return <Redirect href={isAdmin ? '/(tabs)/live' : '/login'} />;
}
