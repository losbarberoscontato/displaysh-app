import type { Metadata } from "next";
import { redirect } from "next/navigation";
import { BillingRegularization } from "@/components/billing-regularization";
import { getAccessContext } from "@/lib/auth/context";
import { hasSupabaseConfig } from "@/lib/env";
import { getSupabaseServerClient } from "@/lib/supabase/server";
import { getSelectedProductKey } from "@/lib/product-context";

export const metadata: Metadata = { title: "Regularizar pagamento" };

export default async function BillingRegularizationPage() {
  const selectedProduct = await getSelectedProductKey();
  if (selectedProduct === "le-gras") redirect("/le-gras/regularizacao");
  if (selectedProduct === "music-pro") redirect("/music-pro/regularizacao");
  if (selectedProduct === "ateliepro") redirect("/ateliepro/regularizacao");
  const context = hasSupabaseConfig ? await getAccessContext() : null;

  if (hasSupabaseConfig && !context) redirect("/entrar?next=/regularizacao");
  if (context?.role === "CLIENT") redirect("/cliente/agendar");
  if (context?.role === "PLATFORM_ADMIN" || context?.role === "UNREGISTERED") redirect("/onboarding");

  let graceEndsAt: string | null = null;
  let retentionEndsAt: string | null = null;
  if (context?.organizationId) {
    const supabase = await getSupabaseServerClient();
    const { data: subscription } = supabase
      ? await supabase.from("saas_subscriptions").select("grace_ends_at,retention_ends_at").eq("organization_id", context.organizationId).maybeSingle()
      : { data: null };
    graceEndsAt = subscription?.grace_ends_at ?? null;
    retentionEndsAt = subscription?.retention_ends_at ?? null;
  }

  return <BillingRegularization organizationId={context?.organizationId ?? null} billingStatus={context?.billingStatus ?? null} graceEndsAt={graceEndsAt} retentionEndsAt={retentionEndsAt} />;
}
