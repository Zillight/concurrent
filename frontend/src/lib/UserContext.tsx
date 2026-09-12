"use client";

import {
  createContext,
  useCallback,
  useContext,
  useEffect,
  useState,
  type ReactNode,
} from "react";
import { useRouter } from "next/navigation";
import { supabase } from "@/lib/supabaseClient";

export interface UserPosition {
  position_id: string;
  role_code: string;
  role_name: string;
  title: string | null;
  branch_id: string | null;
  branch_name: string | null;
  department_id: string | null;
  department_name: string | null;
}

export interface UserProfile {
  id: string;
  full_name: string;
  email: string;
}

interface UserContextValue {
  profile: UserProfile | null;
  positions: UserPosition[];
  loading: boolean;
  error: string | null;
  signOut: () => Promise<void>;
}

const UserContext = createContext<UserContextValue | null>(null);

export function UserProvider({ children }: { children: ReactNode }) {
  const router = useRouter();
  const [profile, setProfile] = useState<UserProfile | null>(null);
  const [positions, setPositions] = useState<UserPosition[]>([]);
  const [loading, setLoading] = useState(true);
  const [error, setError] = useState<string | null>(null);

  useEffect(() => {
    let cancelled = false;

    async function loadContext() {
      const { data, error: rpcError } = await supabase.rpc("get_my_context");
      if (cancelled) return;
      if (rpcError) {
        setError(rpcError.message);
      } else {
        setProfile(data.profile);
        setPositions(data.positions ?? []);
      }
      setLoading(false);
    }

    loadContext();
    return () => {
      cancelled = true;
    };
  }, []);

  const signOut = useCallback(async () => {
    await supabase.auth.signOut();
    router.replace("/login");
    router.refresh();
  }, [router]);

  return (
    <UserContext.Provider value={{ profile, positions, loading, error, signOut }}>
      {children}
    </UserContext.Provider>
  );
}

export function useUser() {
  const ctx = useContext(UserContext);
  if (!ctx) throw new Error("useUser must be used inside <UserProvider>");
  return ctx;
}
