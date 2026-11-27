import { normalizeSafeReturnPath } from "@/lib/integrations/state";
import { normalizeTenantSlug } from "@/components/connected-client/format";

const defaultBarberDestination = "/profissional/agenda";
const barberDestinations = new Set([
  "/profissional/agenda",
  "/barbeiro",
  "/barbeiro/agenda",
  "/barbeiro/caixa",
  "/barbeiro/financeiro",
  "/barbeiro/perfil",
  "/barbeiro/perfil/dados-pessoais",
  "/barbeiro/escala",
  "/barbeiro/escala/folgas",
  "/barbeiro/escala/historico",
  "/barbeiro/escala/nova-folga",
]);

export function barberAuthDestination(input: {
  next?: string | null;
  slug?: string | null;
}): string {
  const normalizedPath = normalizeSafeReturnPath(input.next, defaultBarberDestination);
  const destination = new URL(normalizedPath, "https://barbeiro.local");
  const pathname = barberDestinations.has(destination.pathname)
    ? destination.pathname
    : defaultBarberDestination;
  const slug = normalizeTenantSlug(input.slug);
  return slug ? `${pathname}?barbearia=${encodeURIComponent(slug)}` : pathname;
}

export function barberLoginHref(next = defaultBarberDestination, slug?: string | null): string {
  const destination = barberAuthDestination({ next, slug });
  const url = new URL(destination, "https://barbeiro.local");
  const nextPath = url.pathname === "/barbeiro" || url.pathname === "/barbeiro/agenda"
    ? "/profissional/agenda"
    : url.pathname;
  const params = new URLSearchParams({ next: nextPath });
  const normalizedSlug = url.searchParams.get("barbearia");
  if (normalizedSlug) params.set("barbearia", normalizedSlug);
  return `/profissional/entrar?${params.toString()}`;
}
