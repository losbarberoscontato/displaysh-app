import { redirect } from "next/navigation";

export default async function DisabledProjectOfferPage({ searchParams }: { params: Promise<{ id: string }>; searchParams: Promise<{ barbearia?: string }> }) {
  const params = await searchParams;
  const query = params.barbearia ? `?barbearia=${encodeURIComponent(params.barbearia)}` : "";
  redirect(`/cliente/assinaturas${query}`);
}
