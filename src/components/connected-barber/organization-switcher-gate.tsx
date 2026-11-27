"use client";

import { useEffect, useRef, useState } from "react";
import { useRouter } from "next/navigation";
import { barberSwitcherEntryStorageKey } from "@/lib/barber-switcher-entry";
import styles from "./access.module.css";

export function OrganizationSwitcherGate({
  allowedOrganizationSlugs,
  children,
}: {
  allowedOrganizationSlugs: string[];
  children: React.ReactNode;
}) {
  const router = useRouter();
  const [authorized, setAuthorized] = useState(false);
  const checkedRef = useRef(false);

  useEffect(() => {
    if (checkedRef.current) return;
    checkedRef.current = true;
    let sourceSlug: string | null = null;
    try {
      sourceSlug = window.sessionStorage.getItem(barberSwitcherEntryStorageKey);
      window.sessionStorage.removeItem(barberSwitcherEntryStorageKey);
    } catch {
      sourceSlug = null;
    }

    if (sourceSlug && allowedOrganizationSlugs.includes(sourceSlug)) {
      queueMicrotask(() => setAuthorized(true));
      return;
    }

    router.replace("/barbeiro/entrar");
  }, [allowedOrganizationSlugs, router]);

  if (!authorized) {
    return <main className={styles.switcherLoading} role="status" aria-label="Validando acesso">Carregando…</main>;
  }

  return children;
}
