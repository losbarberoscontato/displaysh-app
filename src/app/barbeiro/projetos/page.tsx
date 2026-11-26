import { redirect } from "next/navigation";

export default async function BarberProjectsPage({ searchParams }: { searchParams: Promise<{ barbearia?: string }> }) {
  const params = await searchParams;
  if (!params.barbearia) redirect("/barbeiro");
  redirect(`/barbeiro/agenda?barbearia=${encodeURIComponent(params.barbearia)}`);
}
