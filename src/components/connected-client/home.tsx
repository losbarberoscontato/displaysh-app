"use client";

import Link from "next/link";
import { CalendarPlus2 } from "lucide-react";
import { useEffect, useMemo, useState } from "react";
import { useConnectedClient } from "@/components/connected-client/context";
import { formatInstant, formatMoney, parsePostgresRange } from "@/components/connected-client/format";
import { getNextMyAppointment, toClientError } from "@/components/connected-client/api";
import { ConnectedClientGate } from "@/components/connected-client/state";
import type { NextCustomerAppointment } from "@/components/connected-client/types";
import styles from "@/components/connected-client/connected-client.module.css";
import { clientVocabulary } from "@/components/connected-client/vocabulary";
import { getSupabaseBrowserClient } from "@/lib/supabase/browser";

export function ConnectedClientHome() {
  return <ConnectedClientGate><HomeContent /></ConnectedClientGate>;
}

function HomeContent() {
  const { context, slug, user, customer, authLoading, identity, entry } = useConnectedClient();
  const vocabulary = clientVocabulary(identity, entry?.product_key);
  const supabase = useMemo(() => getSupabaseBrowserClient(), []);
  const requestKey = supabase && context && customer && user
    ? `${context.organization.id}:${customer.id}:${user.id}`
    : null;
  const [appointmentResult, setAppointmentResult] = useState<{
    key: string;
    next: NextCustomerAppointment | null;
    error: string;
  } | null>(null);

  useEffect(() => {
    if (!requestKey || !supabase || !context || !customer) return;
    let active = true;
    void getNextMyAppointment(supabase, context.organization.id, customer.id)
      .then((next) => {
        if (active) setAppointmentResult({ key: requestKey, next, error: "" });
      })
      .catch((cause: unknown) => {
        if (active) setAppointmentResult({
          key: requestKey,
          next: null,
          error: toClientError(cause, "Não foi possível carregar o próximo atendimento."),
        });
      });

    return () => { active = false; };
  }, [context, customer, requestKey, supabase]);

  if (!context || !slug) return null;

  const currentResult = appointmentResult?.key === requestKey ? appointmentResult : null;
  const appointmentsLoading = Boolean(requestKey && !currentResult);
  const appointmentsError = currentResult?.error ?? "";
  const nextAppointment = currentResult?.next ?? null;
  const bookingHref = `/cliente/agendar?barbearia=${encodeURIComponent(slug)}`;
  return (
    <section className={styles.clientHome} aria-label="Agendar atendimento">
      <div className={styles.homeHero}>
        <Link className={`${styles.primaryButton} ${styles.homeBookButton}`} href={bookingHref}>
          <CalendarPlus2 size={20} aria-hidden="true" /> Agendar
        </Link>
      </div>

      <section className={styles.homePanel} aria-label="Próximo atendimento">
        <span>Próximo atendimento</span>
        {authLoading || appointmentsLoading ? (
          <p role="status">Carregando atendimento…</p>
        ) : appointmentsError ? (
          <p role="alert">{appointmentsError}</p>
        ) : !user ? (
          <p><Link href={`/cliente/entrar?barbearia=${encodeURIComponent(slug)}`}>Entre para consultar seu próximo atendimento.</Link></p>
        ) : nextAppointment ? (
          <div className={styles.nextAppointmentTableWrap}>
            <table className={styles.nextAppointmentTable}>
              <thead><tr><th>Data/Hora</th><th>Serviço/Profissional</th><th>Valor</th></tr></thead>
              <tbody>
                <tr>
                  <td>{formatInstant(parsePostgresRange(nextAppointment.service_period).startsAt, context.organization.timezone, { dateStyle: "short", timeStyle: "short" })}</td>
                  <td>
                    <strong>{nextAppointment.items.map((item) => item.service_name_snapshot).join(" + ") || vocabulary.service}</strong>
                    <small>{context.barbers.find((barber) => barber.id === nextAppointment.barber_id)?.name ?? vocabulary.professional}</small>
                  </td>
                  <td>{nextAppointment.payment_mode === "SUBSCRIPTION"
                    ? `Incluíd${vocabulary.serviceArticle === "a" ? "a" : "o"} no plano`
                    : formatMoney(nextAppointment.total_cents_snapshot, nextAppointment.currency)}</td>
                </tr>
              </tbody>
            </table>
          </div>
        ) : (
          <strong>Nenhum horário futuro confirmado</strong>
        )}
      </section>
    </section>
  );
}
