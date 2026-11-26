import type { Metadata } from "next";
import { ConnectedSubscriptions } from "@/components/connected-client/subscriptions";
import { hasSupabaseConfig } from "@/lib/env";

export const metadata: Metadata = { title: "Detalhes do plano" };

export default async function CustomerPlanDetailsPage({ params, searchParams }: { params: Promise<{ id: string }>; searchParams: Promise<{ aba?: string }> }) {
  const [{ id }, query] = await Promise.all([params, searchParams]);
  const initialTab = query.aba === "agenda" ? "agenda" : query.aba === "contrato" ? "contrato" : "financeiro";
  return hasSupabaseConfig ? <ConnectedSubscriptions key={`${id}:${initialTab}`} view="my-plan" itemId={id} initialTab={initialTab} /> : <p>Os detalhes do plano ficarão disponíveis quando a conta estiver conectada.</p>;
}
