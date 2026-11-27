import type { Metadata } from "next";
import { redirect } from "next/navigation";
import { BarberConnectionScreen } from "@/components/connected-barber/access";
import { OrganizationSwitcherGate } from "@/components/connected-barber/organization-switcher-gate";
import { getBarberAccessState } from "@/lib/barber-server";

export const metadata: Metadata = {
  title: { absolute: "Alterar Equipe · Display App" },
};

export default async function ProfessionalOrganizationSwitcherPage() {
  const access = await getBarberAccessState();
  if (!access) redirect("/barbeiro/entrar");
  if (!access.organizations.length) redirect("/barbeiro/entrar");
  if (access.organizations.length === 1) {
    redirect(`/barbeiro/agenda?barbearia=${encodeURIComponent(access.organizations[0].organization_slug)}`);
  }

  return (
    <OrganizationSwitcherGate
      allowedOrganizationSlugs={access.organizations.map((organization) => organization.organization_slug)}
    >
      <BarberConnectionScreen organizations={access.organizations} mode="switch" />
    </OrganizationSwitcherGate>
  );
}
