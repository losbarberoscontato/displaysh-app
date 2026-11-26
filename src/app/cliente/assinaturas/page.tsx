import type { Metadata } from "next";
import { ConnectedSubscriptions } from "@/components/connected-client/subscriptions";
import { hasSupabaseConfig } from "@/lib/env";

export const metadata: Metadata = { title: "Minhas Assinaturas" };

export default function CustomerSubscriptionsPage() {
  if (!hasSupabaseConfig) return <p>Minhas assinaturas ficarão disponíveis quando a conta estiver conectada.</p>;
  return <ConnectedSubscriptions view="my-plans" />;
}
