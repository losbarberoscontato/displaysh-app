import { redirect } from "next/navigation";
import { BarberAgenda } from "@/components/connected-barber/agenda";
import { BarberShell } from "@/components/connected-barber/barber-shell";
import { loadBarberAgenda } from "@/lib/barber-server";

export default async function BarberAgendaPage({ searchParams }: { searchParams: Promise<{ barbearia?: string; data?: string }> }) {
  const params = await searchParams;
  if (!params.barbearia) redirect("/barbeiro");
  const requestedDate = params.data;
  const parsedDate = requestedDate && /^\d{4}-\d{2}-\d{2}$/u.test(requestedDate) ? new Date(`${requestedDate}T12:00:00.000Z`) : null;
  const date = parsedDate && !Number.isNaN(parsedDate.getTime()) && parsedDate.toISOString().slice(0, 10) === requestedDate ? requestedDate : null;
  const data = await loadBarberAgenda(params.barbearia, date);
  if (!data) redirect("/barbeiro");
  return <BarberShell context={data.context}><BarberAgenda key={date ?? "today"} {...data} initialDate={date} /></BarberShell>;
}
