"use client";

import { useEffect, useMemo, useRef, useState, type FormEvent, type TouchEvent } from "react";
import { useRouter } from "next/navigation";
import {
  CalendarDays,
  CalendarPlus2,
  Check,
  ChevronDown,
  ChevronLeft,
  ChevronRight,
  CircleDollarSign,
  Clock3,
  MapPin,
  MessageCircle,
  Plus,
  Scissors,
  UserRound,
  X,
} from "lucide-react";
import { Avatar } from "@/components/ui";
import { getSupabaseBrowserClient } from "@/lib/supabase/browser";
import {
  appointmentGeometry,
  appointmentDateKey,
  buildAppointmentLayouts,
  currentTimeGeometry,
  dateKeyInTimezone,
  monthCells,
  shiftDateKey,
} from "@/components/connected-manager/agenda-calendar";
import {
  formatCents,
  formatRange,
  localDateTimeToIso,
} from "@/components/connected-manager/format";
import {
  ActionMessage,
  StatusChip,
} from "@/components/connected-manager/shared";
import type {
  BarberAppContext,
  BarberAppointment,
  BarberAppointmentItem,
  BarberCustomer,
  BarberEnvironment,
  BarberFinancialAccount,
  BarberProfessional,
  BarberService,
} from "./types";
import styles from "@/components/connected-manager/connected-manager.module.css";

type StatusFilter =
  "ALL" | "CONFIRMED" | "IN_SERVICE" | "COMPLETED" | "CANCELED" | "NO_SHOW";
const hours = Array.from(
  { length: 14 },
  (_, index) => `${String(index + 8).padStart(2, "0")}:00`,
);
const calendarWeekdays = ["S", "T", "Q", "Q", "S", "S", "D"];
const statusLabels: Record<StatusFilter, string> = {
  ALL: "Todos os status",
  CONFIRMED: "Agendado",
  IN_SERVICE: "Em serviço",
  COMPLETED: "Concluído",
  CANCELED: "Cancelado",
  NO_SHOW: "Não compareceu",
};
const paymentMethods = ["CASH", "PIX", "CARD", "BOLETO", "TRANSFER", "OTHER"];

function formatDate(
  dateKey: string,
  options: Intl.DateTimeFormatOptions = {
    day: "numeric",
    month: "long",
    year: "numeric",
  },
) {
  return new Intl.DateTimeFormat("pt-BR", {
    ...options,
    timeZone: "UTC",
  }).format(new Date(`${dateKey}T12:00:00.000Z`));
}
function formatAgendaDate(dateKey: string) {
  const parts = new Intl.DateTimeFormat("pt-BR", {
    weekday: "long",
    day: "2-digit",
    month: "2-digit",
    timeZone: "UTC",
  }).formatToParts(new Date(`${dateKey}T12:00:00.000Z`));
  const weekday = parts.find((part) => part.type === "weekday")?.value.replace("-feira", "") ?? "Dia";
  const day = parts.find((part) => part.type === "day")?.value ?? "";
  const month = parts.find((part) => part.type === "month")?.value ?? "";
  return `${weekday[0]?.toLocaleUpperCase("pt-BR")}${weekday.slice(1)} ${day}/${month}`;
}
function shiftMonth(dateKey: string, amount: number) {
  const date = new Date(`${dateKey}T12:00:00.000Z`);
  const day = date.getUTCDate();
  date.setUTCDate(1);
  date.setUTCMonth(date.getUTCMonth() + amount);
  const lastDay = new Date(
    Date.UTC(date.getUTCFullYear(), date.getUTCMonth() + 1, 0),
  ).getUTCDate();
  date.setUTCDate(Math.min(day, lastDay));
  return date.toISOString().slice(0, 10);
}
function parseCents(value: FormDataEntryValue | null) {
  return Math.round(
    Number(
      String(value ?? "")
        .replace(/[R$\s.]/g, "")
        .replace(",", "."),
    ) * 100,
  );
}
function statusDisplay(appointment: BarberAppointment) {
  if (appointment.status === "CONFIRMED")
    return { label: "Agendado", tone: "info" as const };
  if (appointment.status === "IN_SERVICE")
    return { label: "Em serviço", tone: "warning" as const };
  if (appointment.status === "COMPLETED")
    return { label: "Concluído", tone: "success" as const };
  if (appointment.status === "CANCELED")
    return { label: "Cancelado", tone: "danger" as const };
  if (appointment.status === "NO_SHOW")
    return { label: "Não compareceu", tone: "danger" as const };
  return { label: appointment.status, tone: "neutral" as const };
}

export function BarberAgenda({
  context,
  initialDate,
  appointments,
  appointmentItems,
  customers,
  services,
  professionals,
  environments,
  outstandingByAppointment,
  accounts,
  kanbanBoards = [],
  kanbanCards = [],
}: {
  context: BarberAppContext;
  initialDate?: string | null;
  appointments: BarberAppointment[];
  appointmentItems: BarberAppointmentItem[];
  customers: BarberCustomer[];
  services: BarberService[];
  professionals: BarberProfessional[];
  environments: BarberEnvironment[];
  outstandingByAppointment: Map<string, number>;
  accounts: BarberFinancialAccount[];
  kanbanBoards?: { id: string; name: string }[];
  kanbanCards?: { appointment_id: string; board_id: string }[];
}) {
  const router = useRouter();
  const timezone = context.timezone;
  const todayKey = dateKeyInTimezone(new Date(), timezone);
  const ownAgenda = context.agenda_access_scope === "OWN";
  const [message, setMessage] = useState("");
  const [date, setDate] = useState(initialDate ?? todayKey);
  const [datePickerOpen, setDatePickerOpen] = useState(false);
  const [datePickerMonth, setDatePickerMonth] = useState(todayKey);
  const datePickerRef = useRef<HTMLDivElement>(null);
  const agendaTouchStartRef = useRef<{ x: number; y: number; scrollLeft: number; maxScrollLeft: number; onTimeAxis: boolean } | null>(null);
  const [barberFilter, setBarberFilter] = useState(
    ownAgenda ? context.barber_id : "ALL",
  );
  const [status, setStatus] = useState<StatusFilter>("ALL");
  const [selected, setSelected] = useState<BarberAppointment | null>(null);
  const [newOpen, setNewOpen] = useState(false);
  const [receiptTarget, setReceiptTarget] = useState<BarberAppointment | null>(
    null,
  );
  const [customerQuery, setCustomerQuery] = useState("");
  const [selectedCustomerId, setSelectedCustomerId] = useState("");
  const [attendeeDependentId, setAttendeeDependentId] = useState("");
  const [currentTime, setCurrentTime] = useState<Date | null>(null);
  const customerById = useMemo(
    () => new Map(customers.map((item) => [item.id, item])),
    [customers],
  );
  const barberById = useMemo(
    () => new Map(professionals.map((item) => [item.id, item])),
    [professionals],
  );
  const environmentById = useMemo(
    () => new Map(environments.map((item) => [item.id, item.name])),
    [environments],
  );
  const itemsByAppointment = useMemo(() => {
    const map = new Map<string, string[]>();
    for (const item of [...appointmentItems].sort(
      (left, right) => left.position - right.position,
    ))
      map.set(item.appointment_id, [
        ...(map.get(item.appointment_id) ?? []),
        item.service_name_snapshot,
      ]);
    return map;
  }, [appointmentItems]);
  const matchingCustomers = useMemo(() => {
    const query = customerQuery.trim().toLocaleLowerCase("pt-BR");
    return query
      ? customers.filter((customer) =>
          `${customer.full_name} ${customer.phone_e164 ?? ""}`
            .toLocaleLowerCase("pt-BR")
            .includes(query),
        )
      : [];
  }, [customers, customerQuery]);
  const selectedCustomer = customerById.get(selectedCustomerId) ?? null;
  const filteredAppointments = useMemo(
    () =>
      appointments.filter(
        (appointment) =>
          (!ownAgenda || appointment.barber_id === context.barber_id) &&
          (status === "ALL" || appointment.status === status) &&
          (barberFilter === "ALL" || appointment.barber_id === barberFilter),
      ),
    [appointments, barberFilter, context.barber_id, ownAgenda, status],
  );
  const displayedBarbers = ownAgenda
    ? professionals.filter((barber) => barber.id === context.barber_id)
    : barberFilter === "ALL"
      ? professionals
      : professionals.filter((barber) => barber.id === barberFilter);
  const nowLine = currentTime
    ? currentTimeGeometry(date, currentTime, timezone)
    : null;
  const dayAppointmentLayouts = useMemo(() => {
    const appointmentsForDate = filteredAppointments.filter(
      (appointment) => appointmentDateKey(appointment.service_period, timezone) === date,
    );
    return buildAppointmentLayouts(
      appointmentsForDate,
      (appointment) => appointment.id,
      (appointment) => appointment.service_period,
    );
  }, [date, filteredAppointments, timezone]);
  const dayLaneCount = Math.max(
    1,
    ...Array.from(dayAppointmentLayouts.values(), (layout) => layout.lanes),
  );
  useEffect(() => {
    const update = () => setCurrentTime(new Date());
    update();
    const interval = window.setInterval(update, 300_000);
    return () => window.clearInterval(interval);
  }, []);
  useEffect(() => {
    if (!datePickerOpen) return;
    const closeOnOutsidePointer = (event: PointerEvent) => {
      if (event.target instanceof Node && !datePickerRef.current?.contains(event.target))
        setDatePickerOpen(false);
    };
    const closeOnEscape = (event: KeyboardEvent) => {
      if (event.key === "Escape") setDatePickerOpen(false);
    };
    document.addEventListener("pointerdown", closeOnOutsidePointer);
    document.addEventListener("keydown", closeOnEscape);
    return () => {
      document.removeEventListener("pointerdown", closeOnOutsidePointer);
      document.removeEventListener("keydown", closeOnEscape);
    };
  }, [datePickerOpen]);
  function appointmentDate(appointment: BarberAppointment) {
    return appointmentDateKey(appointment.service_period, timezone);
  }
  function appointmentsOn(dateKey: string) {
    return filteredAppointments.filter(
      (appointment) => appointmentDate(appointment) === dateKey,
    );
  }
  function selectDate(dateKey: string) {
    setDate(dateKey);
    setDatePickerOpen(false);
    const params = new URLSearchParams(window.location.search);
    params.set("barbearia", context.organization_slug);
    params.set("data", dateKey);
    router.replace(`${window.location.pathname}?${params.toString()}`, { scroll: false });
  }
  function handleAgendaTouchStart(event: TouchEvent<HTMLDivElement>) {
    const touch = event.touches[0];
    if (!touch || (event.target instanceof Element && event.target.closest(".agenda-event"))) {
      agendaTouchStartRef.current = null;
      return;
    }
    const element = event.currentTarget;
    agendaTouchStartRef.current = {
      x: touch.clientX,
      y: touch.clientY,
      scrollLeft: element.scrollLeft,
      maxScrollLeft: Math.max(0, element.scrollWidth - element.clientWidth),
      onTimeAxis: event.target instanceof Element && Boolean(event.target.closest(".agenda-time-axis")),
    };
  }
  function handleAgendaTouchEnd(event: TouchEvent<HTMLDivElement>) {
    const start = agendaTouchStartRef.current;
    agendaTouchStartRef.current = null;
    const touch = event.changedTouches[0];
    if (!start || !touch) return;
    const deltaX = touch.clientX - start.x;
    const deltaY = touch.clientY - start.y;
    if (Math.abs(deltaX) < 52 || Math.abs(deltaX) < Math.abs(deltaY) * 1.25) return;
    const hasHorizontalOverflow = start.maxScrollLeft > 12;
    const atStart = start.scrollLeft <= 12;
    const atEnd = start.scrollLeft >= start.maxScrollLeft - 12;
    if (hasHorizontalOverflow && !start.onTimeAxis && !((deltaX > 0 && atStart) || (deltaX < 0 && atEnd))) return;
    selectDate(shiftDateKey(date, deltaX < 0 ? 1 : -1));
  }
  function serviceLabel(appointmentId: string) {
    return itemsByAppointment.get(appointmentId)?.join(" + ") || "Atendimento";
  }
  function closeCreate() {
    setNewOpen(false);
    setCustomerQuery("");
    setSelectedCustomerId("");
    setAttendeeDependentId("");
  }
  async function callRpc(
    name: string,
    args: Record<string, unknown>,
    success: string,
  ) {
    const client = getSupabaseBrowserClient();
    if (!client) {
      setMessage("Conexão com o sistema indisponível.");
      return false;
    }
    const { data, error } = await client.rpc(name, args);
    if (error) {
      setMessage(error.message);
      return false;
    }
    setMessage(success);
    router.refresh();
    return data ?? true;
  }
  async function transition(
    appointment: BarberAppointment,
    next: "IN_SERVICE" | "COMPLETED" | "NO_SHOW",
  ) {
    const saved = await callRpc(
      "barber_transition_appointment",
      {
        p_appointment_id: appointment.id,
        p_expected_status: appointment.status,
        p_new_status: next,
      },
      next === "IN_SERVICE"
        ? "Atendimento iniciado."
        : next === "COMPLETED"
          ? "Atendimento concluído."
          : "Não compareceu registrado.",
    );
    if (saved) {
      setSelected(null);
      if (
        next === "COMPLETED" &&
        context.cash_access_enabled &&
        (outstandingByAppointment.get(appointment.id) ?? 0) > 0
      )
        setReceiptTarget(appointment);
    }
  }
  async function cancel(appointment: BarberAppointment) {
    const reason = window.prompt("Motivo do cancelamento:");
    if (!reason?.trim()) return;
    if (
      await callRpc(
        "barber_cancel_appointment",
        { p_appointment_id: appointment.id, p_reason: reason.trim() },
        "Agendamento cancelado.",
      )
    )
      setSelected(null);
  }
  async function createAppointment(event: FormEvent<HTMLFormElement>) {
    event.preventDefault();
    const data = new FormData(event.currentTarget);
    if (!selectedCustomerId) {
      setMessage("Busque e selecione um cliente.");
      return;
    }
    const serviceId = String(data.get("service_id") ?? "");
    const barberId = ownAgenda
      ? context.barber_id
      : String(data.get("barber_id") ?? "");
    if (!serviceId || !barberId) {
      setMessage("Escolha serviço e profissional.");
      return;
    }
    const startsAt = `${String(data.get("date") ?? "")}T${String(data.get("time") ?? "")}`;
    const appointmentId = await callRpc(
        "barber_create_manual_appointment",
        {
          p_organization_id: context.organization_id,
          p_customer_id: selectedCustomerId,
          p_barber_id: barberId,
          p_starts_at: localDateTimeToIso(startsAt, timezone),
          p_selections: [{ type: "SERVICE", id: serviceId, quantity: 1 }],
          p_notes: String(data.get("notes") ?? "").trim() || null,
        },
        "Agendamento criado com saldo pendente para o balcão.",
      );
    if (appointmentId) {
      if (attendeeDependentId) { const client = getSupabaseBrowserClient(); if (client) await client.rpc("set_appointment_attendee", { p_appointment_id: String(appointmentId), p_attendee_dependent_id: attendeeDependentId }); }
      selectDate(String(data.get("date")));
      closeCreate();
    }
  }
  async function receive(event: FormEvent<HTMLFormElement>) {
    event.preventDefault();
    if (!receiptTarget) return;
    const data = new FormData(event.currentTarget);
    const amount = parseCents(data.get("amount"));
    if (!amount) {
      setMessage("Informe um valor válido.");
      return;
    }
    if (
      await callRpc(
        "record_barber_appointment_receipt",
        {
          p_appointment_id: receiptTarget.id,
          p_amount_cents: amount,
          p_payment_method: String(data.get("payment_method")),
          p_financial_account_id: String(data.get("financial_account_id")),
          p_reference: String(data.get("reference") ?? "").trim() || null,
          p_idempotency_key: `barber:receipt:${crypto.randomUUID()}`,
        },
        "Recebimento registrado no seu Caixa e aguardando conciliação.",
      )
    )
      setReceiptTarget(null);
  }
  const selectedCustomerRecord = selected
    ? customerById.get(selected.customer_id)
    : null;
  const selectedBarberRecord = selected
    ? barberById.get(selected.barber_id)
    : null;
  const selectedOutstanding = selected
    ? (outstandingByAppointment.get(selected.id) ??
      selected.total_cents_snapshot)
    : 0;
  const datePickerCalendar = monthCells(datePickerMonth);
  const datePickerTitle = formatDate(datePickerMonth, {
    month: "long",
    year: "numeric",
  }).replace(/^\p{L}/u, (letter) => letter.toLocaleUpperCase("pt-BR"));
  return (
    <div className={`${styles.stack} barber-agenda-page`}>
      {message && <ActionMessage message={message} />}
      <div className="barber-agenda-toolbar">
        <div className="barber-agenda-date" ref={datePickerRef}>
          <button
            type="button"
            className="barber-agenda-date__trigger"
            aria-label={`Selecionar data. Data atual: ${formatAgendaDate(date)}`}
            aria-haspopup="dialog"
            aria-expanded={datePickerOpen}
            aria-controls="barber-agenda-calendar-picker"
            onClick={() => {
              if (!datePickerOpen) setDatePickerMonth(date);
              setDatePickerOpen((open) => !open);
            }}
          >
            <strong>{formatAgendaDate(date)}</strong>
            <ChevronDown size={17} aria-hidden="true" />
          </button>
          {datePickerOpen && (
            <div
              className="barber-agenda-date__picker"
              id="barber-agenda-calendar-picker"
              role="dialog"
              aria-label="Selecionar data da agenda"
            >
              <header>
                <button
                  type="button"
                  aria-label="Mês anterior"
                  onClick={() => setDatePickerMonth((current) => shiftMonth(current, -1))}
                >
                  <ChevronLeft size={17} />
                </button>
                <strong>{datePickerTitle}</strong>
                <button
                  type="button"
                  aria-label="Próximo mês"
                  onClick={() => setDatePickerMonth((current) => shiftMonth(current, 1))}
                >
                  <ChevronRight size={17} />
                </button>
              </header>
              <div className="barber-agenda-date__weekdays" aria-hidden="true">
                {calendarWeekdays.map((day, index) => <span key={`${day}-${index}`}>{day}</span>)}
              </div>
              <div className="barber-agenda-date__days">
                {datePickerCalendar.map((cell) => (
                  <button
                    type="button"
                    key={cell.dateKey}
                    className={`${cell.outside ? "is-outside" : ""}${cell.dateKey === date ? " is-selected" : ""}${cell.dateKey === todayKey ? " is-today" : ""}`}
                    aria-label={formatAgendaDate(cell.dateKey)}
                    aria-pressed={cell.dateKey === date}
                    onClick={() => selectDate(cell.dateKey)}
                  >
                    {cell.day}
                  </button>
                ))}
              </div>
            </div>
          )}
        </div>
        <div className="barber-agenda-filters">
          <label className="barber-agenda-filter">
            <span className="sr-only">Filtrar por profissional</span>
            <select
              aria-label="Filtrar por profissional"
              value={barberFilter}
              disabled={ownAgenda}
              onChange={(event) => setBarberFilter(event.target.value)}
            >
              {!ownAgenda && <option value="ALL">Todos</option>}
              {professionals.map((barber) => (
                <option key={barber.id} value={barber.id}>{barber.display_name}</option>
              ))}
            </select>
            <ChevronDown size={15} aria-hidden="true" />
          </label>
          <label className="barber-agenda-filter">
            <span className="sr-only">Filtrar por status</span>
            <select
              aria-label="Filtrar por status"
              value={status}
              onChange={(event) => setStatus(event.target.value as StatusFilter)}
            >
              {(Object.keys(statusLabels) as StatusFilter[]).map((item) => (
                <option key={item} value={item}>{statusLabels[item]}</option>
              ))}
            </select>
            <ChevronDown size={15} aria-hidden="true" />
          </label>
        </div>
      </div>
      <section className="agenda-day barber-agenda-day" aria-label="Agenda diária">
        <div
          className="agenda-day__head"
          style={{ gridTemplateColumns: "56px minmax(0, 1fr)" }}
        >
          <div className="agenda-day__time-label">Horário</div>
          <div className="agenda-day__general-date">
            <small>{formatDate(date, { weekday: "long" }).replace("-feira", "")}</small>
            <strong>{formatDate(date, { day: "2-digit" })}</strong>
          </div>
        </div>
        <div
          className="agenda-day__scroll"
          aria-label="Horários da agenda. Deslize sobre a coluna de horários para mudar o dia."
          onTouchStart={handleAgendaTouchStart}
          onTouchEnd={handleAgendaTouchEnd}
          onTouchCancel={() => { agendaTouchStartRef.current = null; }}
        >
          <div
            className="agenda-day__grid"
            style={{
              gridTemplateColumns: `56px repeat(${dayLaneCount}, minmax(248px, 1fr))`,
              height: hours.length * 78,
            }}
          >
            {!appointmentsOn(date).length && (
              <div className="agenda-day__empty">Nenhum agendamento para este dia.</div>
            )}
            <div
              className="agenda-time-axis"
              style={{ gridTemplateRows: `repeat(${hours.length}, 78px)` }}
            >
              {hours.map((hour) => <span key={hour}>{hour}</span>)}
            </div>
            <div
              className="agenda-column"
              style={{ gridTemplateRows: `repeat(${hours.length}, 78px)` }}
            >
              {hours.map((hour) => <span className="agenda-gridline" key={hour} />)}
              {appointmentsOn(date).map((appointment, itemIndex) => {
                const geometry = appointmentGeometry(appointment.service_period, timezone);
                if (!geometry) return null;
                const display = statusDisplay(appointment);
                const layout = dayAppointmentLayouts.get(appointment.id) ?? { lane: 0, lanes: 1 };
                const laneWidth = 100 / dayLaneCount;
                const customerName = customerById.get(appointment.customer_id)?.full_name ?? "Cliente";
                const professionalName = barberById.get(appointment.barber_id)?.display_name ?? "Profissional";
                const environmentName = environmentById.get(appointment.environment_id ?? "") ?? "Ambiente não definido";
                return (
                  <button
                    key={appointment.id}
                    type="button"
                    aria-label={`Abrir agendamento de ${customerName}, ${professionalName}, ${environmentName}, ${geometry.startLabel}–${geometry.endLabel}, ${display.label}`}
                    title={`${customerName} · ${professionalName} | ${environmentName}`}
                    className={`agenda-event agenda-event--${itemIndex % 3} agenda-event--response-${display.tone}${geometry.height <= 24 ? " agenda-event--compact" : geometry.height <= 39 ? " agenda-event--short" : ""}`}
                    style={{ top: geometry.top, height: geometry.height, left: `calc(${layout.lane * laneWidth}% + 6px)`, right: "auto", width: `calc(${laneWidth}% - 12px)` }}
                    onClick={() => setSelected(appointment)}
                  >
                    <span className="agenda-event__details">
                      <strong>{customerName}</strong>
                      <small>{professionalName} | {environmentName}</small>
                    </span>
                  </button>
                );
              })}
              {nowLine && (
                <div className="agenda-now-line" style={{ top: nowLine.top }} aria-label={`Hora atual: ${nowLine.label}`}>
                  <span>{nowLine.label}</span><i />
                </div>
              )}
            </div>
          </div>
        </div>
      </section>
      <button type="button" className="barber-agenda-fab" aria-label="Novo agendamento" title="Novo agendamento" onClick={() => setNewOpen(true)}>
        <Plus size={27} strokeWidth={2.2} />
      </button>
      {selected && (
        <div className="modal-layer" role="presentation">
          <button
            className="modal-layer__backdrop"
            type="button"
            aria-label="Fechar detalhes"
            onClick={() => setSelected(null)}
          />
          <section
            className="form-modal appointment-detail"
            role="dialog"
            aria-modal="true"
            aria-label="Detalhes do agendamento"
          >
            <div className="appointment-detail__head">
              <span>
                <small>Agendamento {selected.id.slice(0, 8)}</small>
                <strong>Detalhes do atendimento</strong>
              </span>
              <button
                type="button"
                className="icon-button"
                onClick={() => setSelected(null)}
                aria-label="Fechar"
              >
                <X size={19} />
              </button>
            </div>
            <div className="appointment-detail__body">
              <div className="appointment-detail__customer">
                <Avatar
                  initials={(selectedCustomerRecord?.full_name ?? "CL")
                    .slice(0, 2)
                    .toUpperCase()}
                  size="lg"
                  tone="sage"
                />
                <span>
                  <strong>
                    {selectedCustomerRecord?.full_name ?? "Cliente"}
                  </strong>
                  <small>
                    {selectedCustomerRecord?.phone_e164 ?? "Sem telefone"}
                  </small>
                </span>
              </div>
              <StatusChip
                active={!["CANCELED", "NO_SHOW"].includes(selected.status)}
                label={statusDisplay(selected).label}
                tone={statusDisplay(selected).tone}
              />
              <div className="appointment-detail__info">
                <span>
                  <CalendarDays size={17} />
                  <div>
                    <small>Data e horário</small>
                    <strong>
                      {formatRange(selected.service_period, timezone)}
                    </strong>
                  </div>
                </span>
                <span>
                  <Scissors size={17} />
                  <div>
                    <small>Serviço</small>
                    <strong>{serviceLabel(selected.id)}</strong>
                  </div>
                </span>
                <span>
                  <UserRound size={17} />
                  <div>
                    <small>Profissional</small>
                    <strong>
                      {selectedBarberRecord?.display_name ?? "Profissional"}
                    </strong>
                  </div>
                </span>
                <span>
                  <MapPin size={17} />
                  <div>
                    <small>Origem</small>
                    <strong>{selected.source ?? "AGENDA"}</strong>
                  </div>
                </span>
                {context.kanban_access_enabled && (() => { const card = kanbanCards.find((item) => item.appointment_id === selected.id); const board = kanbanBoards.find((item) => item.id === card?.board_id); return board ? <span><div><small>Kanban</small><strong>{board.name}</strong></div></span> : null; })()}
              </div>
              <div className="appointment-detail__payment">
                <div>
                  <span>
                    <CircleDollarSign size={17} /> Pagamento
                  </span>
                  <small>
                    {selected.payment_mode === "SUBSCRIPTION"
                      ? "Sessão assinatura"
                      : selectedOutstanding > 0
                        ? "Pgto Pendente"
                        : "Pago"}
                  </small>
                </div>
                <strong>
                  {selected.payment_mode === "SUBSCRIPTION"
                    ? "Incluída no plano"
                    : formatCents(selected.total_cents_snapshot)}
                </strong>
                <span>
                  {selected.payment_mode === "SUBSCRIPTION"
                    ? "Sem cobrança avulsa"
                    : `Saldo: ${formatCents(selectedOutstanding)}`}
                </span>
              </div>
              {selectedCustomerRecord?.phone_e164 && (
                <div className="appointment-detail__contact">
                  <a
                    href={`https://web.whatsapp.com/send?phone=${selectedCustomerRecord.phone_e164.replace(/\D/g, "")}`}
                    target="_blank"
                    rel="noreferrer"
                  >
                    <MessageCircle size={17} /> WhatsApp
                  </a>
                </div>
              )}
            </div>
            <div className="appointment-detail__actions">
              {["HELD", "PENDING_PAYMENT", "CONFIRMED"].includes(
                selected.status,
              ) && (
                <button
                  type="button"
                  className="button button--soft"
                  disabled
                  title="A confirmação manual é gerenciada pelo Gestor."
                >
                  Confirmar manualmente
                </button>
              )}
              {selected.status === "CONFIRMED" && (
                <button
                  type="button"
                  className="button button--dark"
                  onClick={() => void transition(selected, "IN_SERVICE")}
                >
                  <Check size={17} /> Iniciar
                </button>
              )}
              {selected.status === "IN_SERVICE" && (
                <button
                  type="button"
                  className="button button--dark"
                  onClick={() => void transition(selected, "COMPLETED")}
                >
                  <Check size={17} /> Concluir
                </button>
              )}
              {selected.status === "COMPLETED" &&
                context.cash_access_enabled &&
                selectedOutstanding > 0 && (
                  <button
                    type="button"
                    className="button button--dark"
                    onClick={() => {
                      setSelected(null);
                      setReceiptTarget(selected);
                    }}
                  >
                    <CircleDollarSign size={17} /> Receber
                  </button>
                )}
              {selected.status === "CONFIRMED" && (
                <button
                  type="button"
                  className="button button--soft"
                  onClick={() => void transition(selected, "NO_SHOW")}
                >
                  Não compareceu
                </button>
              )}
              {["CONFIRMED", "IN_SERVICE"].includes(selected.status) && (
                <button
                  type="button"
                  className="button button--soft"
                  onClick={() => void cancel(selected)}
                >
                  Cancelar
                </button>
              )}
            </div>
          </section>
        </div>
      )}
      {newOpen && (
        <div className="modal-layer" role="presentation">
          <button
            className="modal-layer__backdrop"
            type="button"
            aria-label="Fechar"
            onClick={closeCreate}
          />
          <form
            className="form-modal"
            role="dialog"
            aria-modal="true"
            aria-label="Novo agendamento"
            onSubmit={createAppointment}
          >
            <div className="form-modal__head">
              <span>
                <small>Novo agendamento</small>
                <strong>Reserve um horário</strong>
              </span>
              <button
                type="button"
                className="icon-button"
                onClick={closeCreate}
                aria-label="Fechar"
              >
                <X size={19} />
              </button>
            </div>
            <div className="form-modal__body">
              <label>
                Cliente
                <span className="input-shell">
                  <UserRound size={17} />
                  <input
                    required
                    value={selectedCustomer?.full_name ?? customerQuery}
                    onChange={(event) => {
                      setCustomerQuery(event.target.value);
                      setSelectedCustomerId("");
                    }}
                    placeholder="Buscar por nome ou telefone"
                  />
                </span>
              </label>
              {customerQuery.trim() && !selectedCustomerId && (
                <div className="customer-search-results">
                  {matchingCustomers.map((customer) => (
                    <button
                      className="customer-search-result"
                      key={customer.id}
                      type="button"
                      onClick={() => {
                        setSelectedCustomerId(customer.id);
                        setCustomerQuery(customer.full_name);
                      }}
                    >
                      <strong>{customer.full_name}</strong>
                      <small>{customer.phone_e164 ?? "Sem telefone"}</small>
                    </button>
                  ))}
                  {matchingCustomers.length === 0 && (
                    <span className="customer-search-selected">
                      Nenhum cliente encontrado. Solicite o cadastro ao Gestor.
                    </span>
                  )}
                </div>
              )}
              {selectedCustomer && (
                <p className="customer-search-selected">
                  <Check size={15} /> {selectedCustomer.full_name} selecionado
                </p>
              )}
              {selectedCustomer && (selectedCustomer.dependents ?? []).length > 0 && <label>Pessoa atendida<select value={attendeeDependentId} onChange={(event) => setAttendeeDependentId(event.target.value)}><option value="">Cliente titular</option>{selectedCustomer.dependents?.map((dependent) => <option key={dependent.id} value={dependent.id}>{dependent.full_name}</option>)}</select></label>}
              <div className="form-grid">
                <label>
                  Serviço
                  <span className="select-input">
                    <select name="service_id" required defaultValue="">
                      <option value="">Selecione</option>
                      {services.map((service) => (
                        <option key={service.id} value={service.id}>
                          {service.name} · {formatCents(service.price_cents)}
                        </option>
                      ))}
                    </select>
                    <ChevronDown size={15} />
                  </span>
                </label>
                <label>
                  Profissional
                  <span className="select-input">
                    <select
                      name="barber_id"
                      required
                      defaultValue={ownAgenda ? context.barber_id : ""}
                      disabled={ownAgenda}
                    >
                      {!ownAgenda && <option value="">Selecione</option>}
                      {displayedBarbers.map((barber) => (
                        <option key={barber.id} value={barber.id}>
                          {barber.display_name}
                        </option>
                      ))}
                    </select>
                    <ChevronDown size={15} />
                  </span>
                </label>
              </div>
              <div className="form-grid">
                <label>
                  Data
                  <span className="input-shell">
                    <CalendarDays size={17} />
                    <input
                      name="date"
                      type="date"
                      defaultValue={date}
                      required
                    />
                  </span>
                </label>
                <label>
                  Horário
                  <span className="input-shell">
                    <Clock3 size={17} />
                    <input
                      name="time"
                      type="time"
                      defaultValue="09:00"
                      step="900"
                      required
                    />
                  </span>
                </label>
              </div>
              <label>
                Observação <small>opcional</small>
                <textarea
                  name="notes"
                  placeholder="Preferências e observações..."
                  rows={3}
                />
              </label>
            </div>
            <div className="form-modal__footer">
              <button
                type="button"
                className="button button--ghost"
                onClick={closeCreate}
              >
                Cancelar
              </button>
              <button type="submit" className="button button--dark">
                <CalendarPlus2 size={17} /> Criar agendamento
              </button>
            </div>
          </form>
        </div>
      )}
      {receiptTarget && (
        <div className="modal-layer" role="presentation">
          <button
            className="modal-layer__backdrop"
            type="button"
            aria-label="Fechar recebimento"
            onClick={() => setReceiptTarget(null)}
          />
          <form
            className="form-modal"
            role="dialog"
            aria-modal="true"
            aria-label="Receber atendimento"
            onSubmit={receive}
          >
            <div className="form-modal__head">
              <span>
                <small>Caixa individual</small>
                <strong>Receber atendimento</strong>
              </span>
              <button
                type="button"
                className="icon-button"
                onClick={() => setReceiptTarget(null)}
                aria-label="Fechar"
              >
                <X size={19} />
              </button>
            </div>
            <div className="form-modal__body">
              <p>
                O recebimento ficará no seu Caixa e aguardará a conciliação do
                Gestor.
              </p>
              <label>
                Atendimento
                <span className="input-shell">
                  <input
                    value={`${customerById.get(receiptTarget.customer_id)?.full_name ?? "Cliente"} · saldo ${formatCents(outstandingByAppointment.get(receiptTarget.id) ?? receiptTarget.total_cents_snapshot)}`}
                    readOnly
                  />
                </span>
              </label>
              <label>
                Valor recebido (R$)
                <span className="input-shell">
                  <input
                    name="amount"
                    inputMode="decimal"
                    placeholder="0,00"
                    required
                  />
                </span>
              </label>
              <label>
                Forma de recebimento
                <span className="select-input">
                  <select name="payment_method">
                    {paymentMethods.map((method) => (
                      <option key={method} value={method}>
                        {method === "CASH"
                          ? "Dinheiro"
                          : method === "CARD"
                            ? "Cartão"
                            : method}
                      </option>
                    ))}
                  </select>
                  <ChevronDown size={15} />
                </span>
              </label>
              <label>
                Conta de destino
                <span className="select-input">
                  <select name="financial_account_id" required defaultValue="">
                    <option value="">Selecione</option>
                    {accounts.map((account) => (
                      <option key={account.id} value={account.id}>
                        {account.name} ·{" "}
                        {account.kind === "CASH" ? "Caixa" : "Banco"}
                      </option>
                    ))}
                  </select>
                  <ChevronDown size={15} />
                </span>
              </label>
              <label>
                Observação <small>opcional</small>
                <span className="input-shell">
                  <input name="reference" maxLength={240} />
                </span>
              </label>
            </div>
            <div className="form-modal__footer">
              <button
                type="button"
                className="button button--ghost"
                onClick={() => setReceiptTarget(null)}
              >
                Cancelar
              </button>
              <button type="submit" className="button button--dark">
                <CircleDollarSign size={17} /> Confirmar recebimento
              </button>
            </div>
          </form>
        </div>
      )}
    </div>
  );
}
