import { redirect } from "next/navigation";

export default async function BarberProjectPage({ params, searchParams }: { params: Promise<{ projectId: string }>; searchParams: Promise<{ barbearia?: string }> }) {
  await params;
  const query = await searchParams;
  if (!query.barbearia) redirect("/barbeiro");
  redirect(`/barbeiro/agenda?barbearia=${encodeURIComponent(query.barbearia)}`);
}
