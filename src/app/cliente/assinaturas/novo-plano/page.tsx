import { redirect } from "next/navigation";

export default async function CustomerNewPlanPage({ searchParams }: { searchParams: Promise<{ barbearia?: string }> }) {
  const params = await searchParams;
  const query = params.barbearia ? `?barbearia=${encodeURIComponent(params.barbearia)}` : "";
  redirect(`/cliente/assinaturas${query}`);
}
