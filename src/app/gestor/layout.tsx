import type { Metadata, Viewport } from "next";
import { redirect } from "next/navigation";
import { ManagerShell } from "@/components/manager-shell";
import { getAccessContext } from "@/lib/auth/context";
import { hasSupabaseConfig } from "@/lib/env";
import { getSupabaseServerClient } from "@/lib/supabase/server";
import { appointments as demoAppointments } from "@/data/demo";
import { isProductIdentityConfig, type ProductIdentityConfig } from "@/lib/product-identity";
import { getSelectedProductKey, parseProductKey, type ProductKey } from "@/lib/product-context";
import { getPublishedProductIdentity } from "@/lib/product-identity-server";
import { productLoginPath } from "@/lib/product-routes";
import { getTodayAgendaCount } from "@/lib/agenda-count";

export async function generateMetadata(): Promise<Metadata> {
  const productKey = await getSelectedProductKey();
  const productName = productKey === "ateliepro" ? "AteliePro" : productKey === "music-pro" ? "MusicPro" : productKey === "le-gras" ? "Le Gras" : productKey === "pro-stetic" ? "ProStetic" : "Los Barberos";
  return {
    title: "Painel do gestor",
    applicationName: productName,
    appleWebApp: { capable: true, title: productName, statusBarStyle: "black-translucent" },
    icons: {
      icon: productKey === "ateliepro"
        ? [{ url: "/ateliepro/mark.png", type: "image/png" }]
        : productKey === "le-gras"
        ? [{ url: "/le-gras/icon.svg", type: "image/svg+xml" }]
        : productKey === "music-pro"
        ? [{ url: "/music-pro/icon.svg", type: "image/svg+xml" }]
        : productKey === "pro-stetic"
        ? [{ url: "/pro-stetic/icon.svg", type: "image/svg+xml" }]
        : "/icon.svg",
      apple: "/icon-192.png",
    },
  };
}

export async function generateViewport(): Promise<Viewport> {
  const productKey = await getSelectedProductKey();
  return { themeColor: productKey === "ateliepro" ? "#4A3024" : productKey === "music-pro" ? "#06233b" : productKey === "le-gras" ? "#29143d" : productKey === "pro-stetic" ? "#4d245f" : "#12352e" };
}

export default async function GestorLayout({ children }: { children: React.ReactNode }) {
  let productKey: ProductKey = await getSelectedProductKey();
  const context = hasSupabaseConfig ? await getAccessContext(productKey) : null;

  if (hasSupabaseConfig && !context) redirect(`${productLoginPath(productKey)}?modo=login&next=%2Fgestor`);
  if (context?.role === "CLIENT") redirect("/cliente/agendar");
  if (context?.role === "PLATFORM_ADMIN" || context?.role === "UNREGISTERED") redirect("/onboarding");
  if (context?.billingStatus === "PROVISIONING") redirect("/onboarding");
  // Pages keep canceled tenants out of the operation. Configurações remains
  // reachable so CANCELED_RETENTION can export data; CLOSED sees it disabled.

  let organizationName = productKey === "ateliepro" ? "Seu ateliê" : productKey === "pro-stetic" ? "Seu estúdio" : productKey === "music-pro" ? "Sua escola" : productKey === "le-gras" ? "Seu estúdio" : "Sua barbearia";
  let locationName = "Unidade principal";
  let userName = "Gestor";
  let projectsModuleEnabled = false;
  let kanbanModuleEnabled = false;
  let identity: ProductIdentityConfig | undefined = await getPublishedProductIdentity(productKey) ?? undefined;
  let agendaCount = demoAppointments.filter((appointment) => appointment.date === new Intl.DateTimeFormat("en-CA").format(new Date())).length;
  if (context?.organizationId) {
    const supabase = await getSupabaseServerClient();
    if (supabase) {
      const [{ data: organization }, { data: location }, { data: profile }, { data: projectsModule }, { data: kanbanModule }, { data: assignment }] = await Promise.all([
        supabase.from("organizations").select("name,timezone").eq("id", context.organizationId).maybeSingle(),
        supabase.from("locations").select("name").eq("organization_id", context.organizationId).eq("active", true).maybeSingle(),
        supabase.from("profiles").select("display_name").eq("id", context.userId).maybeSingle(),
        supabase.from("organization_module_entitlements").select("enabled").eq("organization_id", context.organizationId).eq("module_key", "projects").maybeSingle(),
        supabase.from("organization_module_entitlements").select("enabled").eq("organization_id", context.organizationId).eq("module_key", "kanban").maybeSingle(),
        supabase.from("organization_product_assignments").select("product_key").eq("organization_id", context.organizationId).maybeSingle(),
      ]);
      if (assignment?.product_key) {
        const previousProductKey = productKey;
        productKey = parseProductKey(assignment.product_key) ?? productKey;
        if (productKey !== previousProductKey) {
          const publishedIdentity = await getPublishedProductIdentity(productKey);
          if (isProductIdentityConfig(publishedIdentity)) identity = publishedIdentity;
        }
      }
      organizationName = organization?.name ?? organizationName;
      locationName = location?.name ?? locationName;
      userName = profile?.display_name ?? userName;
      projectsModuleEnabled = Boolean(projectsModule?.enabled);
      kanbanModuleEnabled = Boolean(kanbanModule?.enabled);
      agendaCount = await getTodayAgendaCount(supabase, context.organizationId, organization?.timezone ?? "UTC");
    }
  }

  return (
    <ManagerShell agendaCount={agendaCount} organizationId={context?.organizationId} demoMode={!hasSupabaseConfig} projectsModuleEnabled={hasSupabaseConfig ? projectsModuleEnabled : true} kanbanModuleEnabled={kanbanModuleEnabled} billingBlocked={context?.billingStatus === "BLOCKED"} organizationName={hasSupabaseConfig ? organizationName : "Los Barberos"} locationName={hasSupabaseConfig ? locationName : "Vila Madalena"} userName={hasSupabaseConfig ? userName : "Guilherme Castro"} identity={identity} productKey={productKey}>
      {children}
    </ManagerShell>
  );
}
