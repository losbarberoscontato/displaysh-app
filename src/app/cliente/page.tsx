import { redirect } from "next/navigation";
import { ConnectedClientHome } from "@/components/connected-client/home";
import { clientAuthDestination } from "@/lib/client-auth";
import { hasSupabaseConfig } from "@/lib/env";

type ClientHomeSearchParams = Promise<{
  barbearia?: string | string[];
  booking?: string | string[];
  complete?: string | string[];
  erro?: string | string[];
  modo?: string | string[];
  next?: string | string[];
  oauth?: string | string[];
  slug?: string | string[];
  tenant?: string | string[];
}>;

function singleValue(value: string | string[] | undefined): string | null {
  return typeof value === "string" ? value : null;
}

export default async function CustomerHomePage({
  searchParams,
}: {
  searchParams: ClientHomeSearchParams;
}) {
  if (!hasSupabaseConfig) redirect("/cliente/agendar");

  const input = await searchParams;
  const destination = clientAuthDestination({
    next: singleValue(input.next),
    slug: singleValue(input.barbearia) ?? singleValue(input.tenant) ?? singleValue(input.slug),
    booking: singleValue(input.booking),
  });
  const resolved = new URL(destination, "https://cliente.local");

  if (resolved.pathname === "/cliente" && resolved.searchParams.has("booking")) {
    return <ConnectedClientHome />;
  }

  const query = new URLSearchParams();
  const slug = resolved.searchParams.get("barbearia");
  if (slug) query.set("barbearia", slug);
  const nextParams = new URLSearchParams(resolved.searchParams);
  nextParams.delete("barbearia");
  const nextQuery = nextParams.toString();
  query.set("next", nextQuery ? `${resolved.pathname}?${nextQuery}` : resolved.pathname);

  const mode = singleValue(input.modo);
  if (mode === "cadastro") query.set("modo", mode);
  const oauth = singleValue(input.oauth);
  if (oauth === "complete") query.set("oauth", oauth);
  if (singleValue(input.complete) === "1") query.set("complete", "1");
  if (singleValue(input.erro) === "invalid_client_context") query.set("erro", "invalid_client_context");

  redirect(`/cliente/entrar?${query.toString()}`);
}
