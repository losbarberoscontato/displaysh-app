"use client";

import { AlertTriangle, CalendarDays, Check, CircleX, CreditCard, History, LoaderCircle, MessageCircle, RefreshCw, RotateCcw, X } from "lucide-react";
import Link from "next/link";
import { useCallback, useEffect, useMemo, useState } from "react";
import {
  cancelAppointment,
  createMercadoPagoCheckout,
  getClientManagerNotificationPhone,
  getAvailableSlots,
  getMyAppointments,
  rescheduleAppointment,
  rescheduleFixedSubscriptionSession,
  toClientError,
} from "@/components/connected-client/api";
import { useConnectedClient } from "@/components/connected-client/context";
import {
  barberSupportsServices,
  bookingSelection,
  canCustomerReschedule,
  addCalendarDays,
  catalogChoices,
  dateOptions,
  formatInstant,
  formatLocalDate,
  formatMoney,
  formatSlotTime,
  localDateForInstant,
  localToday,
  parsePostgresRange,
  selectionsFromAppointmentItems,
  serviceIdsForChoice,
} from "@/components/connected-client/format";
import { AuthPrompt, ConnectedClientGate } from "@/components/connected-client/state";
import type { AvailableSlot, CustomerAppointment } from "@/components/connected-client/types";
import styles from "@/components/connected-client/connected-client.module.css";
import { getSupabaseBrowserClient } from "@/lib/supabase/browser";
import { clientVocabulary } from "@/components/connected-client/vocabulary";

const statusLabels: Record<CustomerAppointment["status"], string> = {
  HELD: "Horário protegido",
  PENDING_PAYMENT: "Pagamento pendente",
  CONFIRMED: "Confirmado",
  IN_SERVICE: "Em atendimento",
  COMPLETED: "Concluído",
  CANCELED: "Cancelado",
  NO_SHOW: "Não compareceu",
  EXPIRED: "Expirado",
};

function rescheduleDatesFor(appointment: CustomerAppointment, timezone: string): string[] {
  if (!appointment.subscription_session_id || appointment.subscription_scheduling_mode !== "FIXED") {
    return dateOptions(timezone, 10);
  }
  const originalStart = appointment.subscription_reschedule_original_starts_at
    ?? parsePostgresRange(appointment.service_period).startsAt;
  const originalDate = localDateForInstant(originalStart, timezone);
  const firstDate = [localToday(timezone), addCalendarDays(originalDate, -14)]
    .sort()
    .at(-1) ?? localToday(timezone);
  const lastDate = addCalendarDays(originalDate, 14);
  if (firstDate > lastDate) return [];
  const dates: string[] = [];
  for (let date = firstDate; date <= lastDate; date = addCalendarDays(date, 1)) dates.push(date);
  return dates;
}

function appointmentStatusLabel(appointment: CustomerAppointment): string {
  if (appointment.status === "CANCELED") {
    if (appointment.cancellation_outcome === "ON_TIME") return "Cancelado no prazo";
    if (appointment.cancellation_outcome === "AFTER_DEADLINE") return "Cancelado após o prazo";
    return "Cancelado";
  }
  if (appointment.status === "NO_SHOW" && appointment.subscription_session_id) return "Cancelado após o prazo";
  if (appointment.status === "CONFIRMED") {
    if (appointment.whatsapp_response_status === "CONFIRMED_MANUALLY") return "Confirmado Manualmente";
    if (appointment.whatsapp_response_status === "CONFIRMED_BY_WHATSAPP") return "Confirmado";
    return "Agendado";
  }
  return statusLabels[appointment.status];
}

function upcomingAppointments(appointments: CustomerAppointment[], now: number): CustomerAppointment[] {
  return appointments.filter((appointment) => {
    const { startsAt } = parsePostgresRange(appointment.service_period);
    return new Date(startsAt).getTime() >= now
      && ["HELD", "PENDING_PAYMENT", "CONFIRMED", "IN_SERVICE"].includes(appointment.status);
  }).sort((a, b) => new Date(parsePostgresRange(a.service_period).startsAt).getTime()
    - new Date(parsePostgresRange(b.service_period).startsAt).getTime());
}

export function ConnectedReservations() {
  return <ConnectedClientGate><ReservationsContent /></ConnectedClientGate>;
}

function ReservationsContent() {
  const { context, slug, user, customer, authLoading, identity, entry } = useConnectedClient();
  const vocabulary = clientVocabulary(identity, entry?.product_key);
  const supabase = useMemo(() => getSupabaseBrowserClient(), []);
  const [appointments, setAppointments] = useState<CustomerAppointment[]>([]);
  const [managerNotificationPhone, setManagerNotificationPhone] = useState<string | null>(null);
  const [loading, setLoading] = useState(true);
  const [error, setError] = useState("");
  const [notice, setNotice] = useState("");
  const [loadedAt] = useState(() => Date.now());
  const [cancelTarget, setCancelTarget] = useState<CustomerAppointment | null>(null);
  const [cancelBeforeDeadline, setCancelBeforeDeadline] = useState(false);
  const [cancelReason, setCancelReason] = useState("");
  const [cancelAcknowledged, setCancelAcknowledged] = useState(false);
  const [rescheduleTarget, setRescheduleTarget] = useState<CustomerAppointment | null>(null);
  const [currentTime, setCurrentTime] = useState(() => Date.now());
  const [barberId, setBarberId] = useState("");
  const [localDate, setLocalDate] = useState("");
  const [startsAt, setStartsAt] = useState("");
  const [rescheduleChoiceId, setRescheduleChoiceId] = useState("");
  const [slots, setSlots] = useState<AvailableSlot[]>([]);
  const [slotsLoading, setSlotsLoading] = useState(false);
  const [mutationBusy, setMutationBusy] = useState(false);
  const [paymentBusyId, setPaymentBusyId] = useState("");
  const [modalError, setModalError] = useState("");
  const rescheduleChoice = useMemo(
    () => context ? catalogChoices(context).find((choice) => choice.id === rescheduleChoiceId) ?? null : null,
    [context, rescheduleChoiceId],
  );
  const requiredServiceIds = useMemo(() => {
    if (!context || !rescheduleTarget) return [];
    if (rescheduleChoice) return serviceIdsForChoice(context, rescheduleChoice);
    return [...new Set(rescheduleTarget.items.map((item) => item.service_id))];
  }, [context, rescheduleChoice, rescheduleTarget]);
  const compatibleBarbers = useMemo(
    () => context?.barbers.filter((barber) => {
      if (rescheduleTarget?.subscription_session_id && rescheduleTarget.subscription_scheduling_mode === "FIXED") {
        return barberSupportsServices(requiredServiceIds, barber.service_ids)
          && (!rescheduleTarget.subscription_plan_id
            || !barber.subscription_plan_ids
            || barber.subscription_plan_ids.includes(rescheduleTarget.subscription_plan_id));
      }
      if (!barberSupportsServices(requiredServiceIds, barber.service_ids)) return false;
      const packageId = rescheduleChoice?.kind === "PACKAGE"
        ? rescheduleChoice.id
        : rescheduleTarget?.items.find((item) => item.package_id)?.package_id;
      return !packageId || barber.package_ids === undefined || barber.package_ids.includes(packageId);
    }) ?? [],
    [context, requiredServiceIds, rescheduleChoice, rescheduleTarget],
  );

  useEffect(() => {
    if (barberId && !compatibleBarbers.some((barber) => barber.id === barberId)) {
      queueMicrotask(() => setBarberId(""));
    }
  }, [barberId, compatibleBarbers]);

  useEffect(() => {
    if (!rescheduleTarget) return;
    const refreshCurrentTime = () => setCurrentTime(Date.now());
    const timeoutId = window.setTimeout(refreshCurrentTime, 0);
    const intervalId = window.setInterval(() => setCurrentTime(Date.now()), 15_000);
    return () => {
      window.clearTimeout(timeoutId);
      window.clearInterval(intervalId);
    };
  }, [rescheduleTarget]);

  const load = useCallback(async () => {
    if (!supabase || !context || !customer) {
      setAppointments([]);
      setManagerNotificationPhone(null);
      setLoading(false);
      return;
    }
    setLoading(true);
    setError("");
    try {
      const [loadedAppointments, notificationPhone] = await Promise.all([
        getMyAppointments(supabase, context.organization.id, customer.id, context.organization.timezone),
        getClientManagerNotificationPhone(supabase, context.organization.id).catch(() => null),
      ]);
      setManagerNotificationPhone(notificationPhone);
      setAppointments(loadedAppointments);
    } catch (cause: unknown) {
      setError(toClientError(cause, "Não foi possível carregar reservas."));
    } finally {
      setLoading(false);
    }
  }, [context, customer, loadedAt, supabase]);

  useEffect(() => {
    let active = true;
    queueMicrotask(() => { if (active) void load(); });
    return () => { active = false; };
  }, [load]);
  useEffect(() => {
    queueMicrotask(() => {
      const payment = new URLSearchParams(window.location.search).get("payment");
      if (payment === "approved") setNotice("Pagamento retornou como aprovado. Webhook assinado ainda confirma reserva.");
      if (payment === "pending") setNotice("Pagamento está pendente. Reserva atualiza após webhook do Mercado Pago.");
      if (payment === "failed") setNotice("Pagamento não concluiu. Hold expira automaticamente se não houver captura.");
    });
  }, []);

  useEffect(() => {
    if (!supabase || !context || !slug || !rescheduleTarget || !barberId || !localDate) {
      queueMicrotask(() => setSlots([]));
      return;
    }
    const selections = rescheduleChoice ? bookingSelection(rescheduleChoice) : selectionsFromAppointmentItems(rescheduleTarget.items);
    if (!selections.length) {
      queueMicrotask(() => setModalError("Itens da reserva não permitem consulta de novos horários."));
      return;
    }
    let active = true;
    queueMicrotask(() => {
      if (!active) return;
      setSlotsLoading(true);
      setModalError("");
      setStartsAt("");
    });
    void getAvailableSlots(supabase, {
      organizationSlug: slug,
      barberId,
      localDate,
      selections,
    }).then((result) => {
      if (active) setSlots(result?.slots ?? []);
    }).catch((cause: unknown) => {
      if (active) setModalError(toClientError(cause, "Não foi possível consultar agenda."));
    }).finally(() => {
      if (active) setSlotsLoading(false);
    });
    return () => { active = false; };
  }, [barberId, context, localDate, rescheduleChoice, rescheduleTarget, slug, supabase]);

  if (!context || !slug) return null;
  const tenantSlug = slug;
  const tenantContext = context;
  if (authLoading) return <div className={styles.state} role="status"><LoaderCircle className={styles.spin} /> Validando sessão…</div>;
  if (!user) return <AuthPrompt description="Entre para ver somente reservas vinculadas à sua identidade." />;
  if (!customer && !loading) {
    return <section className={styles.emptyPage}><CalendarDays size={30} /><h1>Ainda sem perfil neste estabelecimento</h1><p>Seu perfil neste estabelecimento aparecerá após a primeira reserva confirmada.</p><Link className={styles.primaryButton} href={`/cliente/agendar?barbearia=${encodeURIComponent(slug)}`}>Agendar horário</Link></section>;
  }

  const upcoming = upcomingAppointments(appointments, loadedAt);
  const nextAppointments = upcoming.slice(0, 2);
  const history = appointments.filter((appointment) => !upcoming.some((item) => item.id === appointment.id));
  const timezone = context.organization.timezone;
  const acceptingBookings = context.organization.accepting_bookings;
  const rescheduleDates = rescheduleTarget ? rescheduleDatesFor(rescheduleTarget, timezone) : [];

  async function performCancel() {
    if (!supabase || !cancelTarget) return;
    const { startsAt } = parsePostgresRange(cancelTarget.service_period);
    const beforeDeadline = cancelTarget.cancellation_lead_minutes_snapshot === 0 || Date.now() <= new Date(startsAt).getTime() - cancelTarget.cancellation_lead_minutes_snapshot * 60_000;
    if (!beforeDeadline && !cancelAcknowledged) return;
    setMutationBusy(true);
    setModalError("");
    try {
      const result = await cancelAppointment(supabase, cancelTarget.id, cancelReason || "customer_requested");
      setNotice(result.refund_amount_cents > 0
        ? `Reserva cancelada. Reembolso de ${formatMoney(result.refund_amount_cents, cancelTarget.currency)} entrou na fila.`
        : "Reserva cancelada. Nenhum valor reembolsável calculado.");
      setCancelTarget(null);
      setCancelReason("");
      await load();
    } catch (cause: unknown) {
      setModalError(toClientError(cause, "Não foi possível cancelar reserva."));
    } finally {
      setMutationBusy(false);
    }
  }

  function openReschedule(appointment: CustomerAppointment) {
    const { startsAt: currentStart } = parsePostgresRange(appointment.service_period);
    if (appointment.subscription_session_id && appointment.subscription_scheduling_mode !== "FIXED") return;
    if (appointment.subscription_has_overdue_installment) {
      setNotice("Há parcela vencida neste plano. Regularize o pagamento antes de reagendar a sessão.");
      return;
    }
    const dates = rescheduleDatesFor(appointment, timezone);
    const currentDate = localDateForInstant(currentStart, timezone);
    setRescheduleTarget(appointment);
    setBarberId(appointment.barber_id);
    setLocalDate(dates.includes(currentDate) ? currentDate : dates[0] ?? "");
    setStartsAt("");
    setRescheduleChoiceId("");
    setModalError("");
    const rescheduleLeadMinutes = appointment.subscription_scheduling_mode === "FIXED" ? 0 : appointment.cancellation_lead_minutes_snapshot;
    if (!canCustomerReschedule(appointment.status, currentStart, rescheduleLeadMinutes, acceptingBookings)) {
      setModalError("Reserva fora do prazo ou estabelecimento pausou novos horários.");
    }
  }

  async function performReschedule() {
    if (!supabase || !rescheduleTarget || !startsAt || !barberId) return;
    setMutationBusy(true);
    setModalError("");
    try {
      if (rescheduleTarget.subscription_session_id && rescheduleTarget.subscription_scheduling_mode === "FIXED") {
        await rescheduleFixedSubscriptionSession(supabase, {
          organizationId: tenantContext.organization.id,
          subscriptionSessionId: rescheduleTarget.subscription_session_id,
          barberId,
          startsAt,
        });
        setNotice("Sessão do plano reagendada com sucesso.");
      } else {
        const replacement = catalogChoices(tenantContext).find((choice) => choice.id === rescheduleChoiceId);
        await rescheduleAppointment(supabase, {
          appointmentId: rescheduleTarget.id,
          barberId,
          startsAt,
          selections: replacement ? bookingSelection(replacement) : null,
        });
        setNotice(replacement
          ? "Reserva reagendada. Novo item usou catálogo atual; diferença financeira ficou registrada."
          : "Reserva reagendada com sucesso.");
      }
      setRescheduleTarget(null);
      await load();
    } catch (cause: unknown) {
      setModalError(toClientError(cause, "Não foi possível reagendar. Reserva original continua intacta."));
    } finally {
      setMutationBusy(false);
    }
  }

  async function resumePayment(appointment: CustomerAppointment) {
    if (!supabase || !appointment.pending_payment_order_id) return;
    setPaymentBusyId(appointment.id);
    setError("");
    try {
      const checkoutUrl = await createMercadoPagoCheckout(
        supabase,
        appointment.pending_payment_order_id,
        `mp-resume:${crypto.randomUUID()}`,
      );
      window.localStorage.setItem("los-barberos:client-tenant", tenantSlug);
      window.location.assign(checkoutUrl);
    } catch (cause: unknown) {
      setError(toClientError(cause, "Não foi possível retomar pagamento."));
    } finally {
      setPaymentBusyId("");
    }
  }

  return (
    <div className={styles.reservations}>
      <header className={styles.pageHeading}><h1>Minhas reservas</h1></header>
      {notice && <div className={styles.notice} role="status"><Check size={17} /><span>{notice}</span><button type="button" onClick={() => setNotice("")} aria-label="Fechar aviso"><X size={15} /></button></div>}
      {error && <div className={styles.errorBox} role="alert"><strong>Falha ao carregar</strong><span>{error}</span><button type="button" onClick={() => void load()}><RefreshCw size={15} /> Tentar novamente</button></div>}
      {loading ? <div className={styles.state} role="status"><LoaderCircle className={styles.spin} /> Carregando reservas…</div> : (
        <>
          <section className={styles.reservationSection}>
            <div className={styles.sectionTitle}><CalendarDays /><div><h2>Próximas</h2><p>{nextAppointments.length} agendamento(s)</p></div></div>
            {!nextAppointments.length ? <div className={styles.empty}><p>Nenhuma reserva futura.</p><Link href={`/cliente/agendar?barbearia=${encodeURIComponent(slug)}`} className={styles.primaryButton}>Agendar horário</Link></div> : (
              <div className={styles.reservationTableWrap}>
                <table className={styles.reservationTable}>
                  <thead><tr><th scope="col">Data/hora</th><th scope="col">Serviço/tipo</th><th scope="col">Profissional/estabelecimento</th><th scope="col" aria-label="Ações" /></tr></thead>
                  <tbody>{nextAppointments.map((appointment) => {
                    const { startsAt: sessionStart } = parsePostgresRange(appointment.service_period);
                    const serviceName = appointment.items.map((item) => item.service_name_snapshot).join(" + ") || "Reserva";
                    const barberName = context.barbers.find((item) => item.id === appointment.barber_id)?.name ?? vocabulary.professionalLabel;
                    const sessionWeekday = formatInstant(sessionStart, timezone, {
                      weekday: "long",
                      dateStyle: undefined,
                      timeStyle: undefined,
                    }).replace(/-feira$/u, "");
                    const sessionDate = formatInstant(sessionStart, timezone, { dateStyle: "short", timeStyle: undefined });
                    const sessionTime = formatInstant(sessionStart, timezone, { dateStyle: undefined, timeStyle: "short" });
                    const sessionDateTime = formatInstant(sessionStart, timezone, { dateStyle: "full", timeStyle: "short" });
                    const managerPhone = managerNotificationPhone?.replace(/\D/gu, "");
                    const whatsappHref = managerPhone
                      ? `https://wa.me/${managerPhone}?text=${encodeURIComponent(`Sessão: ${sessionDateTime}, Cliente: ${customer?.full_name ?? "Cliente"}. Gostaria de algumas informações sobre este atendimento`)}`
                      : null;
                    const canCancel = ["HELD", "PENDING_PAYMENT", "CONFIRMED"].includes(appointment.status);
                    const canResumePayment = appointment.status === "PENDING_PAYMENT" && Boolean(appointment.pending_payment_order_id);
                    const canRescheduleFixed = Boolean(appointment.subscription_session_id)
                      && appointment.subscription_scheduling_mode === "FIXED"
                      && !appointment.subscription_has_overdue_installment
                      && canCustomerReschedule(appointment.status, sessionStart, 0, context.organization.accepting_bookings);
                    return <tr key={appointment.id}>
                      <td><time dateTime={sessionStart}><span>{sessionWeekday}</span><span>{sessionDate}</span><span>{sessionTime}</span></time></td>
                      <td><strong>{serviceName}</strong><small>{appointment.payment_mode === "SUBSCRIPTION" || appointment.subscription_session_id ? "Assinatura" : "Avulso"}</small></td>
                      <td><strong>{barberName}</strong><small>{context.organization.name}</small></td>
                      <td><div className={styles.reservationActions}>
                        {canCancel && <button type="button" className={`${styles.reservationAction} ${styles.reservationCancelAction}`} onClick={() => { const { startsAt } = parsePostgresRange(appointment.service_period); const leadMinutes = appointment.cancellation_lead_minutes_snapshot ?? 0; setCancelTarget(appointment); setCancelBeforeDeadline(leadMinutes === 0 || Date.now() <= new Date(startsAt).getTime() - leadMinutes * 60_000); setCancelAcknowledged(false); setModalError(""); }} aria-label={`Cancelar ${serviceName}`} title="Cancelar"><CircleX size={18} aria-hidden="true" /></button>}
                        {whatsappHref ? <a className={`${styles.reservationAction} ${styles.reservationWhatsAppAction}`} href={whatsappHref} target="_blank" rel="noopener noreferrer" aria-label={`Falar no WhatsApp sobre ${serviceName}`} title="WhatsApp"><MessageCircle size={18} aria-hidden="true" /></a> : <button type="button" className={`${styles.reservationAction} ${styles.reservationWhatsAppAction}`} disabled aria-label="WhatsApp de avisos do gestor não configurado" title="WhatsApp de avisos do gestor não configurado"><MessageCircle size={18} aria-hidden="true" /></button>}
                      {canRescheduleFixed && <button type="button" className={styles.reservationAction} onClick={() => openReschedule(appointment)} aria-label={`Reagendar ${serviceName}`} title="Reagendar"><RotateCcw size={18} aria-hidden="true" /></button>}
                        {canResumePayment && <button type="button" className={styles.reservationAction} disabled={paymentBusyId === appointment.id} onClick={() => void resumePayment(appointment)} aria-label="Retomar pagamento" title="Retomar pagamento"><CreditCard size={18} aria-hidden="true" /></button>}
                      </div></td>
                    </tr>;
                  })}</tbody>
                </table>
              </div>
            )}
          </section>
          <section className={styles.reservationSection}>
            <div className={styles.sectionTitle}><History /><div><h2>Histórico</h2><p>{vocabulary.servicesLabel} e reservas encerradas</p></div></div>
            {!history.length ? <p className={styles.empty}>Histórico vazio.</p> : <div className={styles.history}>{history.map((appointment) => {
              const { startsAt: start } = parsePostgresRange(appointment.service_period);
              return <article key={appointment.id}><span>{formatInstant(start, timezone, { dateStyle: "short", timeStyle: undefined })}</span><div><strong>{appointment.items.map((item) => item.service_name_snapshot).join(" + ") || "Reserva"}</strong><small>{context.barbers.find((item) => item.id === appointment.barber_id)?.name ?? vocabulary.professionalLabel}</small></div><b data-status={appointment.status}>{appointmentStatusLabel(appointment)}</b><em>{appointment.payment_mode === "SUBSCRIPTION" ? "Sessão assinatura" : formatMoney(appointment.total_cents_snapshot, appointment.currency)}</em></article>;
            })}</div>}
          </section>
        </>
      )}

      {cancelTarget && <div className={styles.modalLayer} role="presentation"><button type="button" className={styles.backdrop} onClick={() => setCancelTarget(null)} aria-label="Fechar cancelamento" /><section className={styles.modal} role="dialog" aria-modal="true" aria-labelledby="cancel-title"><button type="button" className={styles.modalClose} onClick={() => setCancelTarget(null)} aria-label="Fechar"><X /></button><AlertTriangle className={styles.warning} /><h2 id="cancel-title">Cancelar reserva?</h2>{cancelBeforeDeadline ? <p>Cancelamento dentro do prazo devolve a sessão para <strong>Em aberto</strong>. Você poderá agendar novamente.</p> : <><p>O cancelamento após o prazo limite encerrará esta sessão. Você não poderá reagendar.</p><label style={{ display: "flex", alignItems: "center", gap: 8 }}><input type="checkbox" checked={cancelAcknowledged} onChange={(event) => setCancelAcknowledged(event.target.checked)} /><span>Estou ciente</span></label></>}<label>Motivo <small>opcional</small><select value={cancelReason} onChange={(event) => setCancelReason(event.target.value)}><option value="">Selecione</option><option value="personal_unforeseen">Imprevisto pessoal</option><option value="need_another_time">Preciso de outro horário</option><option value="other">Outro</option></select></label>{modalError && <p className={styles.error} role="alert">{modalError}</p>}<footer><button type="button" className={styles.secondaryButton} onClick={() => setCancelTarget(null)}>Manter reserva</button><button type="button" className={styles.dangerButton} disabled={mutationBusy} onClick={() => void performCancel()}>{mutationBusy ? "Cancelando…" : "Confirmar cancelamento da sessão"}</button></footer></section></div>}

      {rescheduleTarget && <div className={styles.modalLayer} role="presentation">
        <button type="button" className={styles.backdrop} onClick={() => setRescheduleTarget(null)} aria-label="Fechar reagendamento" />
        <section className={`${styles.modal} ${styles.modalWide}`} role="dialog" aria-modal="true" aria-labelledby="reschedule-title">
          <button type="button" className={styles.modalClose} onClick={() => setRescheduleTarget(null)} aria-label="Fechar"><X /></button>
          <RotateCcw className={styles.rescheduleIcon} />
          <h2 id="reschedule-title">Reagendar {rescheduleTarget.subscription_session_id ? "sessão do plano" : "reserva"}</h2>
          <p>{rescheduleTarget.subscription_scheduling_mode === "FIXED"
            ? "Escolha profissional, data e horário livre. Reagendamento permitido entre 2 semanas antes e 2 semanas depois da data original da sessão."
            : "Escolha um novo horário. Sua reserva atual será mantida se a alteração não for concluída."}</p>
          {!(rescheduleTarget.subscription_session_id && rescheduleTarget.subscription_scheduling_mode === "FIXED") && <fieldset className={styles.rescheduleCatalog}>
            <legend>{vocabulary.serviceLabel} ou pacote</legend>
            <button type="button" className={!rescheduleChoiceId ? styles.selected : undefined} onClick={() => setRescheduleChoiceId("")}><strong>Manter itens atuais</strong><small>{rescheduleTarget.items.map((item) => item.service_name_snapshot).join(" + ")}</small></button>
            {catalogChoices(context).map((choice) => <button type="button" key={choice.id} className={rescheduleChoiceId === choice.id ? styles.selected : undefined} onClick={() => setRescheduleChoiceId(choice.id)}><strong>{choice.name}</strong><small>{formatMoney(choice.priceCents, context.organization.currency)}</small></button>)}
          </fieldset>}
          <label>{vocabulary.professionalLabel}
            <select value={barberId} onChange={(event) => { setBarberId(event.target.value); setStartsAt(""); }}>
              <option value="">Selecione</option>{compatibleBarbers.map((item) => <option key={item.id} value={item.id}>{item.name}</option>)}
            </select>
          </label>
          {compatibleBarbers.length === 0 && <p className={styles.empty}>Nenhum profissional habilitado para esta seleção.</p>}
          <div className={styles.dates}>{rescheduleDates.map((date) => <button type="button" key={date} className={localDate === date ? styles.selected : undefined} onClick={() => { setLocalDate(date); setStartsAt(""); }}><small>{formatLocalDate(date, { weekday: "short" })}</small><strong>{date.slice(-2)}</strong></button>)}</div>
          {rescheduleTarget.subscription_scheduling_mode === "FIXED" && rescheduleDates.length === 0 && <p className={styles.error} role="alert">Não há datas futuras dentro do limite de 2 semanas da sessão original.</p>}
          {slotsLoading ? <p className={styles.loadingLine}><LoaderCircle className={styles.spin} /> Consultando horários…</p> : <div className={styles.slots}>{slots.filter((slot) => new Date(slot.starts_at).getTime() > currentTime).map((slot) => <button type="button" key={slot.starts_at} className={startsAt === slot.starts_at ? styles.selected : undefined} onClick={() => setStartsAt(slot.starts_at)}>{formatSlotTime(slot.starts_at, timezone)}</button>)}</div>}
          {!slotsLoading && barberId && localDate && !slots.some((slot) => new Date(slot.starts_at).getTime() > currentTime) && !modalError && <p className={styles.empty}>Nenhum horário disponível nesta data. Confira a escala, bloqueios e atendimentos já marcados para o profissional.</p>}
          {modalError && <p className={styles.error} role="alert">{modalError}</p>}
          <footer><button type="button" className={styles.secondaryButton} onClick={() => setRescheduleTarget(null)}>Voltar</button><button type="button" className={styles.primaryButton} disabled={!startsAt || !barberId || mutationBusy || Boolean(modalError)} onClick={() => void performReschedule()}>{mutationBusy ? "Reagendando…" : "Confirmar novo horário"}</button></footer>
        </section>
      </div>}
    </div>
  );
}
