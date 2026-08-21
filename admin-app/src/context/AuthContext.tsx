import React, { createContext, useCallback, useContext, useEffect, useMemo, useState } from 'react';
import { adminApi, Profile } from '../lib/adminApi';
import { registerAdminPushToken } from '../lib/push';
import { supabase } from '../lib/supabase';

type AuthState = {
  loading: boolean;
  profile: Profile | null;
  isAdmin: boolean;
  signIn: (email: string, password: string) => Promise<void>;
  signOut: () => Promise<void>;
  refreshProfile: () => Promise<void>;
};

const AuthContext = createContext<AuthState | null>(null);

async function loadAdminProfile(userId: string) {
  const profile = await adminApi.getProfile(userId);
  if (!adminApi.isAdmin(profile)) {
    await adminApi.signOut();
    throw new Error('Acesso restrito a administradores.');
  }
  try {
    await registerAdminPushToken();
  } catch {
    // Push opcional — login não falha
  }
  return profile;
}

export function AuthProvider({ children }: { children: React.ReactNode }) {
  const [loading, setLoading] = useState(true);
  const [profile, setProfile] = useState<Profile | null>(null);

  const refreshProfile = useCallback(async () => {
    const session = await adminApi.getSession();
    if (!session?.user) {
      setProfile(null);
      return;
    }
    const p = await loadAdminProfile(session.user.id);
    setProfile(p);
  }, []);

  useEffect(() => {
    let mounted = true;
    (async () => {
      try {
        const session = await adminApi.getSession();
        if (!session?.user) {
          if (mounted) setProfile(null);
          return;
        }
        const p = await loadAdminProfile(session.user.id);
        if (mounted) setProfile(p);
      } catch {
        if (mounted) setProfile(null);
      } finally {
        if (mounted) setLoading(false);
      }
    })();

    const { data: sub } = supabase.auth.onAuthStateChange(async (_event, session) => {
      if (!session?.user) {
        setProfile(null);
        return;
      }
      try {
        const p = await loadAdminProfile(session.user.id);
        setProfile(p);
      } catch {
        setProfile(null);
      }
    });

    return () => {
      mounted = false;
      sub.subscription.unsubscribe();
    };
  }, []);

  const signIn = useCallback(async (email: string, password: string) => {
    await adminApi.signIn(email, password);
    const session = await adminApi.getSession();
    if (!session?.user) throw new Error('Sessão inválida');
    const p = await loadAdminProfile(session.user.id);
    setProfile(p);
  }, []);

  const signOut = useCallback(async () => {
    await adminApi.signOut();
    setProfile(null);
  }, []);

  const value = useMemo(
    () => ({
      loading,
      profile,
      isAdmin: !!profile?.is_admin,
      signIn,
      signOut,
      refreshProfile,
    }),
    [loading, profile, signIn, signOut, refreshProfile]
  );

  return <AuthContext.Provider value={value}>{children}</AuthContext.Provider>;
}

export function useAuth() {
  const ctx = useContext(AuthContext);
  if (!ctx) throw new Error('useAuth fora do AuthProvider');
  return ctx;
}
