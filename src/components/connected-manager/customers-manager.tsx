"use client";

import { useMemo, useState, useEffect, type FormEvent } from "react";
import { useRouter } from "next/navigation";
import { CalendarDays, Check, ChevronDown, Clock3, Pencil, Save, Trash2, UserRound, UserPlus, X } from "lucide-react";
import { PageHeader } from "@/components/ui";
import type { loadCustomersData } from "./server";
import type { AwaitedReturn } from "./utility-types";
import type { CustomerRecord } from "./types";
import { ActionMessage, EmptyState, Field, Panel, StatusChip } from "./shared";
import { assertResult, connectedClient, runMutation } from "./mutation-utils";
import styles from "./connected-manager.module.css";
import { normalizePhoneE164 } from "@/lib/phone";
import { centsFromInput, formatCents, formatRange, localDateTimeToIso, parsePostgresRange } from "./format";
import { cpfCnpjDigits, formatCpfCnpj, isCpfCnpjValid } from "@/lib/cpf-cnpj";
import { showManagerError } from "@/components/manager-error-dialog";

type LoadedProps = AwaitedReturn<typeof loadCustomersData>;
type Props = Omit<
  LoadedProps,
  | "timezone"
  | "subscriptionBundlePlans"
  | "subscriptions"
  | "subscriptionCancellationRequests"
  | "subscriptionCycles"
  | "subscriptionSessions"
  | "subscriptionPlanServices"
  | "barberServices"
  | "barberSubscriptionPlans"
  | "subscriptionServiceDurations"
  | "chartAccounts"
  | "financialAccounts"
  | "costCenters"
  | "financialTags"
  | "slotIntervalMinutes"
  | "workIntervals"
  | "agendaEnvironments"
  | "subscriptionModuleEnabled"
> &
  Partial<
    Pick<
      LoadedProps,
      | "subscriptions"
      | "subscriptionCancellationRequests"
      | "timezone"
      | "subscriptionBundlePlans"
      | "subscriptionCycles"
      | "subscriptionSessions"
      | "subscriptionPlanServices"
      | "barberServices"
      | "barberSubscriptionPlans"
      | "subscriptionServiceDurations"
      | "chartAccounts"
      | "financialAccounts"
      | "costCenters"
      | "financialTags"
      | "slotIntervalMinutes"
      | "workIntervals"
      | "agendaEnvironments"
      | "subscriptionModuleEnabled"
    >
  > & { subscriptionPlans?: unknown[] };
type CustomerFilter = "ACTIVE" | "INACTIVE";
type SubscriptionDisplayStatus = "pending" | "cancellationPending" | "due" | "finished" | "overdue" | "active" | "declined" | "canceled";
type SubscriptionFilter = "ALL" | SubscriptionDisplayStatus;

function dateInTimezone(date: Date, timezone: string): string {
  const parts = new Intl.DateTimeFormat("en-US", {
    timeZone: timezone,
    year: "numeric",
    month: "2-digit",
    day: "2-digit",
  }).formatToParts(date);
  const values = Object.fromEntries(parts.map((part) => [part.type, part.value]));
  return `${values.year}-${values.month}-${values.day}`;
}

function weekdayForDate(date: string): number | null {
  const match = /^(\d{4})-(\d{2})-(\d{2})$/u.exec(date);
  if (!match) return null;
  return new Date(Date.UTC(Number(match[1]), Number(match[2]) - 1, Number(match[3]))).getUTCDay();
}

function minutesFromTime(value: string): number | null {
  const match = /^(\d{2}):(\d{2})/u.exec(value);
  if (!match) return null;
  return Number(match[1]) * 60 + Number(match[2]);
}

function timeFromMinutes(value: number): string {
  return `${String(Math.floor(value / 60)).padStart(2, "0")}:${String(value % 60).padStart(2, "0")}`;
}

function localDateTimeInputs(value: Date, timezone: string) {
  const parts = new Intl.DateTimeFormat("en-CA", {
    timeZone: timezone,
    year: "numeric",
    month: "2-digit",
    day: "2-digit",
    hour: "2-digit",
    minute: "2-digit",
    hourCycle: "h23",
  }).formatToParts(value);
  const fields = Object.fromEntries(parts.map((part) => [part.type, part.value]));
  return {
    date: `${fields.year}-${fields.month}-${fields.day}`,
    time: `${fields.hour}:${fields.minute}`,
  };
}

function subscriptionDisplayStatuses(
  subscription: { status?: unknown; contract_accepted_at?: unknown; manager_activated_provisionally_at?: unknown },
  cycles: Array<Record<string, unknown>>,
  today: string,
  cancellationPending = false,
): Set<SubscriptionDisplayStatus> {
  const statuses = new Set<SubscriptionDisplayStatus>();
  const status = String(subscription.status);
  if (subscription.manager_activated_provisionally_at && !subscription.contract_accepted_at) {
    statuses.add("pending");
  } else if (status === "REQUESTED") {
    statuses.add("pending");
  } else if (status === "DECLINED") {
    statuses.add("declined");
  } else if (status === "CANCELED") {
    statuses.add("canceled");
  } else {
    const billableCycles = cycles.filter((cycle) => String(cycle.status) !== "CANCELED");
    if (billableCycles.some((cycle) => {
      const cycleStatus = String(cycle.status);
      return cycleStatus === "OVERDUE" ||
        (cycleStatus === "OPEN" && typeof cycle.due_on === "string" && cycle.due_on < today);
    })) {
      statuses.add("overdue");
    } else if (billableCycles.length > 0 && billableCycles.every((cycle) => String(cycle.status) === "PAID")) {
      statuses.add("finished");
    } else {
      const unpaidCycles = billableCycles.filter((cycle) =>
        String(cycle.status) === "OPEN" || String(cycle.status) === "OVERDUE",
      );
      statuses.add(unpaidCycles.length === 1 ? "due" : "active");
    }
  }

  if (cancellationPending && status !== "REQUESTED" && status !== "DECLINED" && status !== "CANCELED") {
    statuses.add("cancellationPending");
  }
  return statuses;
}

function subscriptionDisplayStatus(
  subscription: { status?: unknown; contract_accepted_at?: unknown },
  cycles: Array<Record<string, unknown>>,
  today: string,
  cancellationPending = false,
): SubscriptionDisplayStatus {
  const statuses = subscriptionDisplayStatuses(subscription, cycles, today, cancellationPending);
  const priority: SubscriptionDisplayStatus[] = [
    "cancellationPending",
    "pending",
    "declined",
    "canceled",
    "overdue",
    "finished",
    "due",
    "active",
  ];
  return priority.find((status) => statuses.has(status)) ?? "active";
}

const activeSubscriptionStatuses = new Set<SubscriptionDisplayStatus>([
  "cancellationPending",
  "active",
  "due",
  "overdue",
]);

const subscriptionDisplayStatusLabels: Record<SubscriptionDisplayStatus, string> = {
  pending: "Pendente",
  cancellationPending: "Cancelamento pendente",
  due: "À Vencer",
  finished: "Finalizado",
  overdue: "Em Atraso",
  active: "Ativo",
  declined: "Recusada",
  canceled: "Cancelada",
};

const subscriptionFilterLabels: Record<SubscriptionFilter, string> = {
  ALL: "Todas as assinaturas",
  cancellationPending: "Cancelamento pendente",
  active: "Ativas",
  pending: "Pendentes",
  due: "À Vencer",
  finished: "Finalizadas",
  overdue: "Em Atraso",
  declined: "Recusadas",
  canceled: "Canceladas",
};

const bundlePaymentMethodLabels: Record<string, string> = {
  ONLINE: "Link de pagamento",
  CARD: "Cartão",
  PIX: "Pix",
  BOLETO: "Boleto",
  CASH: "Dinheiro",
  CRYPTO: "Cripto",
  UPFRONT: "À vista",
};

const inactivationReasons = [
  ["NEIGHBORHOOD_CHANGE", "Mudança de bairro"],
  ["CITY_CHANGE", "Mudança de cidade"],
  ["DISSATISFACTION", "Insatisfação"],
  ["LOST_CONTACT", "Perda de contato"],
  ["OTHER", "Outro motivo"],
] as const;

type ApprovalDraft = { subscriptionId: string; startDate: string; dueDate: string };
type ManualSubscriptionActivationDraft = { subscriptionId: string; planName: string };
type FixedScheduleEditDraft = { subscriptionId: string; cadenceWeeks: string; startDate: string; localTime: string; barberId: string; environmentId: string; serviceIds: string[] };
type BundleOfferSlotDraft = { slotNumber: number; barberId: string; weekday: string; localTime: string; environmentId: string };
type BundleOfferTab = "SESSIONS" | "FINANCIAL" | "REVIEW";
type BundleDiscountType = "NONE" | "FIXED" | "PERCENT";
type BundleOfferDraft = {
  customerId: string;
  planId: string;
  firstSessionDate: string;
  entryDueDate: string;
  firstInstallmentDueDate: string;
  idempotencyKey: string;
  slots: BundleOfferSlotDraft[];
  totalSessions: string;
  pricePerSession: string;
  entry: string;
  paymentMethod: string;
  installmentCount: string;
  discountType: BundleDiscountType;
  discountValue: string;
  activeTab: BundleOfferTab;
};
type FixedScheduleSlot = { time: string; environmentId: string; environmentName: string };

function bundleMoneyInput(cents: number | null | undefined) {
  return ((Number(cents) || 0) / 100).toFixed(2).replace(".", ",");
}

function bundlePercentageInput(basisPoints: number | null | undefined) {
  return ((Number(basisPoints) || 0) / 100).toFixed(2).replace(".", ",");
}

function formatBundleDate(value: string) {
  const match = /^(\d{4})-(\d{2})-(\d{2})$/u.exec(value);
  return match ? `${match[3]}/${match[2]}/${match[1]}` : "—";
}

function safeBundleCentsInput(value: string) {
  try {
    return centsFromInput(value);
  } catch {
    return 0;
  }
}

function safeBundlePercentageInput(value: string) {
  const numeric = Number(value.replace(",", "."));
  return Number.isFinite(numeric) ? Math.round(numeric * 100) : 0;
}

function bundleFinancialDraft(plan: LoadedProps["subscriptionBundlePlans"][number]) {
  const sessions = Number(plan.version.bundle_total_sessions ?? 1);
  return {
    totalSessions: String(sessions),
    pricePerSession: bundleMoneyInput(
      plan.version.bundle_price_per_session_cents ?? Math.ceil(Number(plan.version.price_cents) / sessions),
    ),
    entry: Number(plan.version.bundle_entry_cents ?? 0) > 0 ? bundleMoneyInput(plan.version.bundle_entry_cents) : "",
    paymentMethod: plan.version.payment_method,
    installmentCount: String(plan.version.bundle_installment_count ?? 1),
    discountType: (plan.version.bundle_discount_type === "FIXED" || plan.version.bundle_discount_type === "PERCENT"
      ? plan.version.bundle_discount_type
      : "NONE") as BundleDiscountType,
    discountValue: plan.version.bundle_discount_type === "PERCENT"
      ? bundlePercentageInput(plan.version.bundle_discount_value)
      : plan.version.bundle_discount_type === "FIXED"
        ? bundleMoneyInput(plan.version.bundle_discount_value)
        : "",
  };
}

type SubscriptionCancellationDraft = {
  subscriptionId: string;
  requestId: string | null;
  reason: string;
  observations: string;
  lastCycleId: string;
  lastSessionId: string;
};
type SubscriptionBookingTarget = {
  mode: "BOOK" | "RESCHEDULE";
  appointmentId: string | null;
  subscriptionId: string;
  sessionId: string;
  customerId: string;
  sessionNumber: number;
  totalSessions: number;
  referenceDate: string;
  planName: string;
  serviceNames: string[];
  serviceIds: string[];
};

function birthdayReminder(birthDate: string | null): string | null {
  if (!birthDate) return null;
  const match = /^(\d{4})-(\d{2})-(\d{2})$/u.exec(birthDate);
  if (!match) return null;
  const month = Number(match[2]);
  const day = Number(match[3]);
  if (month < 1 || month > 12 || day < 1 || day > 31) return null;

  const today = new Date();
  const currentDay = Date.UTC(
    today.getFullYear(),
    today.getMonth(),
    today.getDate(),
  );
  const birthdayForYear = (year: number) => {
    const lastDay = new Date(Date.UTC(year, month, 0)).getUTCDate();
    return Date.UTC(year, month - 1, Math.min(day, lastDay));
  };
  let nextBirthday = birthdayForYear(today.getFullYear());
  if (nextBirthday < currentDay)
    nextBirthday = birthdayForYear(today.getFullYear() + 1);
  const days = Math.round((nextBirthday - currentDay) / 86_400_000);
  if (days > 7) return null;
  if (days === 0) return "Cliente faz aniversário hoje";
  return `Cliente faz aniversário em ${days} ${days === 1 ? "dia" : "dias"}`;
}

export function CustomersManager({
  organizationId,
  timezone = "America/Sao_Paulo",
  customers,
  appointments,
  appointmentItems,
  financial,
  barbers,
  statusEvents,
  subscriptions = [],
  subscriptionCancellationRequests = [],
  subscriptionCycles = [],
  subscriptionSessions = [],
  subscriptionPlanServices = [],
  barberServices = [],
  barberSubscriptionPlans = [],
  subscriptionServiceDurations = [],
  subscriptionBundlePlans = [],
  slotIntervalMinutes = 15,
  workIntervals = [],
  agendaEnvironments = [],
  chartAccounts = [],
  financialAccounts = [],
  costCenters = [],
  financialTags = [],
  subscriptionModuleEnabled = false,
}: Props) {
  const router = useRouter();
  const todayInOrganization = dateInTimezone(new Date(), timezone);
  const [formOpen, setFormOpen] = useState(customers.length === 0);
  const [editing, setEditing] = useState<CustomerRecord | null>(null);
  const [query, setQuery] = useState("");
  const [message, setMessage] = useState("");
  const [mergeOpen, setMergeOpen] = useState(false);
  const [historyCustomer, setHistoryCustomer] = useState<CustomerRecord | null>(
    null,
  );
  const [historyTab, setHistoryTab] = useState<
    "APPOINTMENTS" | "SUBSCRIPTIONS"
  >("APPOINTMENTS");
  const [customerFilter, setCustomerFilter] =
    useState<CustomerFilter>("ACTIVE");
  const [subscriptionFilter, setSubscriptionFilter] =
    useState<SubscriptionFilter>("ALL");
  const [pendingInactivation, setPendingInactivation] =
    useState<CustomerRecord | null>(null);
  const [inactivationReason, setInactivationReason] = useState("");
  const [customInactivationReason, setCustomInactivationReason] = useState("");
  const [approvalDraft, setApprovalDraft] = useState<ApprovalDraft | null>(null);
  const [manualSubscriptionActivationDraft, setManualSubscriptionActivationDraft] = useState<ManualSubscriptionActivationDraft | null>(null);
  const [fixedScheduleEditDraft, setFixedScheduleEditDraft] = useState<FixedScheduleEditDraft | null>(null);
  const [subscriptionControlId, setSubscriptionControlId] = useState<string | null>(null);
  const [subscriptionControlTab, setSubscriptionControlTab] = useState<"SESSIONS" | "FINANCE" | "SUMMARY">("SESSIONS");
  const [subscriptionBundleContracts, setSubscriptionBundleContracts] = useState<Array<Record<string, unknown>>>([]);
  const [subscriptionBundleInstallments, setSubscriptionBundleInstallments] = useState<Array<Record<string, unknown>>>([]);
  const [subscriptionBundleSessions, setSubscriptionBundleSessions] = useState<Array<Record<string, unknown>>>([]);
  const [subscriptionBundleFixedSlots, setSubscriptionBundleFixedSlots] = useState<Array<Record<string, unknown>>>([]);
  const [deletingSubscriptionId, setDeletingSubscriptionId] = useState<string | null>(null);
  const [subscriptionCycleDeleteTarget, setSubscriptionCycleDeleteTarget] = useState<Record<string, unknown> | null>(null);
  const [deletingSubscriptionCycle, setDeletingSubscriptionCycle] = useState(false);
  const [subscriptionBundleInstallmentDeleteTarget, setSubscriptionBundleInstallmentDeleteTarget] = useState<Record<string, unknown> | null>(null);
  const [subscriptionInstallmentEdit, setSubscriptionInstallmentEdit] = useState<{ kind: "LEGACY" | "BUNDLE"; subscriptionId: string; installmentId: string; amount: string; dueOn: string } | null>(null);
  const [savingSubscriptionInstallmentEdit, setSavingSubscriptionInstallmentEdit] = useState(false);
  const [subscriptionCancellationDraft, setSubscriptionCancellationDraft] = useState<SubscriptionCancellationDraft | null>(null);
  const [subscriptionBooking, setSubscriptionBooking] = useState<SubscriptionBookingTarget | null>(null);
  const [subscriptionBookingDate, setSubscriptionBookingDate] = useState("");
  const [subscriptionBookingTime, setSubscriptionBookingTime] = useState("09:00");
  const [subscriptionBookingBarberId, setSubscriptionBookingBarberId] = useState("");
  const [subscriptionOverdueReason, setSubscriptionOverdueReason] = useState("");
  const [bundleOfferDraft, setBundleOfferDraft] = useState<BundleOfferDraft | null>(null);
  const [bundleOfferSending, setBundleOfferSending] = useState(false);
  const [bundleOfferConfirmationOpen, setBundleOfferConfirmationOpen] = useState(false);
  const [paymentTarget, setPaymentTarget] = useState<{ kind: "LEGACY"; subscriptionId: string; cycleId: string; amountCents: number; dueOn: string } | { kind: "BUNDLE"; subscriptionId: string; installmentId: string; amountCents: number; dueOn: string; idempotencyKey: string } | null>(null);
  const [paymentDate, setPaymentDate] = useState(todayInOrganization);
  const [paymentMethod, setPaymentMethod] = useState("CASH");
  const [paymentAccountId, setPaymentAccountId] = useState("");
  const [paymentReference, setPaymentReference] = useState("");
  const [paymentChartAccountId, setPaymentChartAccountId] = useState("");
  const [paymentCostCenterId, setPaymentCostCenterId] = useState("");
  const [paymentTagIds, setPaymentTagIds] = useState<string[]>([]);
  const [paymentDescription, setPaymentDescription] = useState("");
  const [paymentDocumentNumber, setPaymentDocumentNumber] = useState("");
  const [customerFormTab, setCustomerFormTab] = useState<"details" | "dependents">("details");
  const [dependentDraft, setDependentDraft] = useState<{ id?: string; fullName: string; birthDate: string; relationship: "CHILD" | "SPOUSE" | "EMPLOYEE" | "PARENT" | "OTHER" }>({ fullName: "", birthDate: "", relationship: "CHILD" });
  const [todayTimestamp] = useState(() => Date.now());
  useEffect(() => {
    const subscription = subscriptions.find((item) => String(item.id) === subscriptionControlId);
    const version = subscription?.plan_version as { model?: string } | null | undefined;
    if (!subscriptionControlId || version?.model !== "SESSION_BUNDLE_V1") return;
    let active = true;
    void Promise.all([
      connectedClient().from("subscription_bundle_contracts")
        .select("id,subscription_id,scheduling_mode,sessions_per_week,session_duration_minutes,total_sessions,price_per_session_cents,total_price_cents,entry_cents,installment_count,discount_type,discount_value,entry_due_on,first_installment_due_on,first_session_date")
        .eq("organization_id", organizationId).eq("subscription_id", subscriptionControlId).maybeSingle(),
      connectedClient().from("subscription_bundle_installments")
        .select("id,subscription_id,installment_number,kind,due_on,amount_cents,payment_method,status,paid_at,financial_entry_id")
        .eq("organization_id", organizationId).eq("subscription_id", subscriptionControlId).order("installment_number"),
      connectedClient().from("subscription_bundle_sessions")
        .select("id,subscription_id,session_number,release_on,scheduled_for,installment_number,status,appointment_id,barber_id,environment_id")
        .eq("organization_id", organizationId).eq("subscription_id", subscriptionControlId).order("session_number"),
      connectedClient().from("subscription_bundle_fixed_slots")
        .select("id,subscription_id,slot_number,weekday,local_time,barber_name_snapshot,environment_name_snapshot")
        .eq("organization_id", organizationId).eq("subscription_id", subscriptionControlId).order("slot_number"),
    ]).then(async ([contract, installments, sessions, slots]) => {
      if (!active) return;
      const failed = contract.error ?? installments.error ?? sessions.error ?? slots.error;
      if (failed) {
        setMessage(`Não foi possível carregar os detalhes do plano: ${failed.message}`);
        return;
      }
      const installmentRows = (installments.data ?? []) as Array<Record<string, unknown>>;
      const entryIds = [...new Set(installmentRows.map((item) => String(item.financial_entry_id ?? "")).filter(Boolean))];
      const [entries, settlements] = entryIds.length > 0
        ? await Promise.all([
            connectedClient().from("financial_entries").select("id,canceled_at,total_cents,due_date").eq("organization_id", organizationId).in("id", entryIds),
            connectedClient().from("financial_settlements").select("id,entry_id,amount_cents,settled_on,payment_method,reference,kind").eq("organization_id", organizationId).in("entry_id", entryIds).order("settled_on"),
          ])
        : [{ data: [], error: null }, { data: [], error: null }];
      if (entries.error || settlements.error) {
        setMessage(`Não foi possível carregar os recebimentos das parcelas: ${entries.error?.message ?? settlements.error?.message}`);
        return;
      }
      const entriesById = new Map(((entries.data ?? []) as Array<Record<string, unknown>>).map((entry) => [String(entry.id), entry]));
      const settlementsByEntry = new Map<string, Array<Record<string, unknown>>>();
      for (const settlement of (settlements.data ?? []) as Array<Record<string, unknown>>) {
        const entryId = String(settlement.entry_id ?? "");
        settlementsByEntry.set(entryId, [...(settlementsByEntry.get(entryId) ?? []), settlement]);
      }
      setSubscriptionBundleContracts(contract.data ? [contract.data as Record<string, unknown>] : []);
      setSubscriptionBundleInstallments(installmentRows.map((installment) => ({
        ...installment,
        financial_entry: entriesById.get(String(installment.financial_entry_id ?? "")) ?? null,
        settlements: settlementsByEntry.get(String(installment.financial_entry_id ?? "")) ?? [],
      })));
      setSubscriptionBundleSessions((sessions.data ?? []) as Array<Record<string, unknown>>);
      setSubscriptionBundleFixedSlots((slots.data ?? []) as Array<Record<string, unknown>>);
    }).catch((cause: unknown) => {
      if (active) setMessage(cause instanceof Error ? cause.message : "Não foi possível carregar o plano.");
    });
    return () => { active = false; };
  }, [organizationId, subscriptionControlId, subscriptions]);
  useEffect(() => {
    if (subscriptionControlId) setSubscriptionControlTab("SESSIONS");
  }, [subscriptionControlId]);
  const subscriptionStatusesByCustomer = useMemo(() => {
    const cyclesBySubscription = new Map<string, Array<Record<string, unknown>>>();
    for (const cycle of subscriptionCycles) {
      const subscriptionId = String(cycle.subscription_id ?? "");
      const relatedCycles = cyclesBySubscription.get(subscriptionId) ?? [];
      relatedCycles.push(cycle);
      cyclesBySubscription.set(subscriptionId, relatedCycles);
    }

    const statusesByCustomer = new Map<string, Set<SubscriptionDisplayStatus>>();
    for (const subscription of subscriptions) {
      const customerId = String(subscription.customer_id ?? "");
      if (!customerId) continue;
      const statuses = statusesByCustomer.get(customerId) ?? new Set<SubscriptionDisplayStatus>();
      for (const status of subscriptionDisplayStatuses(
        subscription,
        cyclesBySubscription.get(String(subscription.id)) ?? [],
        todayInOrganization,
        subscriptionCancellationRequests.some((request) => String(request.subscription_id) === String(subscription.id)),
      )) {
        statuses.add(status);
      }
      statusesByCustomer.set(customerId, statuses);
    }
    return statusesByCustomer;
  }, [subscriptions, subscriptionCycles, subscriptionCancellationRequests, todayInOrganization]);
  const filtered = customers.filter((customer) => {
    const matchesCustomerStatus = customer.active === (customerFilter === "ACTIVE");
    const matchesQuery = `${customer.full_name} ${customer.phone_e164 ?? ""} ${customer.email ?? ""}`
      .toLowerCase()
      .includes(query.toLowerCase());
    const customerSubscriptionStatuses = subscriptionStatusesByCustomer.get(customer.id);
    const matchesSubscriptionStatus = subscriptionFilter === "ALL" ||
      (subscriptionFilter === "active"
        ? [...activeSubscriptionStatuses].some((status) => customerSubscriptionStatuses?.has(status))
        : customerSubscriptionStatuses?.has(subscriptionFilter) === true);
    return matchesCustomerStatus && matchesQuery && matchesSubscriptionStatus;
  });
  const itemsByAppointment = useMemo(() => {
    const map = new Map<string, string[]>();
    for (const item of [...appointmentItems].sort(
      (left, right) => left.position - right.position,
    )) {
      map.set(item.appointment_id, [
        ...(map.get(item.appointment_id) ?? []),
        item.service_name_snapshot,
      ]);
    }
    return map;
  }, [appointmentItems]);
  const financialByAppointment = useMemo(
    () => new Map(financial.map((item) => [item.appointment_id, item])),
    [financial],
  );
  const barberById = useMemo(
    () => new Map(barbers.map((item) => [item.id, item.display_name])),
    [barbers],
  );
  const rescheduledIds = useMemo(
    () =>
      new Set(
        statusEvents
          .filter((event) => event.reason === "appointment_rescheduled")
          .map((event) => event.appointment_id),
      ),
    [statusEvents],
  );

  useEffect(() => {
    const params = new URLSearchParams(window.location.search);
    const customerId = params.get("cliente");
    const subscriptionId = params.get("assinatura");
    if (!customerId) return;
    const customer = customers.find((item) => item.id === customerId);
    if (customer && params.get("aba") === "agendamentos") {
      queueMicrotask(() => {
        setEditing(null);
        setFormOpen(false);
        setHistoryCustomer(customer);
        setHistoryTab("APPOINTMENTS");
        setSubscriptionControlId(null);
      });
      return;
    }
    const subscription = subscriptionId
      ? subscriptions.find((item) => String(item.id) === subscriptionId)
      : null;
    if (customer && subscription) {
      queueMicrotask(() => {
        setEditing(null);
        setFormOpen(false);
        setHistoryCustomer(customer);
        setHistoryTab("SUBSCRIPTIONS");
        setSubscriptionControlId(subscriptionId);
      });
      return;
    }
    if (customer && params.get("aba") === "assinaturas") {
      queueMicrotask(() => {
        setEditing(null);
        setFormOpen(false);
        setHistoryCustomer(customer);
        setHistoryTab("SUBSCRIPTIONS");
        setSubscriptionControlId(null);
      });
      return;
    }
    if (customer) {
      queueMicrotask(() => {
        setEditing(customer);
        setFormOpen(true);
        setCustomerFormTab("details");
        setHistoryCustomer(null);
      });
    }
  }, [customers, subscriptions]);

  function customerAppointments(customerId: string) {
    return appointments
      .filter(
        (appointment) =>
          appointment.customer_id === customerId &&
          appointment.status === "COMPLETED" &&
          (financialByAppointment.get(appointment.id)?.net_paid_cents ?? 0) > 0,
      )
      .sort((left, right) => {
        const leftStart =
          parsePostgresRange(left.service_period)?.start.valueOf() ?? 0;
        const rightStart =
          parsePostgresRange(right.service_period)?.start.valueOf() ?? 0;
        return rightStart - leftStart;
      });
  }

  function lastVisitLabel(customerId: string) {
    const completed = customerAppointments(customerId)
      .filter((appointment) => appointment.status === "COMPLETED")
      .map(
        (appointment) => parsePostgresRange(appointment.service_period)?.start,
      )
      .filter((date): date is Date =>
        Boolean(date && date.valueOf() <= todayTimestamp),
      );
    if (!completed.length) return "Última visita ainda não registrada";
    const days = Math.max(
      0,
      Math.floor(
        (todayTimestamp -
          Math.max(...completed.map((date) => date.valueOf()))) /
          86_400_000,
      ),
    );
    return `Última visita deste cliente foi há ${days} ${days === 1 ? "dia" : "dias"}`;
  }

  function appointmentStatus(appointment: Props["appointments"][number]) {
    if (
      appointment.status === "CONFIRMED" &&
      rescheduledIds.has(appointment.id)
    )
      return "Reagendado";
    const labels: Record<string, string> = {
      COMPLETED: "Atendimento feito",
      CANCELED: "Cancelado",
      NO_SHOW: "Não compareceu",
      CONFIRMED: "Confirmado",
      IN_SERVICE: "Em serviço",
      HELD: "Aguardando pagamento",
      PENDING_PAYMENT: "Pendente de pagamento",
      EXPIRED: "Expirado",
    };
    return labels[appointment.status] ?? appointment.status;
  }

  function openEdit(customer: CustomerRecord) {
    setEditing(customer);
    setFormOpen(true);
    setMessage("");
    setCustomerFormTab("details");
    setDependentDraft({ fullName: "", birthDate: "", relationship: "CHILD" });
  }

  function dependentAge(value: string) { const birth = new Date(`${value}T12:00:00`); const today = new Date(); let age = today.getFullYear() - birth.getFullYear(); if (today < new Date(today.getFullYear(), birth.getMonth(), birth.getDate())) age -= 1; return `${Math.max(0, age)} ${Math.max(0, age) === 1 ? "ano" : "anos"}`; }
  async function saveDependent(customer: CustomerRecord) {
    if (!dependentDraft.fullName.trim() || !dependentDraft.birthDate) return;
    const saved = await runMutation(setMessage, async () => { const input = { p_organization_id: organizationId, p_customer_id: customer.id, p_full_name: dependentDraft.fullName.trim(), p_birth_date: dependentDraft.birthDate, p_relationship: dependentDraft.relationship }; await assertResult(await connectedClient().rpc(dependentDraft.id ? "update_customer_dependent" : "create_customer_dependent", dependentDraft.id ? { ...input, p_dependent_id: dependentDraft.id } : input)); }, "Dependente salvo.");
    if (saved) { setDependentDraft({ fullName: "", birthDate: "", relationship: "CHILD" }); router.refresh(); }
  }
  async function removeDependent(id: string) { const saved = await runMutation(setMessage, async () => { await assertResult(await connectedClient().rpc("delete_customer_dependent", { p_organization_id: organizationId, p_dependent_id: id })); }, "Dependente excluído."); if (saved) router.refresh(); }

  function closeForm() {
    setFormOpen(false);
    setEditing(null);
    setCustomerFormTab("details");
    setDependentDraft({ fullName: "", birthDate: "", relationship: "CHILD" });
  }

  async function submit(event: FormEvent<HTMLFormElement>) {
    event.preventDefault();
    const form = event.currentTarget;
    const data = new FormData(form);
    const rawPhone = String(data.get("phone_e164") ?? "").trim();
    const normalizedPhone = normalizePhoneE164(rawPhone);
    if (rawPhone && !normalizedPhone) {
      showManagerError("Informe um telefone válido com DDD e, se necessário, DDI.");
      return;
    }
    if (!isCpfCnpjValid(String(data.get("cpf_cnpj") ?? ""))) {
      showManagerError("CPF/CNPJ deve ter 11 ou 14 dígitos.");
      return;
    }
    const canonicalPayload = {
      organization_id: organizationId,
      full_name: String(data.get("full_name") ?? "").trim(),
      cpf_cnpj: cpfCnpjDigits(String(data.get("cpf_cnpj") ?? "")) || null,
      phone_e164: normalizedPhone,
      email:
        String(data.get("email") ?? "")
          .trim()
          .toLowerCase() || null,
      birth_date: String(data.get("birth_date") ?? "") || null,
      notes: String(data.get("notes") ?? "").trim() || null,
    };
    const payload = editing?.auth_user_id
      ? { notes: canonicalPayload.notes }
      : canonicalPayload;
    const saved = await runMutation(
      setMessage,
      async () => {
        const client = connectedClient();
        const result = editing
          ? await client
              .from("customers")
              .update(payload)
              .eq("id", editing.id)
              .eq("organization_id", organizationId)
          : await client.from("customers").insert(payload);
        await assertResult(result);
      },
      editing ? "Cliente atualizado." : "Cliente cadastrado.",
    );
    if (saved) {
      form.reset();
      setEditing(null);
      setFormOpen(false);
      router.refresh();
    }
  }

  function openInactivation(customer: CustomerRecord) {
    setPendingInactivation(customer);
    setInactivationReason("");
    setCustomInactivationReason("");
  }

  function closeInactivation() {
    setPendingInactivation(null);
    setInactivationReason("");
    setCustomInactivationReason("");
  }

  async function toggle(customer: CustomerRecord) {
    if (customer.active) return openInactivation(customer);
    const saved = await runMutation(
      setMessage,
      async () => {
        await assertResult(
          await connectedClient()
            .from("customers")
            .update({
              active: true,
              inactivation_reason: null,
              inactivated_at: null,
            })
            .eq("id", customer.id)
            .eq("organization_id", organizationId),
        );
      },
      "Cliente reativado.",
    );
    if (saved) router.refresh();
  }

  async function confirmInactivation() {
    if (!pendingInactivation || !inactivationReason) return;
    const reason =
      inactivationReason === "OTHER"
        ? customInactivationReason.trim()
        : (inactivationReasons.find(
            ([value]) => value === inactivationReason,
          )?.[1] ?? "");
    if (!reason) return;
    const saved = await runMutation(
      setMessage,
      async () => {
        await assertResult(
          await connectedClient()
            .from("customers")
            .update({
              active: false,
              inactivation_reason: reason,
              inactivated_at: new Date().toISOString(),
            })
            .eq("id", pendingInactivation.id)
            .eq("organization_id", organizationId),
        );
      },
      "Cliente inativado.",
    );
    if (saved) {
      closeInactivation();
      router.refresh();
    }
  }

  async function merge(event: FormEvent<HTMLFormElement>) {
    event.preventDefault();
    const data = new FormData(event.currentTarget);
    const sourceId = String(data.get("source_customer_id"));
    const targetId = String(data.get("target_customer_id"));
    const reason = String(data.get("reason") ?? "").trim();
    if (sourceId === targetId) {
      showManagerError("Escolha dois cadastros diferentes.");
      return;
    }
    if (
      !window.confirm(
        "Mesclar estes cadastros? O cadastro de origem será inativado e o histórico migrará para o destino.",
      )
    )
      return;
    const saved = await runMutation(
      setMessage,
      async () => {
        await assertResult(
          await connectedClient().rpc("merge_customers", {
            p_organization_id: organizationId,
            p_source_customer_id: sourceId,
            p_target_customer_id: targetId,
            p_reason: reason,
          }),
        );
      },
      "Cadastros mesclados com auditoria.",
    );
    if (saved) {
      setMergeOpen(false);
      router.refresh();
    }
  }

  async function deletePendingSubscription(subscriptionId: string) {
    if (!window.confirm("Excluir esta assinatura que aguarda decisão do cliente?")) return;
    setDeletingSubscriptionId(subscriptionId);
    const saved = await runMutation(
      setMessage,
      async () => {
        await assertResult(await connectedClient().rpc("delete_pending_customer_subscription_offer", {
          p_organization_id: organizationId,
          p_subscription_id: subscriptionId,
        }));
      },
      "Assinatura pendente excluída.",
    );
    setDeletingSubscriptionId(null);
    if (saved) router.refresh();
  }

  async function saveFixedScheduleEdit(event: FormEvent<HTMLFormElement>) {
    event.preventDefault();
    if (!fixedScheduleEditDraft) return;
    const draft = fixedScheduleEditDraft;
    const saved = await runMutation(
      setMessage,
      async () => {
        await assertResult(await connectedClient().rpc("update_customer_fixed_subscription_schedule", {
          p_organization_id: organizationId,
          p_subscription_id: draft.subscriptionId,
          p_cadence_weeks: Number(draft.cadenceWeeks),
          p_start_date: draft.startDate,
          p_local_time: draft.localTime,
          p_barber_id: draft.barberId,
          p_environment_id: draft.environmentId,
        }));
      },
      "Agendamento fixo atualizado.",
    );
    if (saved) {
      setFixedScheduleEditDraft(null);
      router.refresh();
    }
  }

  async function approveSubscription() {
    if (!approvalDraft) return;
    const { subscriptionId, startDate, dueDate } = approvalDraft;
    if (!startDate || !dueDate) {
      showManagerError("Informe a data de início e o primeiro vencimento.");
      return;
    }
    const saved = await runMutation(
      setMessage,
      async () => {
        await assertResult(
          await connectedClient().rpc("activate_customer_subscription", {
            p_organization_id: organizationId,
            p_subscription_id: subscriptionId,
            p_start_date: startDate,
            p_first_due_date: dueDate,
            p_idempotency_key: `manager-approval-${subscriptionId}-${startDate}`,
          }),
        );
      },
      "Assinatura aprovada. Registre a primeira parcela para liberar as sessões.",
    );
    if (saved) {
      setApprovalDraft(null);
      router.refresh();
    }
  }

  async function confirmManualSubscriptionActivation() {
    if (!manualSubscriptionActivationDraft) return;
    const { subscriptionId } = manualSubscriptionActivationDraft;
    const saved = await runMutation(
      setMessage,
      async () => {
        await assertResult(await connectedClient().rpc("manager_activate_customer_subscription_without_acceptance", {
          p_organization_id: organizationId,
          p_subscription_id: subscriptionId,
        }));
      },
      "Plano ativado para organização da agenda. O aceite do contrato continua pendente.",
    );
    if (saved) {
      setManualSubscriptionActivationDraft(null);
      setSubscriptionControlId(subscriptionId);
      router.refresh();
    }
  }

  async function confirmSubscriptionCancellation(event: FormEvent<HTMLFormElement>) {
    event.preventDefault();
    if (!subscriptionCancellationDraft) return;
    const draft = subscriptionCancellationDraft;
    if (!draft.requestId && (!draft.reason || (draft.reason === "OTHER" && !draft.observations.trim()))) {
      showManagerError("Informe o motivo do cancelamento. Para “Outros”, preencha as observações.");
      return;
    }
    const saved = await runMutation(
      setMessage,
      async () => {
        await assertResult(await connectedClient().rpc("confirm_customer_subscription_cancellation", {
          p_organization_id: organizationId,
          p_subscription_id: draft.subscriptionId,
          p_last_cycle_id: draft.lastCycleId && draft.lastCycleId !== "__none__" ? draft.lastCycleId : null,
          p_last_session_id: draft.lastSessionId || null,
          p_reason: draft.reason || "OTHER",
          p_observations: draft.observations || null,
          p_request_id: draft.requestId,
        }));
      },
      "Cancelamento confirmado. As dívidas existentes foram preservadas até o limite escolhido.",
    );
    if (saved) {
      setSubscriptionCancellationDraft(null);
      setSubscriptionControlId(null);
      router.refresh();
    }
  }

  async function deleteSubscriptionCycle() {
    const cycle = subscriptionCycleDeleteTarget;
    if (!cycle || deletingSubscriptionCycle) return;
    setDeletingSubscriptionCycle(true);
    const saved = await runMutation(setMessage, async () => {
      await assertResult(await connectedClient().rpc("delete_open_subscription_cycle", {
        p_organization_id: organizationId,
        p_subscription_id: String(cycle.subscription_id),
        p_cycle_id: String(cycle.id),
      }));
    }, "Parcela excluída. Sessões disponíveis deste ciclo foram canceladas.");
    setDeletingSubscriptionCycle(false);
    if (saved) {
      setSubscriptionCycleDeleteTarget(null);
      router.refresh();
    }
  }

  async function deleteSubscriptionBundleInstallment() {
    const installment = subscriptionBundleInstallmentDeleteTarget;
    if (!installment || deletingSubscriptionCycle) return;
    setDeletingSubscriptionCycle(true);
    const saved = await runMutation(setMessage, async () => {
      await assertResult(await connectedClient().rpc("cancel_subscription_bundle_installment", {
        p_organization_id: organizationId,
        p_subscription_id: String(installment.subscription_id),
        p_installment_id: String(installment.id),
      }));
    }, "Parcela cancelada. O histórico financeiro foi preservado.");
    setDeletingSubscriptionCycle(false);
    if (saved) {
      setSubscriptionBundleInstallmentDeleteTarget(null);
      router.refresh();
    }
  }

  async function saveSubscriptionInstallmentEdit(event: FormEvent<HTMLFormElement>) {
    event.preventDefault();
    const draft = subscriptionInstallmentEdit;
    if (!draft || savingSubscriptionInstallmentEdit) return;
    const amountCents = safeBundleCentsInput(draft.amount);
    if (amountCents <= 0 || !draft.dueOn) {
      showManagerError("Informe um valor maior que zero e a data de vencimento.");
      return;
    }
    setSavingSubscriptionInstallmentEdit(true);
    const saved = await runMutation(setMessage, async () => {
      const procedure = draft.kind === "BUNDLE" ? "update_subscription_bundle_installment" : "update_open_subscription_cycle";
      await assertResult(await connectedClient().rpc(procedure, {
        p_organization_id: organizationId,
        p_subscription_id: draft.subscriptionId,
        [draft.kind === "BUNDLE" ? "p_installment_id" : "p_cycle_id"]: draft.installmentId,
        p_amount_cents: amountCents,
        p_due_on: draft.dueOn,
      }));
    }, "Parcela atualizada no contrato e em Contas a receber.");
    setSavingSubscriptionInstallmentEdit(false);
    if (saved) {
      setSubscriptionInstallmentEdit(null);
      router.refresh();
    }
  }

  async function recordFirstPayment(
    subscriptionId: string,
    cycleId: string,
    amountCents: number,
    method: string,
    financialAccountId = String(financialAccounts[0]?.id ?? ""),
    paidOn = new Date().toISOString().slice(0, 10),
    externalReference = "",
  ) {
    const chart = (chartAccounts as Array<{ id: string; name?: string }>)[0];
    if (!chart) {
      showManagerError("Cadastre uma conta de receita antes de registrar a parcela.");
      return false;
    }
    const saved = await runMutation(
      setMessage,
      async () => {
        await assertResult(
          await connectedClient().rpc("record_subscription_payment", {
            p_organization_id: organizationId,
            p_subscription_id: subscriptionId,
            p_cycle_id: cycleId,
            p_amount_cents: amountCents,
            p_method: method,
            p_idempotency_key: `manager-payment-${cycleId}`,
            p_chart_account_id: chart.id,
            p_financial_account_id: financialAccountId,
            p_paid_on: paidOn,
            p_external_reference: externalReference || null,
          }),
        );
      },
      "Parcela registrada e assinatura ativada.",
    );
    if (saved) router.refresh();
    return saved;
  }

  function preparePaymentReceipt(subscriptionId: string, installmentNumber: unknown, paymentMethod: string, installmentKind = "INSTALLMENT") {
    const subscription = subscriptions.find((item) => String(item.id) === subscriptionId);
    const plan = subscription?.plan as { name?: unknown } | null | undefined;
    const planName = typeof plan?.name === "string" ? plan.name : "Plano de assinatura";
    const contractNumber = String(subscription?.contract_number ?? subscriptionId.slice(0, 8).toUpperCase());
    const sequence = Math.max(0, Number(installmentNumber ?? 0));
    const installmentLabel = installmentKind === "ENTRY" ? "Entrada" : `Parcela ${sequence || 1}`;
    const revenueAccount = (chartAccounts as Array<{ id: string; kind?: string; active?: boolean; code?: string | null; name?: string }>).find((item) => item.active && item.kind === "REVENUE" && (item.code === "1" || /receita/i.test(item.name ?? "")))
      ?? (chartAccounts as Array<{ id: string; kind?: string; active?: boolean }>).find((item) => item.active && item.kind === "REVENUE");
    setPaymentDate(todayInOrganization);
    setPaymentMethod(paymentMethod || "CASH");
    setPaymentAccountId(String(financialAccounts.find((item) => item.active)?.id ?? ""));
    setPaymentChartAccountId(String(revenueAccount?.id ?? ""));
    setPaymentCostCenterId("");
    setPaymentTagIds([]);
    setPaymentReference("");
    setPaymentDescription(`${planName} · Contrato nº ${contractNumber} · ${installmentLabel}`);
    setPaymentDocumentNumber(`SUB-${subscriptionId.slice(0, 8).toUpperCase()}-${sequence || 1}`);
  }

  function openPaymentDialog(subscriptionId: string, cycle: { id: unknown; cycle_number?: unknown; amount_cents?: unknown; due_on?: unknown }, method: string) {
    setPaymentTarget({ kind: "LEGACY", subscriptionId, cycleId: String(cycle.id), amountCents: Number(cycle.amount_cents ?? 0), dueOn: String(cycle.due_on ?? "") });
    preparePaymentReceipt(subscriptionId, cycle.cycle_number, method);
  }

  function openBundlePaymentDialog(subscriptionId: string, installment: Record<string, unknown>, method: string) {
    setPaymentTarget({ kind: "BUNDLE", subscriptionId, installmentId: String(installment.id), amountCents: Number(installment.amount_cents ?? 0), dueOn: String(installment.due_on ?? ""), idempotencyKey: `manager-bundle-payment-${crypto.randomUUID()}` });
    preparePaymentReceipt(subscriptionId, installment.installment_number, method, String(installment.kind ?? "INSTALLMENT"));
  }

  async function recordSubscriptionPaymentTarget() {
    const target = paymentTarget;
    if (!target) return false;
    if (!paymentChartAccountId) {
      showManagerError("Cadastre uma conta de receita antes de registrar a parcela.");
      return false;
    }
    if (!paymentAccountId) {
      showManagerError("Selecione a conta financeira que recebeu o pagamento.");
      return false;
    }
    const saved = await runMutation(
      setMessage,
      async () => {
        const receiptFields = {
          p_organization_id: organizationId,
          p_amount_cents: target.amountCents,
          p_chart_account_id: paymentChartAccountId,
          p_financial_account_id: paymentAccountId,
          p_external_reference: paymentReference || null,
          p_paid_on: paymentDate,
          p_cost_center_id: paymentCostCenterId || null,
          p_document_number: paymentDocumentNumber.trim() || null,
          p_tag_ids: paymentTagIds,
          p_description: paymentDescription.trim(),
        };
        if (target.kind === "BUNDLE") {
          await assertResult(await connectedClient().rpc("record_subscription_bundle_payment_with_receipt_metadata", {
            ...receiptFields,
            p_installment_id: target.installmentId,
            p_method: paymentMethod,
            p_idempotency_key: target.idempotencyKey,
          }));
        } else {
          await assertResult(await connectedClient().rpc("record_subscription_payment_with_receipt_metadata", {
            ...receiptFields,
            p_subscription_id: target.subscriptionId,
            p_cycle_id: target.cycleId,
            p_method: paymentMethod,
            p_idempotency_key: `manager-payment-${target.cycleId}`,
          }));
        }
      },
      "Recebimento confirmado e enviado ao Financeiro.",
    );
    if (saved) router.refresh();
    return saved;
  }

  function eligibleSubscriptionBarbers(serviceIds: string[], planId?: string) {
    return barbers.filter((barber) => barber.active && (!planId || barberSubscriptionPlans.some((link) =>
      String(link.barber_id) === barber.id && String(link.plan_id) === planId && link.active !== false
    )) && serviceIds.every((serviceId) =>
      barberServices.some((link) =>
        String(link.barber_id) === barber.id &&
        String(link.service_id) === serviceId &&
        link.active !== false,
      ),
    ));
  }

  function fixedScheduleSlots(serviceIds: string[], barberId: string, startDate: string, durationOverride?: number): FixedScheduleSlot[] {
    const weekday = weekdayForDate(startDate);
    const barber = barbers.find((item) => item.id === barberId);
    if (weekday === null || !barber || serviceIds.length === 0) return [];

    const currentServices = serviceIds.map((serviceId) => subscriptionServiceDurations.find((item) => item.id === serviceId && item.active));
    if (currentServices.some((service) => !service)) return [];
    const serviceDuration = durationOverride ?? currentServices.reduce((total, service) => total + Number(service?.duration_minutes ?? 0), 0);
    const slotSize = Math.max(1, Number(slotIntervalMinutes) || 15);
    if (serviceDuration <= 0) return [];
    const occupiedMinutes = Math.ceil(serviceDuration / slotSize) * slotSize;
    const slots: FixedScheduleSlot[] = [];

    for (const interval of workIntervals) {
      if (String(interval.barber_id) !== barberId || Number(interval.weekday) !== weekday || interval.active === false) continue;
      const environmentId = String(interval.environment_id ?? "");
      const environment = agendaEnvironments.find((item) => item.id === environmentId && item.location_id === barber.location_id);
      const intervalStart = minutesFromTime(interval.starts_at);
      const intervalEnd = minutesFromTime(interval.ends_at);
      if (!environment || intervalStart === null || intervalEnd === null) continue;

      let startMinute = Math.ceil(intervalStart / slotSize) * slotSize;
      while (startMinute + occupiedMinutes <= intervalEnd) {
        slots.push({ time: timeFromMinutes(startMinute), environmentId, environmentName: environment.name });
        startMinute += slotSize;
      }
    }

    return slots.sort((left, right) => left.time.localeCompare(right.time) || left.environmentName.localeCompare(right.environmentName));
  }

  function firstFixedScheduleSlot(serviceIds: string[], barberId: string, startDate: string, preferredTime = "", preferredEnvironmentId = "") {
    const slots = fixedScheduleSlots(serviceIds, barberId, startDate);
    return slots.find((slot) => slot.time === preferredTime && slot.environmentId === preferredEnvironmentId)
      ?? slots.find((slot) => slot.time === preferredTime)
      ?? slots[0]
      ?? null;
  }

  function dateForWeekday(weekday: number) {
    const [year, month, day] = todayInOrganization.split("-").map(Number);
    const value = new Date(Date.UTC(year, month - 1, day));
    value.setUTCDate(value.getUTCDate() + ((weekday - value.getUTCDay() + 7) % 7));
    return value.toISOString().slice(0, 10);
  }

  function addMonthClamped(value: string) {
    const [year, month, day] = value.split("-").map(Number);
    const target = new Date(Date.UTC(year, month, 1));
    const lastDay = new Date(Date.UTC(target.getUTCFullYear(), target.getUTCMonth() + 1, 0)).getUTCDate();
    target.setUTCDate(Math.min(day, lastDay));
    return target.toISOString().slice(0, 10);
  }

  function openBundleOffer(customerId: string, planId = "") {
    const plan = subscriptionBundlePlans.find((item) => item.id === planId) ?? subscriptionBundlePlans[0];
    if (!plan) {
      showManagerError("Cadastre um plano V2 ativo antes de enviar uma oferta.");
      return;
    }
    const count = plan.version.bundle_scheduling_mode === "FIXED" ? Number(plan.version.bundle_sessions_per_week ?? 1) : 0;
    const financialDraft = bundleFinancialDraft(plan);
    setBundleOfferDraft({
      customerId,
      planId: plan.id,
      firstSessionDate: todayInOrganization,
      entryDueDate: safeBundleCentsInput(financialDraft.entry) > 0 ? todayInOrganization : "",
      firstInstallmentDueDate: addMonthClamped(todayInOrganization),
      idempotencyKey: `manager-bundle-offer-${crypto.randomUUID()}`,
      slots: Array.from({ length: count }, (_, index) => ({ slotNumber: index + 1, barberId: "", weekday: "", localTime: "", environmentId: "" })),
      ...financialDraft,
      activeTab: "SESSIONS",
    });
    setBundleOfferConfirmationOpen(false);
    setMessage("");
  }

  function updateBundleOfferPlan(planId: string) {
    const plan = subscriptionBundlePlans.find((item) => item.id === planId);
    if (!plan) return;
    const count = plan.version.bundle_scheduling_mode === "FIXED" ? Number(plan.version.bundle_sessions_per_week ?? 1) : 0;
    const financialDraft = bundleFinancialDraft(plan);
    setBundleOfferDraft((current) => current ? {
      ...current,
      planId,
      slots: Array.from({ length: count }, (_, index) => current.slots[index] ?? ({ slotNumber: index + 1, barberId: "", weekday: "", localTime: "", environmentId: "" })),
      entryDueDate: safeBundleCentsInput(financialDraft.entry) > 0 ? current.entryDueDate || todayInOrganization : "",
      firstInstallmentDueDate: safeBundleCentsInput(financialDraft.entry) > 0
        && current.firstInstallmentDueDate < (current.entryDueDate || todayInOrganization)
        ? addMonthClamped(current.entryDueDate || todayInOrganization)
        : current.firstInstallmentDueDate,
      ...financialDraft,
      activeTab: "SESSIONS",
    } : current);
  }

  function updateBundleOfferEntry(value: string) {
    let entryCents: number | null = null;
    if (!value.trim()) {
      entryCents = 0;
    } else {
      try {
        entryCents = centsFromInput(value);
      } catch {
        // Keep the date as-is while the manager is entering a partial amount.
      }
    }
    setBundleOfferDraft((current) => {
      if (!current) return current;
      if (entryCents === null) return { ...current, entry: value };
      if (entryCents <= 0) return { ...current, entry: value, entryDueDate: "" };
      const entryDueDate = current.entryDueDate || todayInOrganization;
      return {
        ...current,
        entry: value,
        entryDueDate,
        firstInstallmentDueDate: current.firstInstallmentDueDate < entryDueDate
          ? addMonthClamped(entryDueDate)
          : current.firstInstallmentDueDate,
      };
    });
  }

  function advanceBundleOffer() {
    setBundleOfferDraft((current) => current ? {
      ...current,
      activeTab: current.activeTab === "SESSIONS" ? "FINANCIAL" : "REVIEW",
    } : current);
  }

  async function submitBundleOffer(sendWhatsAppNotice: boolean) {
    const draft = bundleOfferDraft;
    if (!draft) return;
    setBundleOfferConfirmationOpen(false);
    const plan = subscriptionBundlePlans.find((item) => item.id === draft.planId);
    if (!plan) return;
    let entryCents: number;
    try {
      entryCents = draft.entry.trim() ? centsFromInput(draft.entry) : 0;
    } catch {
      showManagerError("Informe um valor de entrada válido ou deixe o campo vazio.");
      return;
    }
    if (!draft.firstSessionDate || draft.firstSessionDate < todayInOrganization) {
      showManagerError("A primeira sessão deve ser hoje ou em uma data futura.");
      return;
    }
    if (!draft.firstInstallmentDueDate || draft.firstInstallmentDueDate < todayInOrganization) {
      showManagerError("A primeira parcela deve vencer hoje ou em uma data futura.");
      return;
    }
    if (entryCents > 0 && !draft.entryDueDate) {
      showManagerError("Informe o vencimento da entrada ou deixe o valor da entrada zerado.");
      return;
    }
    if (entryCents > 0 && draft.entryDueDate < todayInOrganization) {
      showManagerError("O vencimento da entrada não pode estar no passado.");
      return;
    }
    if (entryCents > 0 && draft.firstInstallmentDueDate < draft.entryDueDate) {
      showManagerError("A primeira parcela deve vencer na data da entrada ou depois.");
      return;
    }
    const fixedSlots = plan.version.bundle_scheduling_mode === "FIXED"
      ? draft.slots.map((slot) => ({ barber_id: slot.barberId, environment_id: slot.environmentId, weekday: Number(slot.weekday), local_time: slot.localTime }))
      : [];
    if (plan.version.bundle_scheduling_mode === "FIXED" && fixedSlots.some((slot) => !slot.barber_id || !slot.environment_id || !slot.local_time || !Number.isInteger(slot.weekday))) {
      showManagerError("Complete profissional, sala, dia e horário de cada sessão fixa.");
      return;
    }
    let financialOverrides: {
      total_sessions: number;
      price_per_session_cents: number;
      entry_cents: number;
      installment_count: number;
      discount_type: BundleDiscountType;
      discount_value: number;
      payment_method: string;
    };
    try {
      const totalSessions = Number(draft.totalSessions);
      const pricePerSessionCents = centsFromInput(draft.pricePerSession);
      const installmentCount = Number(draft.installmentCount);
      const discountValue = draft.discountType === "PERCENT"
        ? Math.round(Number(draft.discountValue.replace(",", ".")) * 100)
        : draft.discountType === "FIXED" ? centsFromInput(draft.discountValue) : 0;
      const totalPriceCents = pricePerSessionCents * totalSessions;
      const installmentBaseCents = Math.floor(totalPriceCents / installmentCount);
      const discountCents = draft.discountType === "PERCENT"
        ? Math.round(installmentBaseCents * discountValue / 10000)
        : draft.discountType === "FIXED" ? discountValue : 0;
      const paymentMethod = draft.paymentMethod.toUpperCase();
      if (!Number.isInteger(totalSessions) || totalSessions < 1 || totalSessions > 300
        || !Number.isSafeInteger(pricePerSessionCents) || pricePerSessionCents <= 0
        || !Number.isSafeInteger(totalPriceCents) || totalPriceCents <= 0
        || !Number.isSafeInteger(entryCents) || entryCents < 0
        || !Number.isInteger(installmentCount) || installmentCount < 1 || installmentCount > 24
        || installmentBaseCents < 1
        || !Number.isInteger(discountValue) || discountValue < 0
        || (draft.discountType === "NONE" && discountValue !== 0)
        || (draft.discountType === "FIXED" && (discountValue <= 0 || discountValue >= installmentBaseCents))
        || (draft.discountType === "PERCENT" && (discountValue < 1 || discountValue > 9999 || discountCents >= installmentBaseCents))
        || !["ONLINE", "CARD", "PIX", "BOLETO", "CASH", "CRYPTO"].includes(paymentMethod)) {
        showManagerError("Confira os valores financeiros: sessões (1 a 300), parcelas (1 a 24), valores positivos e desconto menor que a parcela.");
        return;
      }
      financialOverrides = {
        total_sessions: totalSessions,
        price_per_session_cents: pricePerSessionCents,
        entry_cents: entryCents,
        installment_count: installmentCount,
        discount_type: draft.discountType,
        discount_value: discountValue,
        payment_method: paymentMethod,
      };
    } catch (error) {
      showManagerError(error instanceof Error ? error.message : "Confira os valores financeiros da oferta.");
      return;
    }
    setBundleOfferSending(true);
    let whatsappNoticeQueued = false;
    try {
      const saved = await runMutation(setMessage, async () => {
        const result = await connectedClient().rpc("create_subscription_bundle_offer_with_notice", {
          p_organization_id: organizationId,
          p_customer_id: draft.customerId,
          p_plan_id: draft.planId,
          p_first_session_date: draft.firstSessionDate,
          p_entry_due_on: financialOverrides.entry_cents > 0 ? draft.entryDueDate : null,
          p_first_installment_due_on: draft.firstInstallmentDueDate,
          p_fixed_slots: { slots: fixedSlots, financial: financialOverrides },
          p_idempotency_key: draft.idempotencyKey,
          p_send_whatsapp_notice: sendWhatsAppNotice,
        });
        await assertResult(result);
        const response = result.data as { whatsapp_notice_queued?: boolean } | null;
        whatsappNoticeQueued = response?.whatsapp_notice_queued === true;
      }, "Oferta criada no app do cliente.");
      if (saved) {
        setBundleOfferDraft(null);
        setMessage(sendWhatsAppNotice
          ? whatsappNoticeQueued
            ? "Oferta criada e aviso adicionado à fila do WhatsApp."
            : "Oferta criada. O aviso não entrou na fila: confira o consentimento do cliente, o telefone e a conexão do WhatsApp."
          : "Oferta criada no app do cliente.");
        router.refresh();
      }
    } finally {
      setBundleOfferSending(false);
    }
  }

  function openSubscriptionBooking(
    subscription: Record<string, unknown>,
    session: Record<string, unknown>,
    cycle: Record<string, unknown>,
  ) {
    const plan = subscription.plan as { name?: string | null } | null;
    const version = subscription.plan_version as { id?: string } | null;
    const planServices = subscriptionPlanServices
      .filter((item) => String(item.plan_version_id) === String(version?.id ?? ""))
      .sort((left, right) => Number(left.position ?? 0) - Number(right.position ?? 0));
    const serviceIds = planServices.map((item) => String(item.service_id));
    const eligible = eligibleSubscriptionBarbers(serviceIds, String(subscription.plan_id ?? "") || undefined);
    if (!version?.id || serviceIds.length === 0 || eligible.length === 0) {
      showManagerError("Nenhum profissional habilitado para os serviços deste plano.");
      return;
    }
    const tomorrow = new Date(todayTimestamp + 86_400_000).toISOString().slice(0, 10);
    setSubscriptionBooking({
      mode: "BOOK",
      appointmentId: null,
      subscriptionId: String(subscription.id),
      sessionId: String(session.id),
      customerId: String(subscription.customer_id),
      sessionNumber: Number(session.session_number ?? 0),
      totalSessions: Number((subscription.plan_version as { sessions_per_cycle?: number } | null)?.sessions_per_cycle ?? 0),
      referenceDate: String(cycle.starts_on ?? ""),
      planName: String(plan?.name ?? "Plano de assinatura"),
      serviceNames: planServices.map((item) => String(item.service_name_snapshot)),
      serviceIds,
    });
    setSubscriptionBookingDate(tomorrow);
    setSubscriptionBookingTime("09:00");
    setSubscriptionBookingBarberId(eligible[0]?.id ?? "");
    setSubscriptionOverdueReason("");
  }

  function openSubscriptionSessionReschedule(
    subscription: Record<string, unknown>,
    session: Record<string, unknown>,
    appointmentId: string,
  ) {
    const plan = subscription.plan as { name?: string | null } | null;
    const version = subscription.plan_version as { id?: string; scheduling_mode?: string; sessions_per_cycle?: number } | null;
    const appointment = appointments.find((item) => item.id === appointmentId);
    const range = appointment ? parsePostgresRange(appointment.service_period) : null;
    const planServices = subscriptionPlanServices
      .filter((item) => String(item.plan_version_id) === String(version?.id ?? ""))
      .sort((left, right) => Number(left.position ?? 0) - Number(right.position ?? 0));
    if (version?.scheduling_mode !== "FIXED" || !appointment || appointment.status !== "CONFIRMED" || !range) {
      showManagerError("Esta sessão não pode ser reagendada por este modal.");
      return;
    }
    const localStart = localDateTimeInputs(range.start, timezone);
    setSubscriptionBooking({
      mode: "RESCHEDULE",
      appointmentId,
      subscriptionId: String(subscription.id),
      sessionId: String(session.id),
      customerId: String(subscription.customer_id),
      sessionNumber: Number(session.session_number ?? 0),
      totalSessions: Number(version.sessions_per_cycle ?? 0),
      referenceDate: localStart.date,
      planName: String(plan?.name ?? "Plano de assinatura"),
      serviceNames: planServices.map((item) => String(item.service_name_snapshot)),
      serviceIds: planServices.map((item) => String(item.service_id)),
    });
    setSubscriptionBookingDate(localStart.date);
    setSubscriptionBookingTime(localStart.time);
    setSubscriptionBookingBarberId(appointment.barber_id);
    setSubscriptionOverdueReason("");
  }

  async function bookSubscriptionSession(event: FormEvent<HTMLFormElement>) {
    event.preventDefault();
    if (!subscriptionBooking || !subscriptionBookingBarberId) return;
    const saved = await runMutation(
      setMessage,
      async () => {
        const startsAt = subscriptionBooking.mode === "RESCHEDULE"
          ? localDateTimeToIso(`${subscriptionBookingDate}T${subscriptionBookingTime}`, timezone)
          : new Date(`${subscriptionBookingDate}T${subscriptionBookingTime}:00`).toISOString();
        if (subscriptionBooking.mode === "RESCHEDULE" && subscriptionBooking.appointmentId) {
          await assertResult(await connectedClient().rpc("reschedule_fixed_customer_subscription_session", {
            p_organization_id: organizationId,
            p_subscription_session_id: subscriptionBooking.sessionId,
            p_new_starts_at: startsAt,
          }));
          return;
        }
        await assertResult(await connectedClient().rpc(subscriptionOverdueReason.trim()
          ? "book_customer_subscription_session_with_overdue_override"
          : "book_customer_subscription_session", {
          p_organization_id: organizationId,
          p_customer_id: subscriptionBooking.customerId,
          p_subscription_session_id: subscriptionBooking.sessionId,
          p_barber_id: subscriptionBookingBarberId,
          p_starts_at: startsAt,
          ...(subscriptionOverdueReason.trim() ? { p_reason: subscriptionOverdueReason.trim() } : {}),
        }));
      },
      subscriptionBooking.mode === "RESCHEDULE" ? "Sessão da assinatura reagendada." : "Sessão da assinatura agendada.",
    );
    if (saved) {
      setSubscriptionBooking(null);
      router.refresh();
    }
  }

  function sessionPresentation(session: { status?: unknown; session_number?: unknown; appointment_id?: unknown }, totalSessions: number) {
    const appointment = appointments.find((item) => item.id === String(session.appointment_id ?? ""));
    const start = appointment ? parsePostgresRange(appointment.service_period)?.start : null;
    const base = `${String(session.session_number ?? "—")} de ${totalSessions}`;
    const label = session.status === "SCHEDULED" || session.status === "COMPLETED"
      ? (start ? `${base} | ${new Intl.DateTimeFormat("pt-BR", { timeZone: timezone, day: "2-digit", month: "2-digit" }).format(start)}` : `${base} | Agendada`)
      : `${String(session.session_number ?? "—")} de ${totalSessions}`;
    return { label, tone: session.status === "COMPLETED" ? "completed" : session.status === "CANCELED" || session.status === "CONSUMED" ? "canceled" : session.status === "AVAILABLE" ? "available" : "scheduled" };
  }

  const fixedScheduleEditSlots = fixedScheduleEditDraft
    ? fixedScheduleSlots(fixedScheduleEditDraft.serviceIds, fixedScheduleEditDraft.barberId, fixedScheduleEditDraft.startDate)
    : [];
  const fixedScheduleEditTimes = [...new Set(fixedScheduleEditSlots.map((slot) => slot.time))];
  const fixedScheduleEditRooms = fixedScheduleEditSlots.filter((slot) => slot.time === fixedScheduleEditDraft?.localTime);

  return (
    <div className={styles.stack}>
      <PageHeader
        title="Clientes"
      />
      <Panel
        title="Base de clientes"
        description={subscriptionFilter === "ALL"
          ? `${customers.filter((item) => item.active).length} ativos`
          : `${filtered.length} clientes · ${subscriptionFilterLabels[subscriptionFilter]}`}
        action={
          <button
            className={styles.button}
            type="button"
            onClick={() => {
              setEditing(null);
              setCustomerFormTab("details");
              setFormOpen(true);
            }}
          >
            Novo cliente
          </button>
        }
      >
        <ActionMessage
          message={message}
          tone={
            message.toLowerCase().includes("erro") ||
            message.toLowerCase().includes("negado")
              ? "error"
              : "info"
          }
        />
        <div className={styles.customerToolbar}>
          <div className={styles.customerFilters}>
            <select
              aria-label="Filtro de clientes"
              className="customer-filter"
              value={customerFilter}
              onChange={(event) =>
                setCustomerFilter(event.target.value as CustomerFilter)
              }
            >
              <option value="ACTIVE">Ativos</option>
              <option value="INACTIVE">Inativos</option>
            </select>
            {subscriptionModuleEnabled && (
              <select
                aria-label="Filtro de assinaturas"
                className={`${styles.customerSubscriptionFilter} customer-filter`}
                value={subscriptionFilter}
                onChange={(event) =>
                  setSubscriptionFilter(event.target.value as SubscriptionFilter)
                }
              >
                {(Object.entries(subscriptionFilterLabels) as [SubscriptionFilter, string][]).map(([value, label]) => (
                  <option key={value} value={value}>{label}</option>
                ))}
              </select>
            )}
          </div>
          <label className={`${styles.field} ${styles.customerSearch}`}>
            <span>Buscar</span>
            <input
              value={query}
              onChange={(event) => setQuery(event.target.value)}
              placeholder="Nome, telefone ou e-mail"
            />
          </label>
          {customers.length > 1 && (
            <button
              className={`${styles.button} ${styles.buttonSoft}`}
              type="button"
              onClick={() => setMergeOpen((value) => !value)}
            >
              Mesclar cadastros
            </button>
          )}
        </div>
        {mergeOpen && (
          <form className={styles.form} onSubmit={merge}>
            <Field label="Cadastro de origem">
              <select name="source_customer_id" required>
                {customers.map((customer) => (
                  <option key={customer.id} value={customer.id}>
                    {customer.full_name} ·{" "}
                    {customer.phone_e164 ?? customer.email ?? "sem contato"}
                  </option>
                ))}
              </select>
            </Field>
            <Field label="Cadastro de destino">
              <select
                name="target_customer_id"
                required
                defaultValue={customers[1]?.id}
              >
                {customers.map((customer) => (
                  <option key={customer.id} value={customer.id}>
                    {customer.full_name} ·{" "}
                    {customer.phone_e164 ?? customer.email ?? "sem contato"}
                  </option>
                ))}
              </select>
            </Field>
            <Field label="Motivo" wide>
              <input
                name="reason"
                required
                minLength={3}
                maxLength={500}
                placeholder="Duplicidade confirmada pelo gestor"
              />
            </Field>
            <div className={`${styles.toolbarGroup} ${styles.formWide}`}>
              <button className={styles.button}>Mesclar com auditoria</button>
              <button
                className={`${styles.button} ${styles.buttonSoft}`}
                type="button"
                onClick={() => setMergeOpen(false)}
              >
                Cancelar
              </button>
            </div>
          </form>
        )}
        {formOpen && (
          <div className="modal-layer" role="presentation">
            <button
              className="modal-layer__backdrop"
              type="button"
              aria-label="Fechar"
              onClick={closeForm}
            />
            <form
              className="form-modal form-modal--customer"
              role="dialog"
              aria-modal="true"
              aria-label={editing ? "Editar cliente" : "Novo cliente"}
              onSubmit={submit}
              key={editing?.id ?? "new"}
            >
              <div className="form-modal__head">
                <span>
                  <small>{editing ? "Editar cliente" : "Novo cliente"}</small>
                  <strong>
                    {editing ? "Atualize os dados" : "Cadastre um cliente"}
                  </strong>
                  <em>{editing ? "Mantenha o cadastro e os dependentes organizados." : "Preencha os dados principais do cliente."}</em>
                </span>
                <button
                  type="button"
                  className="icon-button"
                  onClick={closeForm}
                  aria-label="Fechar"
                >
                  <X size={19} />
                </button>
              </div>
              <div className="form-modal__body customer-modal__body">
                <div className="customer-modal__tabs" role="tablist" aria-label="Dados do cliente">
                  <button type="button" id="customer-details-tab" role="tab" aria-selected={customerFormTab === "details"} aria-controls="customer-details-panel" className={customerFormTab === "details" ? "is-active" : ""} onClick={() => setCustomerFormTab("details")}>Dados do cliente</button>
                  <button type="button" id="customer-dependents-tab" role="tab" aria-selected={customerFormTab === "dependents"} aria-controls={editing ? "customer-dependents-panel" : undefined} className={customerFormTab === "dependents" ? "is-active" : ""} disabled={!editing} onClick={() => setCustomerFormTab("dependents")}>
                    Dependentes <span>{editing ? `${editing.dependents?.length ?? 0}/8` : "Após salvar"}</span>
                  </button>
                </div>
                {!editing && <p className="customer-modal__hint">Salve o cliente para liberar o cadastro de dependentes.</p>}
                <section id="customer-details-panel" className="customer-modal__panel" role="tabpanel" aria-labelledby="customer-details-tab" hidden={customerFormTab !== "details"}>
                  {editing?.auth_user_id && (
                    <p className="customer-canonical-notice">
                      Dados controlados pelo cliente. Nome, telefone, e-mail e
                      nascimento são atualizados pela conta global.
                    </p>
                  )}
                  <div className="customer-modal__grid">
                    <Field label="Nome completo">
                      <input
                        name="full_name"
                        required
                        minLength={2}
                        maxLength={160}
                        defaultValue={editing?.full_name}
                        disabled={Boolean(editing?.auth_user_id)}
                      />
                    </Field>
                    <Field label="CPF/CNPJ">
                      <input name="cpf_cnpj" inputMode="numeric" placeholder="CPF ou CNPJ" defaultValue={editing?.cpf_cnpj ? formatCpfCnpj(editing.cpf_cnpj) : ""} disabled={Boolean(editing?.auth_user_id)} onChange={(event) => { event.currentTarget.value = formatCpfCnpj(event.currentTarget.value); }} />
                    </Field>
                    <Field label="Telefone">
                      <input
                        name="phone_e164"
                        inputMode="tel"
                        placeholder="11999999999 ou +5511999999999"
                        pattern="[+0-9][0-9\s().-]{7,20}"
                        defaultValue={editing?.phone_e164 ?? ""}
                        disabled={Boolean(editing?.auth_user_id)}
                      />
                    </Field>
                    <Field label="E-mail">
                      <input
                        name="email"
                        type="email"
                        defaultValue={editing?.email ?? ""}
                        disabled={Boolean(editing?.auth_user_id)}
                      />
                    </Field>
                    <Field label="Nascimento (opcional)">
                      <input
                        name="birth_date"
                        type="date"
                        defaultValue={editing?.birth_date ?? ""}
                        disabled={Boolean(editing?.auth_user_id)}
                      />
                    </Field>
                    <Field label="Observações" wide>
                      <textarea
                        name="notes"
                        maxLength={1000}
                        defaultValue={editing?.notes ?? ""}
                      />
                    </Field>
                  </div>
                </section>
                {editing && <section id="customer-dependents-panel" className="customer-modal__panel customer-modal__dependents" role="tabpanel" aria-labelledby="customer-dependents-tab" hidden={customerFormTab !== "dependents"}>
                  <header className="customer-modal__section-head">
                    <span><strong>Dependentes do cliente</strong><small>Cadastre até 8 pessoas que podem ser atendidas vinculadas a este cliente.</small></span>
                    <span className="customer-dependents__count">{editing.dependents?.length ?? 0}/8</span>
                  </header>
                  <div className="customer-dependent-form">
                    <label className="customer-dependent-name">Nome completo<input aria-label="Nome do dependente" placeholder="Digite o nome completo" value={dependentDraft.fullName} onChange={(event) => setDependentDraft((d) => ({ ...d, fullName: event.target.value }))} /></label>
                    <div className="customer-dependent-details">
                      <label>Data de nascimento<input aria-label="Data de nascimento do dependente" type="date" value={dependentDraft.birthDate} onChange={(event) => setDependentDraft((d) => ({ ...d, birthDate: event.target.value }))} /></label>
                      <span className="customer-dependent-age"><small>Idade calculada</small><strong>{dependentDraft.birthDate ? dependentAge(dependentDraft.birthDate) : "—"}</strong></span>
                      <label>Parentesco<select aria-label="Parentesco do dependente" value={dependentDraft.relationship} onChange={(event) => setDependentDraft((d) => ({ ...d, relationship: event.target.value as typeof d.relationship }))}><option value="CHILD">Filho(a)</option><option value="SPOUSE">Cônjuge</option><option value="EMPLOYEE">Funcionário(a)</option><option value="PARENT">Pai/Mãe</option><option value="OTHER">Outro</option></select></label>
                      <button type="button" className="button button--dark customer-dependent-save" disabled={(editing.dependents?.length ?? 0) >= 8 && !dependentDraft.id} onClick={() => void saveDependent(editing)}><Save size={15} /> {dependentDraft.id ? "Salvar alteração" : "Adicionar dependente"}</button>
                    </div>
                  </div>
                  {(editing.dependents ?? []).length > 0 ? <div className="customer-dependent-table" role="table" aria-label="Dependentes cadastrados">
                    <div className="customer-dependent-table__head" role="row"><span>Nome</span><span>Nascimento</span><span>Idade</span><span>Parentesco</span><span className="sr-only">Ações</span></div>
                    {(editing.dependents ?? []).map((item) => <div className="customer-dependent-table__row" role="row" key={item.id}><span><strong>{item.full_name}</strong></span><span>{new Date(`${item.birth_date}T12:00:00`).toLocaleDateString("pt-BR")}</span><span>{dependentAge(item.birth_date)}</span><span>{({ CHILD: "Filho(a)", SPOUSE: "Cônjuge", EMPLOYEE: "Funcionário(a)", PARENT: "Pai/Mãe", OTHER: "Outro" } as Record<string, string>)[item.relationship]}</span><span className="customer-dependent-actions"><button type="button" className="icon-button icon-button--sm" aria-label={`Editar ${item.full_name}`} onClick={() => setDependentDraft({ id: item.id, fullName: item.full_name, birthDate: item.birth_date, relationship: item.relationship })}><Pencil size={15} /></button><button type="button" className="icon-button icon-button--sm" aria-label={`Excluir ${item.full_name}`} onClick={() => void removeDependent(item.id)}><Trash2 size={15} /></button></span></div>)}
                  </div> : <div className="customer-dependents__empty"><UserPlus size={18} /><span><strong>Nenhum dependente cadastrado</strong><small>Adicione alguém que poderá ser atendido no lugar do cliente.</small></span></div>}
                </section>}
              </div>
              <div className="form-modal__footer">
                <button
                  className="button button--ghost"
                  type="button"
                  onClick={closeForm}
                >
                  Cancelar
                </button>
                <button className="button button--dark" type="submit">
                  {editing ? "Salvar alterações" : "Cadastrar"}
                </button>
              </div>
            </form>
          </div>
        )}
        {filtered.length === 0 ? (
          <EmptyState
            title={
              customers.length
                ? "Nenhum resultado"
                : "Cadastre o primeiro cliente"
            }
          >
            {customers.length
              ? "Ajuste a busca ou altere os filtros."
              : "Clientes manuais podem ser criados sem login e vinculados depois."}
          </EmptyState>
        ) : (
          <div className={styles.list}>
            {filtered.map((customer) => (
              <article className={`${styles.row} ${subscriptionStatusesByCustomer.get(customer.id)?.has("overdue") ? styles.rowOverdue : ""}`} key={customer.id}>
                <span className={styles.rowTitle}>
                  <strong>{customer.full_name}</strong>
                  <small>{lastVisitLabel(customer.id)}</small>
                  <small>{customer.email ?? "Sem e-mail"}</small>
                </span>
                <span className={styles.customerPhone}>
                  {customer.phone_e164 ? (
                    <a
                      href={`https://web.whatsapp.com/send?phone=${customer.phone_e164.replace(/\D/g, "")}`}
                      target="_blank"
                      rel="noreferrer"
                      aria-label={`Abrir WhatsApp de ${customer.full_name}`}
                    >
                      {customer.phone_e164}
                    </a>
                  ) : (
                    "Sem telefone"
                  )}
                  <small
                    className={`${styles.customerWhatsappAutomatic} ${customer.whatsapp_transactional_opted_out ? styles.customerWhatsappAutomaticOff : ""}`}
                  >
                    {customer.whatsapp_transactional_opted_out
                      ? "Não Recebe Whats Aut."
                      : "Recebe Whats Aut."}
                  </small>
                </span>
                <span className={styles.customerBirthDate}>
                  {customer.birth_date ? (
                    <>
                      {new Date(
                        `${customer.birth_date}T12:00:00`,
                      ).toLocaleDateString("pt-BR")}
                      <small className={styles.customerBirthdayReminder}>
                        {birthdayReminder(customer.birth_date)}
                      </small>
                    </>
                  ) : (
                    "Nascimento não informado"
                  )}
                </span>
                <StatusChip
                  active={customer.active && !subscriptionStatusesByCustomer.get(customer.id)?.has("overdue")}
                  label={subscriptionStatusesByCustomer.get(customer.id)?.has("overdue") ? "Em Atraso" : undefined}
                  tone={subscriptionStatusesByCustomer.get(customer.id)?.has("overdue") ? "danger" : undefined}
                />
                <span className={styles.rowActions}>
                  <button
                    className={`${styles.button} ${styles.buttonSoft} ${styles.buttonSmall}`}
                    type="button"
                    onClick={() => {
                      setHistoryCustomer(customer);
                      setHistoryTab("APPOINTMENTS");
                    }}
                  >
                    Agendamentos e Assinaturas
                  </button>
                  <button
                    className={`${styles.button} ${styles.buttonSoft} ${styles.buttonSmall}`}
                    type="button"
                    onClick={() => openEdit(customer)}
                  >
                    Editar
                  </button>
                  <button
                    className={`${styles.button} ${customer.active ? styles.buttonDanger : styles.buttonSoft} ${styles.buttonSmall}`}
                    type="button"
                    onClick={() => void toggle(customer)}
                  >
                    {customer.active ? "Inativar" : "Reativar"}
                  </button>
                </span>
              </article>
            ))}
          </div>
        )}
        {pendingInactivation && (
          <div className="modal-layer" role="presentation">
            <button
              className="modal-layer__backdrop"
              type="button"
              aria-label="Fechar inativação"
              onClick={closeInactivation}
            />
            <section
              className="form-modal customer-inactivation-modal"
              role="dialog"
              aria-modal="true"
              aria-label="Inativar cliente"
            >
              <div className="form-modal__head">
                <span>
                  <small>Inativação de cliente</small>
                  <strong>
                    Por que deseja inativar {pendingInactivation.full_name}?
                  </strong>
                </span>
                <button
                  type="button"
                  className="icon-button"
                  onClick={closeInactivation}
                  aria-label="Fechar"
                >
                  <X size={19} />
                </button>
              </div>
              <div className="form-modal__body">
                <label className="customer-inactivation-field">
                  <span>Motivo da inativação</span>
                  <select
                    aria-label="Motivo da inativação"
                    value={inactivationReason}
                    onChange={(event) =>
                      setInactivationReason(event.target.value)
                    }
                  >
                    <option value="">Selecione um motivo</option>
                    {inactivationReasons.map(([value, label]) => (
                      <option key={value} value={value}>
                        {label}
                      </option>
                    ))}
                  </select>
                </label>
                {inactivationReason === "OTHER" && (
                  <label className="customer-inactivation-field">
                    <span>Outro motivo</span>
                    <textarea
                      aria-label="Outro motivo"
                      value={customInactivationReason}
                      onChange={(event) =>
                        setCustomInactivationReason(event.target.value)
                      }
                      maxLength={500}
                      rows={3}
                      placeholder="Descreva o motivo"
                    />
                  </label>
                )}
              </div>
              <div className="form-modal__footer">
                <button
                  className="button button--ghost"
                  type="button"
                  onClick={closeInactivation}
                >
                  Cancelar
                </button>
                <button
                  className="button button--dark"
                  type="button"
                  disabled={
                    !inactivationReason ||
                    (inactivationReason === "OTHER" &&
                      !customInactivationReason.trim())
                  }
                  onClick={() => void confirmInactivation()}
                >
                  Confirmar inativação
                </button>
              </div>
            </section>
          </div>
        )}
        {historyCustomer && (
          <div className="modal-layer" role="presentation">
            <button
              className="modal-layer__backdrop"
              type="button"
              aria-label="Fechar agendamentos"
              onClick={() => setHistoryCustomer(null)}
            />
            <section
              className="form-modal customer-history-modal"
              role="dialog"
              aria-modal="true"
              aria-label={`Agendamentos de ${historyCustomer.full_name}`}
            >
              <div className="form-modal__head">
                <span>
                  <small>Histórico do cliente</small>
                  <strong>Agendamentos de {historyCustomer.full_name}</strong>
                </span>
                <button
                  type="button"
                  className="icon-button"
                  onClick={() => setHistoryCustomer(null)}
                  aria-label="Fechar"
                >
                  <X size={19} />
                </button>
              </div>
              <div className="form-modal__body">
                <div className="customer-history-summary">
                  <span>
                    <small>Nome</small>
                    <strong>{historyCustomer.full_name}</strong>
                  </span>
                  <span>
                    <small>Telefone</small>
                    <strong>
                      {historyCustomer.phone_e164 ?? "Não informado"}
                    </strong>
                  </span>
                  <span>
                    <small>Nascimento</small>
                    <strong>
                      {historyCustomer.birth_date
                        ? new Date(
                            `${historyCustomer.birth_date}T12:00:00`,
                          ).toLocaleDateString("pt-BR")
                        : "Não informado"}
                    </strong>
                  </span>
                </div>
                <div className={styles.catalogTabs}>
                  <button
                    className={
                      historyTab === "APPOINTMENTS"
                        ? styles.tabActive
                        : styles.tab
                    }
                    type="button"
                    onClick={() => setHistoryTab("APPOINTMENTS")}
                  >
                    Agendamentos
                  </button>
                  <button
                    className={
                      historyTab === "SUBSCRIPTIONS"
                        ? styles.tabActive
                        : styles.tab
                    }
                    type="button"
                    onClick={() => setHistoryTab("SUBSCRIPTIONS")}
                  >
                    Assinaturas
                  </button>
                </div>
                {historyTab === "APPOINTMENTS" &&
                  (customerAppointments(historyCustomer.id).length === 0 ? (
                    <EmptyState title="Sem agendamentos">
                      Este cliente ainda não possui agendamentos registrados.
                    </EmptyState>
                  ) : (
                    <div className="customer-history-table-wrap">
                      <table className="customer-history-table">
                        <thead>
                          <tr>
                            <th>Data</th>
                            <th>Status</th>
                            <th>Serviço/Pacote</th>
                            <th>Valor pago</th>
                            <th>Profissional</th>
                          </tr>
                        </thead>
                        <tbody>
                          {customerAppointments(historyCustomer.id).map(
                            (appointment) => (
                              <tr key={appointment.id}>
                                <td>
                                  {formatRange(appointment.service_period)}
                                </td>
                                <td>{appointmentStatus(appointment)}</td>
                                <td>
                                  {itemsByAppointment
                                    .get(appointment.id)
                                    ?.join(" + ") || "Atendimento"}
                                </td>
                                <td>
                                  {formatCents(
                                    financialByAppointment.get(appointment.id)
                                      ?.net_paid_cents ?? 0,
                                  )}
                                </td>
                                <td>
                                  {barberById.get(appointment.barber_id) ??
                                    "Não informado"}
                                </td>
                              </tr>
                            ),
                          )}
                        </tbody>
                      </table>
                    </div>
                  ))}
                {historyTab === "SUBSCRIPTIONS" &&
                  (() => {
                    const active = subscriptions.filter(
                      (subscription) =>
                        subscription.customer_id === historyCustomer.id,
                    );
                    return (
                      <div className={styles.stack}>
                        {subscriptionModuleEnabled && subscriptionBundlePlans.length > 0 && <div className={styles.toolbarGroup}>
                          <button type="button" className={styles.button} onClick={() => openBundleOffer(historyCustomer.id)}>Nova Assinatura</button>
                        </div>}
                        {active.length === 0 ? (
                          <EmptyState title="Sem assinaturas">
                            Este cliente não possui assinaturas ativas, pendentes ou arquivadas.
                          </EmptyState>
                        ) : (
                          <div className={styles.list}>
                            {active.map((subscription) => {
                              const plan = subscription.plan as {
                                name?: string;
                                description?: string | null;
                              } | null;
                              const version = subscription.plan_version as {
                                price_cents?: number;
                                billing_period?: string;
                                sessions_per_cycle?: number;
                              } | null;
                              const cycles = subscriptionCycles.filter(
                                (cycle) =>
                                  cycle.subscription_id === subscription.id,
                              );
                              const displayStatus = subscriptionDisplayStatus(
                                subscription,
                                cycles,
                                todayInOrganization,
                                subscriptionCancellationRequests.some((request) => String(request.subscription_id) === String(subscription.id)),
                              );
                              const paymentLabels: Record<string, string> = {
                                CARD: "Cartão",
                                PIX: "PIX",
                                BOLETO: "Boleto",
                                CASH: "Dinheiro",
                                UPFRONT: "À vista",
                                ONLINE: "Link de pagamento",
                              };
                              return (
                                <article
                                  className={`${styles.row} ${styles.subscriptionSummaryRow}`}
                                  key={String(subscription.id)}
                                >
                                  <span className={styles.rowTitle}>
                                    <button type="button" className={styles.subscriptionLink} onClick={() => setSubscriptionControlId(String(subscription.id))}>
                                      {plan?.name ?? "Plano"}
                                    </button>
                                    <small>Contrato nº {String(subscription.contract_number ?? "—")}</small>
                                  </span>
                                  <strong>
                                    {formatCents(version?.price_cents ?? 0)}
                                  </strong>
                                  <span className={styles.subscriptionSummaryPayment}>
                                    Venc.{" "}
                                    {String(subscription.first_due_date ?? "—")}{" "}
                                    ·{" "}
                                    {paymentLabels[
                                      String(subscription.payment_method)
                                    ] ??
                                      String(
                                        subscription.payment_method ?? "—",
                                      )}
                                  </span>
                                  <span className={`${styles.subscriptionSummaryStatus} ${styles[`subscriptionSummaryStatus${displayStatus[0].toUpperCase()}${displayStatus.slice(1)}`]}`}>
                                    {subscriptionDisplayStatusLabels[displayStatus]}
                                  </span>
                                  <span className={styles.rowActions}>
                                    {subscription.status === "REQUESTED" && Boolean(subscription.contract_accepted_at) && (
                                      <button
                                        type="button"
                                        className={`${styles.button} ${styles.buttonSmall}`}
                                        onClick={() => {
                                          const today = new Date().toISOString().slice(0, 10);
                                          setApprovalDraft({ subscriptionId: String(subscription.id), startDate: today, dueDate: today });
                                          setMessage("");
                                        }}
                                      >
                                        Aprovar
                                      </button>
                                    )}
                                    {((subscription.status === "REQUESTED" && !subscription.contract_accepted_at) || (Boolean(subscription.manager_activated_provisionally_at) && !subscription.contract_accepted_at)) && <div className={styles.pendingSubscriptionNotice}>
                                      <small>{subscription.manager_activated_provisionally_at ? "Ativado provisoriamente · aguardando aceite do cliente" : "Aguardando aceite do cliente"}</small>
                                      {!subscription.manager_activated_provisionally_at && <div className={styles.pendingSubscriptionButtons}>
                                        <button type="button" className={`${styles.button} ${styles.buttonSmall}`} onClick={() => setManualSubscriptionActivationDraft({ subscriptionId: String(subscription.id), planName: plan?.name ?? "Plano" })}>Ativar plano sem aceite do cliente</button>
                                        <button type="button" className={`${styles.button} ${styles.buttonSmall}`} aria-label="Excluir assinatura pendente" title="Excluir assinatura pendente" disabled={deletingSubscriptionId === String(subscription.id)} onClick={() => void deletePendingSubscription(String(subscription.id))}><Trash2 size={14} /></button>
                                      </div>}
                                    </div>}
                                    {subscription.status !== "REQUESTED" &&
                                      !(subscription.manager_activated_provisionally_at && !subscription.contract_accepted_at) &&
                                      cycles
                                        .filter(
                                          (cycle) =>
                                            (cycle.status === "OPEN" ||
                                              cycle.status === "OVERDUE") &&
                                            (String(subscription.payment_method) !== "UPFRONT" ||
                                              cycle.cycle_number ===
                                                Math.min(
                                                  ...cycles
                                                    .filter(
                                                      (item) =>
                                                        item.status === "OPEN" ||
                                                        item.status === "OVERDUE",
                                                    )
                                                    .map((item) => Number(item.cycle_number)),
                                                )),
                                        )
                                        .map((cycle) => (
                                          <button
                                            key={String(cycle.id)}
                                            type="button"
                                            className={`${styles.button} ${styles.buttonSoft} ${styles.buttonSmall} ${styles.subscriptionLegacyAction}`}
                                            onClick={() =>
                                              void recordFirstPayment(
                                                String(subscription.id),
                                                String(cycle.id),
                                                String(subscription.payment_method) === "UPFRONT"
                                                  ? cycles
                                                      .filter(
                                                        (item) =>
                                                          item.status === "OPEN" ||
                                                          item.status === "OVERDUE",
                                                      )
                                                      .reduce(
                                                        (total, item) =>
                                                          total + Number(item.amount_cents ?? 0),
                                                        0,
                                                      )
                                                  : Number(
                                                      cycle.amount_cents ??
                                                        version?.price_cents ??
                                                        0,
                                                    ),
                                                String(
                                                  subscription.payment_method ??
                                                    "CASH",
                                                ),
                                              )
                                            }
                                          >
                                            {String(subscription.payment_method) === "UPFRONT"
                                              ? "Registrar pagamento à vista"
                                              : `Registrar parcela ${String(cycle.cycle_number)}`}
                                          </button>
                                        ))}
                                  </span>
                                </article>
                              );
                            })}
                          </div>
                        )}
                      </div>
                    );
                  })()}
              </div>
              <div className="form-modal__footer">
                <button
                  className="button button--ghost"
                  type="button"
                  onClick={() => setHistoryCustomer(null)}
                >
                  Fechar
                </button>
              </div>
            </section>
          </div>
        )}
        {bundleOfferDraft && (() => {
          const plan = subscriptionBundlePlans.find((item) => item.id === bundleOfferDraft.planId);
          if (!plan) return null;
          const fixed = plan.version.bundle_scheduling_mode === "FIXED";
          const serviceId = plan.service.id;
          const sessionDuration = Number(plan.version.bundle_session_duration_minutes ?? plan.service.duration_minutes);
          const eligible = eligibleSubscriptionBarbers([serviceId], plan.id);
          const totalSessions = Number(bundleOfferDraft.totalSessions) || 0;
          const pricePerSessionCents = safeBundleCentsInput(bundleOfferDraft.pricePerSession);
          const totalPriceCents = pricePerSessionCents * totalSessions;
          const entryCents = safeBundleCentsInput(bundleOfferDraft.entry);
          const installmentCount = Math.max(1, Number(bundleOfferDraft.installmentCount) || 1);
          const installmentCents = Math.floor(totalPriceCents / installmentCount);
          const discountValue = bundleOfferDraft.discountType === "PERCENT"
            ? safeBundlePercentageInput(bundleOfferDraft.discountValue)
            : bundleOfferDraft.discountType === "FIXED" ? safeBundleCentsInput(bundleOfferDraft.discountValue) : 0;
          const discountCents = bundleOfferDraft.discountType === "PERCENT"
            ? Math.round(installmentCents * discountValue / 10000)
            : bundleOfferDraft.discountType === "FIXED" ? discountValue : 0;
          const discountedInstallmentCents = Math.max(0, installmentCents - discountCents);
          const discountValueLabel = bundleOfferDraft.discountType === "PERCENT"
            ? `${bundlePercentageInput(discountValue)}%`
            : bundleOfferDraft.discountType === "FIXED" ? formatCents(discountValue) : "Sem desconto";
          const weekdays = [
            { value: 0, label: "Domingo" }, { value: 1, label: "Segunda-feira" },
            { value: 2, label: "Terça-feira" }, { value: 3, label: "Quarta-feira" },
            { value: 4, label: "Quinta-feira" }, { value: 5, label: "Sexta-feira" },
            { value: 6, label: "Sábado" },
          ];
          return <div className={`${styles.modalLayer} ${styles.subscriptionBundleOfferLayer}`} role="presentation">
            <button className={styles.modalBackdrop} type="button" aria-label="Fechar oferta de assinatura" disabled={bundleOfferSending} onClick={() => { setBundleOfferConfirmationOpen(false); setBundleOfferDraft(null); }} />
            <section className={`${styles.modal} ${styles.modalWide} ${styles.subscriptionPlanModal}`} role="dialog" aria-modal="true" aria-labelledby="bundle-offer-title">
              <header className={styles.modalHeader}><div><small>Oferta para {customers.find((item) => item.id === bundleOfferDraft.customerId)?.full_name ?? "cliente"}</small><h2 id="bundle-offer-title">Nova assinatura</h2></div><button className={styles.modalClose} type="button" aria-label="Fechar" disabled={bundleOfferSending} onClick={() => { setBundleOfferConfirmationOpen(false); setBundleOfferDraft(null); }}><X size={19} /></button></header>
              <div className={styles.form}>
                <nav className={`${styles.formWide} ${styles.subscriptionBundleTabs}`} role="tablist" aria-label="Etapas da nova assinatura">
                  {([ ["SESSIONS", "Sessões"], ["FINANCIAL", "Financeiro"], ["REVIEW", "Revisão"] ] as const).map(([tab, label]) => <button key={tab} id={`bundle-offer-tab-${tab.toLowerCase()}`} className={bundleOfferDraft.activeTab === tab ? styles.subscriptionBundleTabActive : styles.subscriptionBundleTab} type="button" role="tab" aria-selected={bundleOfferDraft.activeTab === tab} aria-controls="bundle-offer-tab-panel" onClick={() => setBundleOfferDraft((current) => current ? { ...current, activeTab: tab } : current)}>{label}</button>)}
                </nav>
                <section className={`${styles.formWide} ${styles.subscriptionBundleTabPanel}`} id="bundle-offer-tab-panel" role="tabpanel" aria-labelledby={`bundle-offer-tab-${bundleOfferDraft.activeTab.toLowerCase()}`}>
                  {bundleOfferDraft.activeTab === "SESSIONS" && <>
                    <Field label="Plano"><select value={bundleOfferDraft.planId} onChange={(event) => updateBundleOfferPlan(event.target.value)}>{subscriptionBundlePlans.map((item) => <option key={item.id} value={item.id}>{item.name}</option>)}</select></Field>
                    <Field label="Serviço"><input value={plan.service.name} readOnly /></Field>
                    <Field label="Primeira sessão"><input type="date" min={todayInOrganization} value={bundleOfferDraft.firstSessionDate} onChange={(event) => setBundleOfferDraft((current) => current ? { ...current, firstSessionDate: event.target.value } : current)} /></Field>
                    {fixed ? <div className={`${styles.formWide} ${styles.subscriptionBundleSlots}`}>
                      <strong>Agenda semanal fixa · {bundleOfferDraft.slots.length} sessões por semana</strong>
                      {bundleOfferDraft.slots.map((slot, index) => {
                        const availableWeekdays = slot.barberId ? weekdays.filter((day) => fixedScheduleSlots([serviceId], slot.barberId, dateForWeekday(day.value), sessionDuration).length > 0) : [];
                        const slotOptions = slot.barberId && slot.weekday !== ""
                          ? fixedScheduleSlots([serviceId], slot.barberId, dateForWeekday(Number(slot.weekday)), sessionDuration)
                          : [];
                        const times = [...new Set(slotOptions.map((item) => item.time))];
                        const environments = slotOptions.filter((item) => item.time === slot.localTime);
                        return <div className={styles.subscriptionBundleSlot} key={slot.slotNumber}>
                          <strong>Sessão {index + 1}</strong>
                          <Field label="Profissional"><select value={slot.barberId} onChange={(event) => setBundleOfferDraft((current) => current ? { ...current, slots: current.slots.map((item, i) => i === index ? { ...item, barberId: event.target.value, weekday: "", localTime: "", environmentId: "" } : item) } : current)}><option value="">Selecione primeiro</option>{eligible.map((barber) => <option key={barber.id} value={barber.id}>{barber.display_name}</option>)}</select></Field>
                          <Field label="Dia da semana"><select disabled={!slot.barberId} value={slot.weekday} onChange={(event) => setBundleOfferDraft((current) => current ? { ...current, slots: current.slots.map((item, i) => i === index ? { ...item, weekday: event.target.value, localTime: "", environmentId: "" } : item) } : current)}><option value="">Selecione</option>{availableWeekdays.map((day) => <option key={day.value} value={day.value}>{day.label}</option>)}</select></Field>
                          <Field label="Horário"><select disabled={!slot.weekday || !slot.barberId} value={slot.localTime} onChange={(event) => setBundleOfferDraft((current) => current ? { ...current, slots: current.slots.map((item, i) => i === index ? { ...item, localTime: event.target.value, environmentId: "" } : item) } : current)}><option value="">Selecione</option>{times.map((time) => <option key={time} value={time}>{time}</option>)}</select></Field>
                          <Field label="Sala"><select disabled={!slot.localTime} value={slot.environmentId} onChange={(event) => setBundleOfferDraft((current) => current ? { ...current, slots: current.slots.map((item, i) => i === index ? { ...item, environmentId: event.target.value } : item) } : current)}><option value="">Selecione</option>{environments.map((environment) => <option key={`${environment.environmentId}-${environment.time}`} value={environment.environmentId}>{environment.environmentName}</option>)}</select></Field>
                        </div>;
                      })}
                      {eligible.length === 0 && <p className={styles.muted}>Nenhum profissional elegível. Vincule serviço e plano à equipe e configure comissão do plano.</p>}
                      <small className={styles.muted}>Cada horário será conferido novamente quando o cliente aceitar. Feriados e recessos são ignorados na geração das sessões fixas.</small>
                    </div> : <div className={`${styles.formWide} ${styles.subscriptionFreeSessionList}`}>
                      <strong>Sessões livres · {totalSessions} no total</strong>
                      <small className={styles.muted}>O cliente agenda cada sessão pelo app. As sessões são liberadas conforme o calendário do plano.</small>
                      <div>{Array.from({ length: Math.min(totalSessions, 300) }, (_, index) => <span key={index}>Sessão {String(index + 1).padStart(2, "0")}</span>)}</div>
                    </div>}
                  </>}
                  {bundleOfferDraft.activeTab === "FINANCIAL" && <>
                    <Field label="Total de sessões do plano"><input type="number" min={1} max={300} step={1} value={bundleOfferDraft.totalSessions} onChange={(event) => setBundleOfferDraft((current) => current ? { ...current, totalSessions: event.target.value } : current)} /></Field>
                    <Field label="Valor por sessão (R$)"><input inputMode="decimal" value={bundleOfferDraft.pricePerSession} onChange={(event) => setBundleOfferDraft((current) => current ? { ...current, pricePerSession: event.target.value } : current)} /></Field>
                    <Field label="Total do plano (R$)"><input value={formatCents(totalPriceCents)} readOnly /></Field>
                    <Field label="Total de parcelas"><input type="number" min={1} max={24} step={1} value={bundleOfferDraft.installmentCount} onChange={(event) => setBundleOfferDraft((current) => current ? { ...current, installmentCount: event.target.value } : current)} /></Field>
                    <Field label="Desconto por parcela"><select value={bundleOfferDraft.discountType} onChange={(event) => setBundleOfferDraft((current) => current ? { ...current, discountType: event.target.value as BundleDiscountType, discountValue: event.target.value === "NONE" ? "" : current.discountValue } : current)}><option value="NONE">Sem desconto</option><option value="FIXED">Valor em reais</option><option value="PERCENT">Percentual</option></select></Field>
                    <Field label={bundleOfferDraft.discountType === "PERCENT" ? "Desconto (%)" : "Desconto (R$)"}><input inputMode="decimal" value={bundleOfferDraft.discountValue} onChange={(event) => setBundleOfferDraft((current) => current ? { ...current, discountValue: event.target.value } : current)} disabled={bundleOfferDraft.discountType === "NONE"} placeholder={bundleOfferDraft.discountType === "NONE" ? "Sem desconto" : "0,00"} /></Field>
                    <Field label="Valor da parcela"><input value={formatCents(installmentCents)} readOnly /></Field>
                    <Field label="Valor da parcela com desconto"><input value={formatCents(discountedInstallmentCents)} readOnly /></Field>
                    <Field label="Valor da entrada (R$)"><input inputMode="decimal" value={bundleOfferDraft.entry} onChange={(event) => updateBundleOfferEntry(event.target.value)} /></Field>
                    <Field label="Forma de pagamento"><select value={bundleOfferDraft.paymentMethod} onChange={(event) => setBundleOfferDraft((current) => current ? { ...current, paymentMethod: event.target.value } : current)}><option value="PIX">PIX</option><option value="CARD">Cartão</option><option value="BOLETO">Boleto</option><option value="CASH">Dinheiro</option><option value="CRYPTO">Cripto</option><option value="ONLINE">Link de pagamento</option></select></Field>
                    <Field label="Vencimento da entrada"><input type="date" min={todayInOrganization} disabled={safeBundleCentsInput(bundleOfferDraft.entry) <= 0} value={bundleOfferDraft.entryDueDate} onChange={(event) => setBundleOfferDraft((current) => current ? { ...current, entryDueDate: event.target.value, firstInstallmentDueDate: event.target.value && current.firstInstallmentDueDate < event.target.value ? addMonthClamped(event.target.value) : current.firstInstallmentDueDate } : current)} /></Field>
                    <Field label="Vencimento da 1ª parcela"><input type="date" min={bundleOfferDraft.entryDueDate || todayInOrganization} value={bundleOfferDraft.firstInstallmentDueDate} onChange={(event) => setBundleOfferDraft((current) => current ? { ...current, firstInstallmentDueDate: event.target.value } : current)} /></Field>
                  </>}
                  {bundleOfferDraft.activeTab === "REVIEW" && <div className={`${styles.formWide} ${styles.subscriptionBundleReview}`}>
                    <h3>Resumo da assinatura</h3>
                    <p><strong>Plano:</strong> {plan.name} · <strong>Serviço:</strong> {plan.service.name}</p>
                    <p><strong>Agendamento:</strong> {fixed ? `Fixo · ${bundleOfferDraft.slots.length} sessões por semana` : `Livre · ${totalSessions} sessões`}</p>
                    <p><strong>Primeira sessão:</strong> {formatBundleDate(bundleOfferDraft.firstSessionDate)} · <strong>Duração:</strong> {sessionDuration} min</p>
                    {fixed && <ul>{bundleOfferDraft.slots.map((slot, index) => {
                      const barber = eligible.find((item) => item.id === slot.barberId);
                      const weekday = weekdays.find((item) => item.value === Number(slot.weekday))?.label ?? "Dia não definido";
                      const environment = agendaEnvironments.find((item) => item.id === slot.environmentId);
                      return <li key={slot.slotNumber}>Sessão {index + 1}: {barber?.display_name ?? "Profissional não definido"} · {environment?.name ?? "Sala não definida"} · {weekday} · {slot.localTime || "Horário não definido"}</li>;
                    })}</ul>}
                    <div className={styles.subscriptionBundleReviewFinance}>
                      <p><strong>Total do plano:</strong> {formatCents(totalPriceCents)} <span className={styles.subscriptionBundleReviewSeparator} aria-hidden="true">|</span> <strong>Parcelas:</strong> {installmentCount} <span className={styles.subscriptionBundleReviewSeparator} aria-hidden="true">|</span> <strong>Desconto por parcela:</strong> {discountValueLabel}</p>
                      <p><strong>Valor por sessão:</strong> {formatCents(pricePerSessionCents)}</p>
                      {entryCents > 0
                        ? <p><strong>Entrada:</strong> {formatCents(entryCents)} <span className={styles.subscriptionBundleReviewSeparator} aria-hidden="true">|</span> <strong>Venc.:</strong> {formatBundleDate(bundleOfferDraft.entryDueDate)}</p>
                        : <p><strong>Entrada:</strong> Sem entrada</p>}
                      <p><strong>Parcela:</strong> {formatCents(discountedInstallmentCents)} <span className={styles.subscriptionBundleReviewSeparator} aria-hidden="true">|</span> <strong>Venc.:</strong> {formatBundleDate(bundleOfferDraft.firstInstallmentDueDate)} <span className={styles.subscriptionBundleReviewSeparator} aria-hidden="true">|</span> <strong>Recorrência:</strong> Mensal</p>
                      <p><strong>Forma de pagamento:</strong> {bundlePaymentMethodLabels[bundleOfferDraft.paymentMethod] ?? bundleOfferDraft.paymentMethod}</p>
                    </div>
                  </div>}
                </section>
                <div className={`${styles.toolbarGroup} ${styles.formWide}`}>
                  <button className={`${styles.button} ${styles.buttonSoft}`} type="button" disabled={bundleOfferSending} onClick={() => { setBundleOfferConfirmationOpen(false); setBundleOfferDraft(null); }}>Cancelar</button>
                  {bundleOfferDraft.activeTab !== "SESSIONS" && <button className={`${styles.button} ${styles.buttonSoft}`} type="button" disabled={bundleOfferSending} onClick={() => setBundleOfferDraft((current) => current ? { ...current, activeTab: current.activeTab === "REVIEW" ? "FINANCIAL" : "SESSIONS" } : current)}>Voltar</button>}
                  {bundleOfferDraft.activeTab !== "REVIEW" ? <button className={styles.button} type="button" disabled={bundleOfferSending || (fixed && eligible.length === 0)} onClick={advanceBundleOffer}>Continuar</button> : <button className={styles.button} type="button" disabled={bundleOfferSending || (fixed && eligible.length === 0)} onClick={() => setBundleOfferConfirmationOpen(true)}>Criar Assinatura!</button>}
                </div>
              </div>
            </section>
            {bundleOfferConfirmationOpen && <div className={`${styles.modalLayer} ${styles.subscriptionBundleConfirmLayer}`} role="presentation">
              <button className={styles.modalBackdrop} type="button" aria-label="Fechar confirmação" disabled={bundleOfferSending} onClick={() => setBundleOfferConfirmationOpen(false)} />
              <section className={`${styles.modal} ${styles.subscriptionBundleConfirmModal}`} role="alertdialog" aria-modal="true" aria-labelledby="bundle-offer-confirm-title" aria-describedby="bundle-offer-confirm-description">
                <header className={styles.modalHeader}><div><small>Nova assinatura</small><h2 id="bundle-offer-confirm-title">Enviar aviso ao cliente?</h2></div><button className={styles.modalClose} type="button" aria-label="Fechar confirmação" disabled={bundleOfferSending} onClick={() => setBundleOfferConfirmationOpen(false)}><X size={19} /></button></header>
                <div className={styles.form}>
                  <p id="bundle-offer-confirm-description">O contrato fica disponível no App do cliente, para validar o plano de assinatura o cliente deve realizar o aceite no app.</p>
                  <div className={styles.subscriptionBundleConfirmActions}>
                    <button className={`${styles.button} ${styles.buttonSoft}`} type="button" disabled={bundleOfferSending} onClick={() => setBundleOfferConfirmationOpen(false)}>Voltar</button>
                    <button className={`${styles.button} ${styles.buttonSoft}`} type="button" disabled={bundleOfferSending} onClick={() => void submitBundleOffer(false)}>{bundleOfferSending ? "Criando…" : "Apenas criar o plano"}</button>
                    <button className={styles.button} type="button" disabled={bundleOfferSending} onClick={() => void submitBundleOffer(true)}>{bundleOfferSending ? "Criando…" : "Enviar Aviso pelo WhatsApp"}</button>
                  </div>
                </div>
              </section>
            </div>}
          </div>;
        })()}
        {approvalDraft && (
          <div className="modal-layer" role="presentation">
            <button className="modal-layer__backdrop" type="button" aria-label="Fechar aprovação" onClick={() => setApprovalDraft(null)} />
            <section className="form-modal" role="dialog" aria-modal="true" aria-labelledby="subscription-approval-title">
              <div className="form-modal__head">
                <span><small>Assinatura</small><strong id="subscription-approval-title">Aprovar plano</strong></span>
                <button type="button" className="icon-button" onClick={() => setApprovalDraft(null)} aria-label="Fechar"><X size={19} /></button>
              </div>
              <div className="form-modal__body">
                <p>Defina as datas da primeira cobrança. O formato exibido segue o padrão brasileiro.</p>
                <Field label="Data de início"><input type="date" value={approvalDraft.startDate} onChange={(event) => setApprovalDraft((current) => current ? { ...current, startDate: event.target.value } : current)} /></Field>
                <Field label="Primeiro vencimento"><input type="date" value={approvalDraft.dueDate} onChange={(event) => setApprovalDraft((current) => current ? { ...current, dueDate: event.target.value } : current)} /></Field>
              </div>
              <div className="form-modal__footer">
                <button className="button button--ghost" type="button" onClick={() => setApprovalDraft(null)}>Cancelar</button>
                <button className="button button--dark" type="button" onClick={() => void approveSubscription()}>Aprovar plano</button>
              </div>
            </section>
          </div>
        )}
        {manualSubscriptionActivationDraft && (
          <div className="modal-layer" role="presentation">
            <button className="modal-layer__backdrop" type="button" aria-label="Fechar confirmação de ativação provisória" onClick={() => setManualSubscriptionActivationDraft(null)} />
            <section className="form-modal" role="alertdialog" aria-modal="true" aria-labelledby="manual-subscription-activation-title" aria-describedby="manual-subscription-activation-description">
              <div className="form-modal__head">
                <span><small>Assinatura · {manualSubscriptionActivationDraft.planName}</small><strong id="manual-subscription-activation-title">Deseja fazer o aceite do plano sem assinatura do cliente?</strong></span>
                <button type="button" className="icon-button" onClick={() => setManualSubscriptionActivationDraft(null)} aria-label="Fechar">×</button>
              </div>
              <div className="form-modal__body">
                <p id="manual-subscription-activation-description">Mesmo ativando a assinatura manualmente, o cliente ainda pode recusar pelo app - validação do contrato depende de aceitação pelo app do cliente.</p>
              </div>
              <div className="form-modal__footer">
                <button className="button button--ghost" type="button" onClick={() => setManualSubscriptionActivationDraft(null)}>Não</button>
                <button className="button button--dark" type="button" onClick={() => void confirmManualSubscriptionActivation()}>Sim</button>
              </div>
            </section>
          </div>
        )}
        {subscriptionControlId && (() => {
          const subscription = subscriptions.find((item) => String(item.id) === subscriptionControlId);
          if (!subscription) return null;
          const plan = subscription.plan as { name?: string; description?: string | null } | null;
          const version = subscription.plan_version as { id?: string; model?: string; price_cents?: number; sessions_per_cycle?: number; scheduling_mode?: string; bundle_scheduling_mode?: string; bundle_sessions_per_week?: number; bundle_session_duration_minutes?: number; bundle_total_sessions?: number } | null;
          const isBundlePlan = version?.model === "SESSION_BUNDLE_V1";
          const cycles = subscriptionCycles.filter((cycle) => String(cycle.subscription_id) === subscriptionControlId);
          const sessions = subscriptionSessions.filter((session) => String(session.subscription_id) === subscriptionControlId);
          const bundleContract = subscriptionBundleContracts.find((item) => String(item.subscription_id) === subscriptionControlId);
          const bundleSessions = subscriptionBundleSessions.filter((item) => String(item.subscription_id) === subscriptionControlId);
          const bundleInstallments = subscriptionBundleInstallments.filter((item) => String(item.subscription_id) === subscriptionControlId);
          const bundleFixedSlots = subscriptionBundleFixedSlots.filter((item) => String(item.subscription_id) === subscriptionControlId);
          const bundleService = subscriptionPlanServices.find((item) => String(item.plan_version_id ?? "") === String((subscription.plan_version as { id?: string } | null)?.id ?? ""));
          const bundleInstallment = bundleInstallments.find((item) => String(item.kind) === "INSTALLMENT");
          const bundleInstallmentCount = Math.max(1, Number(bundleContract?.installment_count ?? 1));
          const bundleInstallmentBaseCents = bundleInstallmentCount === 1
            ? Number(bundleContract?.total_price_cents ?? 0)
            : Math.floor(Number(bundleContract?.total_price_cents ?? 0) / bundleInstallmentCount);
          const bundleDiscountCents = String(bundleContract?.discount_type) === "FIXED"
            ? Number(bundleContract?.discount_value ?? 0)
            : String(bundleContract?.discount_type) === "PERCENT"
              ? Math.round(bundleInstallmentBaseCents * Number(bundleContract?.discount_value ?? 0) / 10000)
              : 0;
          const displayedBundleInstallmentCents = Number(bundleInstallment?.amount_cents ?? Math.max(0, bundleInstallmentBaseCents - bundleDiscountCents));
          const openCycles = cycles.filter((cycle) => cycle.status === "OPEN" || cycle.status === "OVERDUE");
          const upfront = String(subscription.payment_method) === "UPFRONT";
          const awaitingCustomerConsent = Boolean(subscription.manager_activated_provisionally_at) && !subscription.contract_accepted_at;
          const paymentLabels: Record<string, string> = { CARD: "Cartão", PIX: "PIX", BOLETO: "Boleto", CASH: "Dinheiro", UPFRONT: "À vista", ONLINE: "Link de pagamento", CRYPTO: "Cripto" };
          const settlementMethodLabels: Record<string, string> = { PIX: "PIX", CARD: "Cartão", CASH: "Dinheiro", BOLETO: "Boleto", TRANSFER: "Transferência", OTHER: "Outro" };
          const firstOpenCycle = openCycles[0];
          const financeCycles = upfront && cycles.length > 0 ? [firstOpenCycle ?? cycles[0]] : cycles;
          const cancellationRequest = subscriptionCancellationRequests.find((request) => String(request.subscription_id) === subscriptionControlId);
          const cancellationReasons: Record<string, string> = { FINANCIAL_DIFFICULTY: "Dificuldade Financeira", LACK_OF_TIME: "Falta de tempo", ADDRESS_CHANGE: "Mudança de endereço", OTHER: "Outros" };
          return <>
          <div className="modal-layer" role="presentation">
            <button className="modal-layer__backdrop" type="button" aria-label="Fechar controle da assinatura" onClick={() => { setSubscriptionCycleDeleteTarget(null); setSubscriptionBundleInstallmentDeleteTarget(null); setSubscriptionInstallmentEdit(null); setSubscriptionControlId(null); }} />
            <section className={`${styles.modal} ${styles.modalWide} ${styles.subscriptionControlModal}`} role="dialog" aria-modal="true" aria-labelledby="subscription-control-title">
              <header className={styles.modalHeader}><div><small>Controle da assinatura · Contrato nº {String(subscription.contract_number ?? "—")}</small><h2 id="subscription-control-title">{plan?.name ?? "Plano"}</h2><p>{formatCents(version?.price_cents ?? 0)} · Venc. {formatBundleDate(String(subscription.first_due_date ?? ""))} · {paymentLabels[String(subscription.payment_method)] ?? String(subscription.payment_method)}</p></div><button className={styles.modalClose} type="button" aria-label="Fechar" onClick={() => { setSubscriptionCycleDeleteTarget(null); setSubscriptionBundleInstallmentDeleteTarget(null); setSubscriptionInstallmentEdit(null); setSubscriptionControlId(null); }}><X size={19} /></button></header>
              <div className={styles.subscriptionControlBody}>
                {awaitingCustomerConsent && <p className={styles.provisionalSubscriptionNotice}>Ativação provisória para organizar a agenda. O contrato ainda aguarda aceite do cliente. Recebimentos registrados serão preservados para ajuste manual se o cliente recusar.</p>}
                <nav className={styles.subscriptionControlTabs} role="tablist" aria-label="Seções do controle da assinatura">
                  {([['SESSIONS', 'Sessões'], ['FINANCE', 'Financeiro'], ['SUMMARY', 'Resumo']] as const).map(([tab, label]) => <button key={tab} type="button" role="tab" aria-selected={subscriptionControlTab === tab} className={subscriptionControlTab === tab ? styles.subscriptionControlTabActive : styles.subscriptionControlTab} onClick={() => setSubscriptionControlTab(tab)}>{label}</button>)}
                </nav>
                {subscriptionControlTab === "SESSIONS" && <div className={styles.subscriptionControlLegend}><span><i className={styles.subscriptionDotAvailable} />Em aberto</span><span><i className={styles.subscriptionDotScheduled} />Agendada</span><span><i className={styles.subscriptionDotCompleted} />Concluída</span><span><i className={styles.subscriptionDotCanceled} />Cancelada</span></div>}
                {isBundlePlan && subscriptionControlTab === "SUMMARY" && <section className={styles.subscriptionBundleReview}>
                  <h3>Resumo da assinatura</h3>
                  {bundleContract ? <>
                    <p><strong>Plano:</strong> {plan?.name ?? "Plano"} · <strong>Serviço:</strong> {String(bundleService?.service_name_snapshot ?? "Não informado")}</p>
                    <p><strong>Agendamento:</strong> {String(bundleContract.scheduling_mode) === "FIXED" ? `Fixo · ${String(bundleContract.sessions_per_week)} sessões por semana` : `Livre · ${String(bundleContract.total_sessions)} sessões`}</p>
                    <p><strong>Primeira sessão:</strong> {formatBundleDate(String(bundleContract.first_session_date ?? ""))} · <strong>Duração:</strong> {String(bundleContract.session_duration_minutes)} min</p>
                    {String(bundleContract.scheduling_mode) === "FIXED" && <ul>{bundleFixedSlots.map((slot) => <li key={String(slot.id)}>Sessão {String(slot.slot_number)}: {String(slot.barber_name_snapshot ?? "Profissional não definido")} · {String(slot.environment_name_snapshot ?? "Sala não definida")} · {(["Domingo", "Segunda-feira", "Terça-feira", "Quarta-feira", "Quinta-feira", "Sexta-feira", "Sábado"][Number(slot.weekday)] ?? "Dia não definido")} · {String(slot.local_time ?? "Horário não definido").slice(0, 5)}</li>)}</ul>}
                    <div className={styles.subscriptionBundleReviewFinance}>
                      <p><strong>Total do plano:</strong> {formatCents(Number(bundleContract.total_price_cents))} <span className={styles.subscriptionBundleReviewSeparator} aria-hidden="true">|</span> <strong>Parcelas:</strong> {String(bundleContract.installment_count)} <span className={styles.subscriptionBundleReviewSeparator} aria-hidden="true">|</span> <strong>Desconto por parcela:</strong> {String(bundleContract.discount_type) === "PERCENT" ? `${bundlePercentageInput(Number(bundleContract.discount_value))}%` : String(bundleContract.discount_type) === "FIXED" ? formatCents(Number(bundleContract.discount_value)) : "Sem desconto"}</p>
                      <p><strong>Valor por sessão:</strong> {formatCents(Number(bundleContract.price_per_session_cents))}</p>
                      {Number(bundleContract.entry_cents) > 0
                        ? <p><strong>Entrada:</strong> {formatCents(Number(bundleContract.entry_cents))} <span className={styles.subscriptionBundleReviewSeparator} aria-hidden="true">|</span> <strong>Venc.:</strong> {formatBundleDate(String(bundleContract.entry_due_on ?? ""))}</p>
                        : <p><strong>Entrada:</strong> Sem entrada</p>}
                      <p><strong>Parcela:</strong> {formatCents(displayedBundleInstallmentCents)} <span className={styles.subscriptionBundleReviewSeparator} aria-hidden="true">|</span> <strong>Venc.:</strong> {formatBundleDate(String(bundleInstallment?.due_on ?? bundleContract.first_installment_due_on ?? ""))} <span className={styles.subscriptionBundleReviewSeparator} aria-hidden="true">|</span> <strong>Recorrência:</strong> Mensal</p>
                      <p><strong>Forma de pagamento:</strong> {bundlePaymentMethodLabels[String(subscription.payment_method)] ?? String(subscription.payment_method ?? "Não informada")}</p>
                    </div>
                  </> : <p className={styles.muted}>Carregando os dados do contrato…</p>}
                </section>}
                {!isBundlePlan && subscriptionControlTab === "SESSIONS" && String((subscription.plan_version as { scheduling_mode?: string } | null)?.scheduling_mode) === "FIXED" && <section className={styles.subscriptionFixedSchedule}>
                  <strong>Agendamento fixo</strong>
                  <span>{Number(subscription.fixed_schedule_cadence_weeks) === 2 ? "Quinzenal" : "Semanal"} · {String(subscription.fixed_schedule_start_date ?? "Data não informada")} às {String(subscription.fixed_schedule_local_time ?? "Horário não informado").slice(0, 5)} · {barbers.find((barber) => barber.id === String(subscription.fixed_schedule_barber_id))?.display_name ?? "Profissional não informado"} · {agendaEnvironments.find((environment) => environment.id === String(subscription.fixed_schedule_environment_id ?? ""))?.name ?? "Ambiente conforme escala"}</span>
                  {!subscription.fixed_schedule_created_at && (subscription.status === "REQUESTED" || subscription.status === "PENDING_PAYMENT") && <button type="button" className={`${styles.button} ${styles.buttonSoft} ${styles.buttonSmall}`} onClick={() => {
                    const planVersionId = String((subscription.plan_version as { id?: string } | null)?.id ?? "");
                    const serviceIds = subscriptionPlanServices.filter((item) => String(item.plan_version_id) === planVersionId).map((item) => String(item.service_id));
                    const eligible = eligibleSubscriptionBarbers(serviceIds, String(subscription.plan_id ?? "") || undefined);
                    const startDate = String(subscription.fixed_schedule_start_date ?? "");
                    const storedBarberId = String(subscription.fixed_schedule_barber_id ?? "");
                    const barberId = eligible.some((item) => item.id === storedBarberId) ? storedBarberId : eligible[0]?.id ?? "";
                    const preferredTime = String(subscription.fixed_schedule_local_time ?? "09:00").slice(0, 5);
                    const storedEnvironmentId = String(subscription.fixed_schedule_environment_id ?? "");
                    const slot = firstFixedScheduleSlot(serviceIds, barberId, startDate, preferredTime, storedEnvironmentId);
                    setFixedScheduleEditDraft({
                      subscriptionId: String(subscription.id),
                      cadenceWeeks: String(subscription.fixed_schedule_cadence_weeks ?? 1),
                      startDate,
                      localTime: slot?.time ?? "",
                      barberId,
                      environmentId: slot?.environmentId ?? "",
                      serviceIds,
                    });
                  }}>Editar série fixa</button>}
                  {fixedScheduleEditDraft?.subscriptionId === String(subscription.id) && <form className={styles.formCompactSchedule} onSubmit={(event) => void saveFixedScheduleEdit(event)}>
                    <label>Frequência da série<span className="input-shell">{fixedScheduleEditDraft.cadenceWeeks === "2" ? "Quinzenal · a cada duas semanas" : "Semanal"}</span></label>
                    <label>Profissional<select value={fixedScheduleEditDraft.barberId} onChange={(event) => setFixedScheduleEditDraft((draft) => {
                      if (!draft) return draft;
                      const barberId = event.target.value;
                      const slot = firstFixedScheduleSlot(draft.serviceIds, barberId, draft.startDate, draft.localTime, draft.environmentId);
                      return { ...draft, barberId, localTime: slot?.time ?? "", environmentId: slot?.environmentId ?? "" };
                })} required><option value="">Selecione</option>{eligibleSubscriptionBarbers(fixedScheduleEditDraft.serviceIds, String(subscription.plan_id ?? "") || undefined).map((item) => <option key={item.id} value={item.id}>{item.display_name}</option>)}</select></label>
                    <label>Data inicial<input type="date" min={todayInOrganization} value={fixedScheduleEditDraft.startDate} onChange={(event) => setFixedScheduleEditDraft((draft) => {
                      if (!draft) return draft;
                      const startDate = event.target.value;
                      const slot = firstFixedScheduleSlot(draft.serviceIds, draft.barberId, startDate, draft.localTime, draft.environmentId);
                      return { ...draft, startDate, localTime: slot?.time ?? "", environmentId: slot?.environmentId ?? "" };
                    })} required /></label>
                    <label>Horário<select value={fixedScheduleEditDraft.localTime} onChange={(event) => setFixedScheduleEditDraft((draft) => {
                      if (!draft) return draft;
                      const localTime = event.target.value;
                      const slot = fixedScheduleSlots(draft.serviceIds, draft.barberId, draft.startDate).find((item) => item.time === localTime && item.environmentId === draft.environmentId)
                        ?? fixedScheduleSlots(draft.serviceIds, draft.barberId, draft.startDate).find((item) => item.time === localTime);
                      return { ...draft, localTime, environmentId: slot?.environmentId ?? "" };
                    })} required><option value="">Selecione um horário</option>{fixedScheduleEditTimes.map((time) => <option key={time} value={time}>{time}</option>)}</select></label>
                    <label>Sala/ambiente<select value={fixedScheduleEditDraft.environmentId} onChange={(event) => setFixedScheduleEditDraft((draft) => draft ? { ...draft, environmentId: event.target.value } : draft)} required disabled={!fixedScheduleEditDraft.localTime}><option value="">Selecione</option>{fixedScheduleEditRooms.map((slot) => <option key={slot.environmentId} value={slot.environmentId}>{slot.environmentName}</option>)}</select></label>
                    {fixedScheduleEditDraft.startDate && fixedScheduleEditTimes.length === 0 && <p className={styles.subscriptionBookingHint}>Não há horário e sala compatíveis com a escala desse profissional para esta data. Escolha outra data ou profissional.</p>}
                    <div className={styles.formWide}><button className={styles.button} type="submit" disabled={!fixedScheduleEditDraft.localTime || !fixedScheduleEditDraft.environmentId}>Salvar série</button><button className={`${styles.button} ${styles.buttonSoft}`} type="button" onClick={() => setFixedScheduleEditDraft(null)}>Cancelar</button></div>
                  </form>}
                </section>}
                {subscriptionControlTab === "SESSIONS" && !isBundlePlan && <>
                {cycles.map((cycle) => {
                  const cycleSessions = sessions.filter((session) => String(session.cycle_id) === String(cycle.id));
                  return <article className={styles.subscriptionMonth} key={String(cycle.id)}>
                    <div className={styles.subscriptionMonthTitle}><strong>{new Intl.DateTimeFormat("pt-BR", { month: "long", year: "numeric" }).format(new Date(`${String(cycle.starts_on)}T12:00:00`))}</strong><small>{cycleSessions.length} sessão(ões)</small></div>
                    <div className={styles.subscriptionSessionList}>{cycleSessions.map((session) => {
                      const presentation = sessionPresentation(session, cycleSessions.length || Number(version?.sessions_per_cycle ?? 0));
                      const chipClass = `${styles.subscriptionSessionChip} ${styles[`subscriptionSessionChip${presentation.tone[0].toUpperCase()}${presentation.tone.slice(1)}`]}`;
                      const appointmentId = String(session.appointment_id ?? "");
                      const linkedAppointment = appointments.find((item) => item.id === appointmentId);
                      const canReschedule = String(version?.scheduling_mode) === "FIXED" && session.status === "SCHEDULED" && linkedAppointment?.status === "CONFIRMED";
                      if (session.status === "AVAILABLE") return <button type="button" className={chipClass} key={String(session.id)} onClick={() => openSubscriptionBooking(subscription, session, cycle)}>{presentation.label}</button>;
                      if (canReschedule) return <button type="button" className={`${chipClass} ${styles.subscriptionSessionChipAction}`} key={String(session.id)} title="Reagendar sessão" aria-label={`Reagendar sessão ${presentation.label}`} onClick={() => openSubscriptionSessionReschedule(subscription, session, appointmentId)}>{presentation.label}</button>;
                      return <span className={chipClass} key={String(session.id)}>{presentation.label}</span>;
                    })}</div>
                  </article>;
                })}
                </>}
                {isBundlePlan && subscriptionControlTab === "SESSIONS" && <section className={styles.subscriptionStack}>
                  <strong>Sessões do plano</strong>
                  <div className={styles.subscriptionSessionList}>{bundleSessions.map((session) => {
                    const linkedAppointment = appointments.find((item) => String(item.id) === String(session.appointment_id ?? ""));
                    const scheduled = session.scheduled_for ? new Intl.DateTimeFormat("pt-BR", { dateStyle: "short", timeStyle: "short", timeZone: timezone }).format(new Date(String(session.scheduled_for))) : "";
                    const barber = barbers.find((item) => item.id === String(session.barber_id ?? linkedAppointment?.barber_id ?? ""));
                    const state = ({ AVAILABLE: "Disponível", SCHEDULED: "Agendada", COMPLETED: "Concluída", CONSUMED: "Consumida", CANCELED: "Cancelada" } as Record<string, string>)[String(session.status)] ?? String(session.status);
                    return <article className={styles.subscriptionSessionChip} key={String(session.id)}><strong>Sessão {String(session.session_number).padStart(2, "0")}</strong><span>{state}{scheduled ? ` · ${scheduled}` : ""}{barber ? ` · ${barber.display_name}` : ""}</span></article>;
                  })}</div>
                </section>}
                {subscriptionControlTab === "FINANCE" && <section className={styles.subscriptionFinanceTableWrap} aria-label="Parcelas da assinatura">
                  <div className={styles.subscriptionFinanceTableScroll}><table className={styles.subscriptionFinanceTable}>
                    <thead><tr><th>N. Parcela</th><th>Valor</th><th>Vencimento</th><th>Recebimento</th><th>Status</th><th>Ações</th></tr></thead>
                    <tbody>
                      {isBundlePlan ? bundleInstallments.map((installment) => {
                        const installmentId = String(installment.id);
                        const installmentNumber = Number(installment.installment_number ?? 0);
                        const dueOn = String(installment.due_on ?? "");
                        const status = String(installment.status ?? "OPEN");
                        const canManage = status === "OPEN" || status === "OVERDUE";
                        const settlements = (installment.settlements ?? []) as Array<Record<string, unknown>>;
                        const receipt = settlements.map((settlement) => `${String(settlement.kind) === "REVERSAL" ? "Estorno" : "Recebido"} ${formatCents(Number(settlement.amount_cents ?? 0))} · ${formatBundleDate(String(settlement.settled_on ?? ""))} · ${settlementMethodLabels[String(settlement.payment_method)] ?? String(settlement.payment_method ?? "")}`).join("; ");
                        const netSettledCents = settlements.reduce((total, settlement) => total + (String(settlement.kind) === "REVERSAL" ? -1 : 1) * Number(settlement.amount_cents ?? 0), 0);
                        const remainingCents = Math.max(0, Number(installment.amount_cents ?? 0) - netSettledCents);
                        const label = String(installment.kind) === "ENTRY" ? "Entrada" : String(installmentNumber).padStart(2, "0");
                        const paymentTargetInstallment = { ...installment, subscription_id: subscriptionControlId };
                        return <tr key={installmentId}>
                          <td>{label}</td><td>{formatCents(Number(installment.amount_cents ?? 0))}</td><td>{formatBundleDate(dueOn)}</td>
                          <td>{receipt || (status === "PAID" ? "Recebido" : "—")}</td><td><span className={styles.subscriptionFinanceStatus}>{status === "PAID" ? "Pago" : status === "CANCELED" ? "Cancelada" : status === "OVERDUE" || (status === "OPEN" && dueOn < todayInOrganization) ? "Em atraso" : "Em aberto"}</span></td>
                          <td><div className={styles.subscriptionFinanceActions}>
                            <button type="button" className={`${styles.button} ${styles.buttonSmall}`} disabled={!canManage || remainingCents <= 0 || !chartAccounts.length || !financialAccounts.length} title={!chartAccounts.length || !financialAccounts.length ? "Configure as contas financeiras para registrar recebimentos" : canManage ? "Receber saldo da parcela" : "Parcela encerrada"} onClick={() => openBundlePaymentDialog(subscriptionControlId, { ...paymentTargetInstallment, amount_cents: remainingCents }, String(subscription.payment_method ?? "CASH"))}>Receber</button>
                            <button type="button" className={`${styles.button} ${styles.buttonSoft} ${styles.buttonSmall}`} disabled={!canManage} onClick={() => setSubscriptionInstallmentEdit({ kind: "BUNDLE", subscriptionId: subscriptionControlId, installmentId, amount: bundleMoneyInput(Number(installment.amount_cents ?? 0)), dueOn })}><Pencil size={14} /> Editar</button>
                            <button type="button" className={`${styles.button} ${styles.buttonDanger} ${styles.buttonSmall}`} disabled={!canManage} onClick={() => setSubscriptionBundleInstallmentDeleteTarget(paymentTargetInstallment)}><Trash2 size={14} /> Excluir</button>
                          </div></td>
                        </tr>;
                      }) : financeCycles.map((cycle) => {
                        const canManage = cycle.status === "OPEN" || cycle.status === "OVERDUE";
                        const canReceive = canManage && (!upfront || String(cycle.id) === String(firstOpenCycle?.id));
                        const canDelete = canManage && !upfront && sessions.filter((session) => String(session.cycle_id) === String(cycle.id)).every((session) => session.status === "AVAILABLE" || session.status === "CANCELED");
                        const amount = upfront ? (cycle.status === "PAID" ? cycles : cycle.status === "CANCELED" ? [cycle] : openCycles).reduce((total, item) => total + Number(item.amount_cents ?? 0), 0) : Number(cycle.amount_cents ?? version?.price_cents ?? 0);
                        const receipt = cycle.paid_at ? `${formatBundleDate(String(cycle.paid_at).slice(0, 10))} · ${paymentLabels[String(subscription.payment_method)] ?? String(subscription.payment_method)}` : "—";
                        return <tr key={String(cycle.id)}>
                          <td>{upfront ? "À vista" : String(cycle.cycle_number ?? "—")}</td><td>{formatCents(amount)}</td><td>{formatBundleDate(String(cycle.due_on ?? ""))}</td><td>{receipt}</td>
                          <td><span className={styles.subscriptionFinanceStatus}>{cycle.status === "PAID" ? "Pago" : cycle.status === "CANCELED" ? "Cancelada" : cycle.status === "OVERDUE" || (cycle.status === "OPEN" && String(cycle.due_on ?? "") < todayInOrganization) ? "Em atraso" : "Em aberto"}</span></td>
                          <td><div className={styles.subscriptionFinanceActions}>
                            <button type="button" className={`${styles.button} ${styles.buttonSmall}`} disabled={!canReceive} title={upfront && canManage && !canReceive ? "À vista: o saldo é recebido pelo primeiro ciclo" : "Receber parcela"} onClick={() => openPaymentDialog(String(subscription.id), { id: cycle.id, amount_cents: amount, due_on: cycle.due_on }, String(subscription.payment_method ?? "CASH"))}>Receber</button>
                            <button type="button" className={`${styles.button} ${styles.buttonSoft} ${styles.buttonSmall}`} disabled={!canManage || upfront} title={upfront ? "Ajuste o valor total do contrato à vista" : "Editar parcela"} onClick={() => setSubscriptionInstallmentEdit({ kind: "LEGACY", subscriptionId: subscriptionControlId, installmentId: String(cycle.id), amount: bundleMoneyInput(amount), dueOn: String(cycle.due_on ?? "") })}><Pencil size={14} /> Editar</button>
                            <button type="button" className={`${styles.button} ${styles.buttonDanger} ${styles.buttonSmall}`} disabled={!canDelete} onClick={() => setSubscriptionCycleDeleteTarget(cycle)}><Trash2 size={14} /> Excluir</button>
                          </div></td>
                        </tr>;
                      })}
                    </tbody>
                  </table></div>
                  {((isBundlePlan && bundleInstallments.length === 0) || (!isBundlePlan && cycles.length === 0)) && <p className={styles.muted}>Nenhuma parcela gerada para esta assinatura.</p>}
                </section>}
                {subscriptionControlTab === "SUMMARY" && !isBundlePlan && <section className={styles.subscriptionBundleReview}>
                  <h3>Resumo da assinatura</h3>
                  <p><strong>Plano:</strong> {plan?.name ?? "Plano"} · <strong>Serviço:</strong> {subscriptionPlanServices.filter((item) => String(item.plan_version_id) === String(version?.id)).map((item) => String(item.service_name_snapshot ?? "Serviço")).join(", ") || "Não informado"}</p>
                  <p><strong>Status:</strong> {String(subscription.status)} · <strong>Início:</strong> {formatBundleDate(String(subscription.start_date ?? ""))} · <strong>Vencimento:</strong> {formatBundleDate(String(subscription.first_due_date ?? ""))}</p>
                  <p><strong>Agendamento:</strong> {String(version?.scheduling_mode) === "FIXED" ? "Fixo" : "Livre"} · <strong>Sessões por período:</strong> {String(version?.sessions_per_cycle ?? "—")} · <strong>Periodicidade:</strong> {String((subscription.plan_version as { billing_period?: string } | null)?.billing_period ?? "—")}</p>
                  <p><strong>Valor por período:</strong> {formatCents(Number(version?.price_cents ?? 0))} · <strong>Quantidade de períodos:</strong> {String((subscription.plan_version as { duration_months?: number } | null)?.duration_months ?? "—")}</p>
                  {!isBundlePlan && String((subscription.plan_version as { scheduling_mode?: string } | null)?.scheduling_mode) === "FIXED" && <p>{String(subscription.fixed_schedule_start_date ?? "Data inicial não informada")} às {String(subscription.fixed_schedule_local_time ?? "Horário não informado").slice(0, 5)} · {barbers.find((barber) => barber.id === String(subscription.fixed_schedule_barber_id))?.display_name ?? "Profissional não informado"}</p>}
                </section>}
                {subscriptionControlTab === "SUMMARY" && !isBundlePlan && cancellationRequest && <section className={styles.subscriptionFixedSchedule}>
                  <strong>Solicitação de cancelamento pendente</strong>
                  <span>Motivo: {cancellationReasons[String(cancellationRequest.reason)] ?? String(cancellationRequest.reason)}</span>
                  {Boolean(cancellationRequest.observations) && <span>Observações: {String(cancellationRequest.observations)}</span>}
                  <span>Última sessão solicitada: {sessions.find((session) => String(session.id) === String(cancellationRequest.last_session_id)) ? `Sessão ${String(sessions.find((session) => String(session.id) === String(cancellationRequest.last_session_id))?.session_number)}` : "Nenhuma sessão adicional"}</span>
                </section>}
                {subscriptionControlTab === "SUMMARY" && !isBundlePlan && (cancellationRequest || subscription.status === "ACTIVE" || subscription.status === "PENDING_PAYMENT") && <div className={styles.toolbarGroup}>
                  <button type="button" className={`${styles.button} ${styles.buttonDanger}`} onClick={() => {
                    setSubscriptionCancellationDraft({
                      subscriptionId: subscriptionControlId,
                      requestId: cancellationRequest ? String(cancellationRequest.id) : null,
                      reason: cancellationRequest ? String(cancellationRequest.reason) : "",
                      observations: cancellationRequest ? String(cancellationRequest.observations ?? "") : "",
                      lastCycleId: "",
                      lastSessionId: "",
                    });
                  }}>{cancellationRequest ? "Confirmar cancelamento" : "Cancelar assinatura"}</button>
                </div>}
              </div>
            </section>
          </div>
          {subscriptionCycleDeleteTarget && String(subscriptionCycleDeleteTarget.subscription_id) === subscriptionControlId && <div className={`${styles.modalLayer} ${styles.subscriptionCancellationLayer}`} role="presentation"><button className={styles.modalBackdrop} type="button" aria-label="Cancelar exclusão da parcela" disabled={deletingSubscriptionCycle} onClick={() => setSubscriptionCycleDeleteTarget(null)} /><section className={styles.modal} role="dialog" aria-modal="true" aria-labelledby="subscription-cycle-delete-title"><header className={styles.modalHeader}><div><small>Controle da assinatura</small><h2 id="subscription-cycle-delete-title">Excluir parcela</h2></div><button className={styles.modalClose} type="button" aria-label="Fechar confirmação" disabled={deletingSubscriptionCycle} onClick={() => setSubscriptionCycleDeleteTarget(null)}><X size={18} /></button></header><div className={styles.form}><p>Confirma excluir o ciclo {String(subscriptionCycleDeleteTarget.cycle_number)} no valor de {formatCents(Number(subscriptionCycleDeleteTarget.amount_cents ?? 0))}, com vencimento em {String(subscriptionCycleDeleteTarget.due_on)}?</p><p className={styles.muted}>As sessões disponíveis deste ciclo também serão canceladas. Ciclos com sessões agendadas/concluídas e parcelas baixadas não podem ser excluídos.</p><footer className={styles.modalActions}><button className={`${styles.button} ${styles.buttonSoft}`} type="button" disabled={deletingSubscriptionCycle} onClick={() => setSubscriptionCycleDeleteTarget(null)}>Cancelar</button><button className={`${styles.button} ${styles.buttonDanger}`} type="button" disabled={deletingSubscriptionCycle} onClick={() => void deleteSubscriptionCycle()}><Trash2 size={15} /> {deletingSubscriptionCycle ? "Excluindo…" : "Confirmar exclusão"}</button></footer></div></section></div>}
          {subscriptionBundleInstallmentDeleteTarget && String(subscriptionBundleInstallmentDeleteTarget.subscription_id) === subscriptionControlId && <div className={`${styles.modalLayer} ${styles.subscriptionCancellationLayer}`} role="presentation"><button className={styles.modalBackdrop} type="button" aria-label="Cancelar exclusão da parcela" disabled={deletingSubscriptionCycle} onClick={() => setSubscriptionBundleInstallmentDeleteTarget(null)} /><section className={styles.modal} role="dialog" aria-modal="true" aria-labelledby="subscription-bundle-installment-delete-title"><header className={styles.modalHeader}><div><small>Controle da assinatura</small><h2 id="subscription-bundle-installment-delete-title">Excluir parcela?</h2></div><button className={styles.modalClose} type="button" aria-label="Fechar confirmação" disabled={deletingSubscriptionCycle} onClick={() => setSubscriptionBundleInstallmentDeleteTarget(null)}><X size={18} /></button></header><div className={styles.form}><p>Confirma cancelar {String(subscriptionBundleInstallmentDeleteTarget.kind) === "ENTRY" ? "a entrada" : `a parcela ${String(subscriptionBundleInstallmentDeleteTarget.installment_number)}`} de {formatCents(Number(subscriptionBundleInstallmentDeleteTarget.amount_cents ?? 0))}, com vencimento em {formatBundleDate(String(subscriptionBundleInstallmentDeleteTarget.due_on ?? ""))}?</p><p className={styles.muted}>A conta a receber será cancelada e o histórico permanecerá registrado. As sessões do plano não serão alteradas.</p><footer className={styles.modalActions}><button className={`${styles.button} ${styles.buttonSoft}`} type="button" disabled={deletingSubscriptionCycle} onClick={() => setSubscriptionBundleInstallmentDeleteTarget(null)}>Voltar</button><button className={`${styles.button} ${styles.buttonDanger}`} type="button" disabled={deletingSubscriptionCycle} onClick={() => void deleteSubscriptionBundleInstallment()}><Trash2 size={15} /> {deletingSubscriptionCycle ? "Cancelando…" : "Confirmar exclusão"}</button></footer></div></section></div>}
          {subscriptionInstallmentEdit?.subscriptionId === subscriptionControlId && <div className={`${styles.modalLayer} ${styles.subscriptionCancellationLayer}`} role="presentation"><button className={styles.modalBackdrop} type="button" aria-label="Fechar edição da parcela" disabled={savingSubscriptionInstallmentEdit} onClick={() => setSubscriptionInstallmentEdit(null)} /><form className={styles.modal} role="dialog" aria-modal="true" aria-labelledby="subscription-installment-edit-title" onSubmit={(event) => void saveSubscriptionInstallmentEdit(event)}><header className={styles.modalHeader}><div><small>Controle da assinatura</small><h2 id="subscription-installment-edit-title">Editar parcela</h2></div><button className={styles.modalClose} type="button" aria-label="Fechar edição" disabled={savingSubscriptionInstallmentEdit} onClick={() => setSubscriptionInstallmentEdit(null)}><X size={18} /></button></header><div className={styles.form}><Field label="Valor (R$)"><input inputMode="decimal" value={subscriptionInstallmentEdit.amount} onChange={(event) => setSubscriptionInstallmentEdit((draft) => draft ? { ...draft, amount: event.target.value } : draft)} required /></Field><Field label="Vencimento"><input type="date" value={subscriptionInstallmentEdit.dueOn} onChange={(event) => setSubscriptionInstallmentEdit((draft) => draft ? { ...draft, dueOn: event.target.value } : draft)} required /></Field><p className={styles.formWide}>A alteração será refletida no contrato e em Contas a receber. Parcelas pagas não podem ser editadas.</p><footer className={styles.modalActions}><button className={`${styles.button} ${styles.buttonSoft}`} type="button" disabled={savingSubscriptionInstallmentEdit} onClick={() => setSubscriptionInstallmentEdit(null)}>Cancelar</button><button className={styles.button} type="submit" disabled={savingSubscriptionInstallmentEdit}>{savingSubscriptionInstallmentEdit ? "Salvando…" : "Salvar alteração"}</button></footer></div></form></div>}
          </>;
        })()}
        {subscriptionCancellationDraft && (() => {
          const draft = subscriptionCancellationDraft;
          const relatedCycles = subscriptionCycles.filter((cycle) => String(cycle.subscription_id) === draft.subscriptionId && cycle.status !== "CANCELED");
          const relatedSessions = subscriptionSessions.filter((session) => String(session.subscription_id) === draft.subscriptionId && (session.status === "AVAILABLE" || session.status === "SCHEDULED"));
          const request = draft.requestId ? subscriptionCancellationRequests.find((item) => String(item.id) === draft.requestId) : null;
          return <div className={`${styles.modalLayer} ${styles.subscriptionCancellationLayer}`} role="presentation">
            <button className={styles.modalBackdrop} type="button" aria-label="Fechar cancelamento" onClick={() => setSubscriptionCancellationDraft(null)} />
            <section className={styles.modal} role="dialog" aria-modal="true" aria-labelledby="subscription-cancellation-manager-title">
              <header className={styles.modalHeader}><div><small>Controle da assinatura</small><h2 id="subscription-cancellation-manager-title">{request ? "Confirmar cancelamento solicitado" : "Cancelar assinatura"}</h2></div><button className={styles.modalClose} type="button" onClick={() => setSubscriptionCancellationDraft(null)} aria-label="Fechar"><X size={18} /></button></header>
              <form className={styles.form} onSubmit={(event) => void confirmSubscriptionCancellation(event)}>
                {request && <div className={styles.formWide}><p><strong>Motivo:</strong> {{ FINANCIAL_DIFFICULTY: "Dificuldade Financeira", LACK_OF_TIME: "Falta de tempo", ADDRESS_CHANGE: "Mudança de endereço", OTHER: "Outros" }[String(request.reason)] ?? String(request.reason)}</p>{Boolean(request.observations) && <p><strong>Observações:</strong> {String(request.observations)}</p>}<p><strong>Última sessão solicitada:</strong> {relatedSessions.find((session) => String(session.id) === String(request.last_session_id)) ? `Sessão ${String(relatedSessions.find((session) => String(session.id) === String(request.last_session_id))?.session_number)}` : "Nenhuma sessão adicional"}</p></div>}
                {!request && <><Field label="Motivo do cancelamento" wide><select required value={draft.reason} onChange={(event) => setSubscriptionCancellationDraft((current) => current ? { ...current, reason: event.target.value } : current)}><option value="">Selecione</option><option value="FINANCIAL_DIFFICULTY">Dificuldade Financeira</option><option value="LACK_OF_TIME">Falta de tempo</option><option value="ADDRESS_CHANGE">Mudança de endereço</option><option value="OTHER">Outros</option></select></Field>{draft.reason === "OTHER" && <Field label="Observações" wide><textarea required maxLength={2000} value={draft.observations} onChange={(event) => setSubscriptionCancellationDraft((current) => current ? { ...current, observations: event.target.value } : current)} /></Field>}</>}
                <Field label="Última cobrança" wide><select required value={draft.lastCycleId} onChange={(event) => setSubscriptionCancellationDraft((current) => current ? { ...current, lastCycleId: event.target.value } : current)}><option value="">Selecione</option><option value="__none__">Sem novas cobranças</option>{relatedCycles.map((cycle) => <option key={String(cycle.id)} value={String(cycle.id)}>Ciclo {String(cycle.cycle_number)} · venc. {String(cycle.due_on)} · {cycle.status === "PAID" ? "Pago" : "Em aberto"}</option>)}</select></Field>
                {!request && <Field label="Última sessão" wide><select value={draft.lastSessionId} onChange={(event) => setSubscriptionCancellationDraft((current) => current ? { ...current, lastSessionId: event.target.value } : current)}><option value="">Nenhuma sessão adicional</option>{relatedSessions.map((session) => <option key={String(session.id)} value={String(session.id)}>Ciclo {String(relatedCycles.find((cycle) => String(cycle.id) === String(session.cycle_id))?.cycle_number ?? "—")} · Sessão {String(session.session_number)}</option>)}</select></Field>}
                <p className={styles.formWide}>Dívidas já existentes serão preservadas. Cobranças e sessões posteriores aos limites escolhidos serão encerradas.</p>
                <footer className={styles.modalActions}><button className={`${styles.button} ${styles.buttonSoft}`} type="button" onClick={() => setSubscriptionCancellationDraft(null)}>Cancelar</button><button className={`${styles.button} ${styles.buttonDanger}`} type="submit">Confirmar cancelamento</button></footer>
              </form>
            </section>
          </div>;
        })()}
        {subscriptionBooking && (() => {
          const customer = customers.find((item) => item.id === subscriptionBooking.customerId);
          const currentSubscription = subscriptions.find((item) => String(item.id) === subscriptionBooking.subscriptionId);
          const eligible = eligibleSubscriptionBarbers(subscriptionBooking.serviceIds, String(currentSubscription?.plan_id ?? "") || undefined);
          return <div className="modal-layer" role="presentation">
            <button className="modal-layer__backdrop" type="button" aria-label="Fechar reserva de assinatura" onClick={() => setSubscriptionBooking(null)} />
            <form className="form-modal" role="dialog" aria-modal="true" aria-labelledby="subscription-booking-title" onSubmit={bookSubscriptionSession}>
              <div className="form-modal__head"><span><small>Agendamento de sessão de assinatura</small><strong id="subscription-booking-title">{subscriptionBooking.mode === "RESCHEDULE" ? "Reagendar sessão" : "Reserve um horário"}</strong></span><button type="button" className="icon-button" onClick={() => setSubscriptionBooking(null)} aria-label="Fechar"><X size={19} /></button></div>
              <div className="form-modal__body">
                <p className={styles.subscriptionBookingReference}>Sessão {subscriptionBooking.sessionNumber} de {subscriptionBooking.totalSessions} de {new Intl.DateTimeFormat("pt-BR", { month: "long", year: "numeric" }).format(new Date(`${subscriptionBooking.referenceDate}T12:00:00`))}</p>
                <label>Cliente<span className="input-shell"><UserRound size={17} /><input value={customer?.full_name ?? "Cliente"} readOnly /></span></label>
                <label>Serviço ou pacote<span className="input-shell"><input value={subscriptionBooking.planName} readOnly /></span></label>
                <label>Profissional<span className="select-input"><select value={subscriptionBookingBarberId} onChange={(event) => setSubscriptionBookingBarberId(event.target.value)} required disabled={subscriptionBooking.mode === "RESCHEDULE"}><option value="">Selecione</option>{eligible.map((barber) => <option key={barber.id} value={barber.id}>{barber.display_name}</option>)}</select><ChevronDown size={15} /></span></label>
                <div className="form-grid"><label>Data<span className="input-shell"><CalendarDays size={17} /><input type="date" value={subscriptionBookingDate} onChange={(event) => setSubscriptionBookingDate(event.target.value)} required /></span></label><label>Horário<span className="input-shell"><Clock3 size={17} /><input type="time" value={subscriptionBookingTime} onChange={(event) => setSubscriptionBookingTime(event.target.value)} step={15 * 60} required /></span></label></div>
                <p className={styles.subscriptionBookingHint}>{subscriptionBooking.mode === "RESCHEDULE" ? "O reagendamento mantém o profissional, os serviços e a cobrança da sessão." : "O cliente e o serviço pertencem ao plano e não podem ser alterados."}</p>
                {subscriptionBooking.mode === "BOOK" && <label>Motivo de exceção por parcela vencida (apenas se necessário)<span className="input-shell"><textarea value={subscriptionOverdueReason} onChange={(event) => setSubscriptionOverdueReason(event.target.value)} minLength={5} maxLength={1000} placeholder="Informe o motivo para liberar este agendamento" /></span></label>}
              </div>
              <div className="form-modal__footer"><button type="button" className="button button--ghost" onClick={() => setSubscriptionBooking(null)}>Cancelar</button><button type="submit" className="button button--dark"><Check size={17} /> {subscriptionBooking.mode === "RESCHEDULE" ? "Confirmar reagendamento" : "Agendar sessão"}</button></div>
            </form>
          </div>;
        })()}
        {paymentTarget && <div className="modal-layer" role="presentation">
          <button className={styles.modalBackdrop} type="button" aria-label="Fechar recebimento" onClick={() => setPaymentTarget(null)} />
          <section className={`${styles.modal} ${styles.modalWide}`} role="dialog" aria-modal="true" aria-labelledby="subscription-payment-title">
            <header className={styles.modalHeader}><div><small>Recebimento de assinatura</small><h2 id="subscription-payment-title">Receber parcela</h2></div><button className={styles.modalClose} type="button" aria-label="Fechar" onClick={() => setPaymentTarget(null)}><X size={19} /></button></header>
            <form className={styles.form} onSubmit={(event) => { event.preventDefault(); void recordSubscriptionPaymentTarget().then((saved) => { if (saved) setPaymentTarget(null); }); }}>
              <Field label="Contraparte / Cliente"><input value={historyCustomer?.full_name ?? "Cliente"} readOnly /></Field>
              <Field label="Tipo"><input value="Receita" readOnly /></Field>
              <Field label="Descrição" wide><input value={paymentDescription} onChange={(event) => setPaymentDescription(event.target.value)} required minLength={2} maxLength={500} /></Field>
              <Field label="Saldo restante"><input value={(paymentTarget.amountCents / 100).toFixed(2).replace(".", ",")} readOnly /></Field>
              <Field label="Valor final lançado (R$)"><input value={(paymentTarget.amountCents / 100).toFixed(2).replace(".", ",")} readOnly /></Field>
              <Field label="Data do lançamento"><input type="date" value={paymentDate} onChange={(event) => setPaymentDate(event.target.value)} required /></Field>
              <Field label="Vencimento"><input type="date" value={paymentTarget.dueOn} readOnly /></Field>
              <Field label="Plano de conta"><select value={paymentChartAccountId} onChange={(event) => setPaymentChartAccountId(event.target.value)} required><option value="">Selecione</option>{(chartAccounts as Array<{ id: string; code?: string | null; name?: string; kind?: string; active?: boolean }>).filter((account) => account.active && account.kind === "REVENUE").map((account) => <option key={account.id} value={account.id}>{account.code ? `${account.code} · ` : ""}{account.name}</option>)}</select></Field>
              <Field label="Banco ou caixa"><select value={paymentAccountId} onChange={(event) => setPaymentAccountId(event.target.value)} required><option value="">Selecione</option>{financialAccounts.filter((account) => account.active).map((account) => <option key={String(account.id)} value={String(account.id)}>{String(account.name)}</option>)}</select></Field>
              <Field label="Centro de custo"><select value={paymentCostCenterId} onChange={(event) => setPaymentCostCenterId(event.target.value)}><option value="">Não informar</option>{costCenters.filter((center) => center.active).map((center) => <option key={center.id} value={center.id}>{center.name}</option>)}</select></Field>
              <Field label="Número do documento"><input value={paymentDocumentNumber} onChange={(event) => setPaymentDocumentNumber(event.target.value)} required minLength={2} maxLength={100} /></Field>
              <Field label="Tags"><select aria-label="Tags" multiple size={Math.min(Math.max(financialTags.filter((tag) => tag.active).length, 2), 4)} value={paymentTagIds} onChange={(event) => setPaymentTagIds(Array.from(event.currentTarget.selectedOptions, (option) => option.value))} disabled={!financialTags.some((tag) => tag.active)}>{financialTags.filter((tag) => tag.active).length === 0 ? <option>Nenhuma tag cadastrada</option> : financialTags.filter((tag) => tag.active).map((tag) => <option key={tag.id} value={tag.id} style={tag.color ? { color: tag.color } : undefined}>{tag.name}</option>)}</select></Field>
              <Field label="Forma de recebimento"><select value={paymentMethod} onChange={(event) => setPaymentMethod(event.target.value)} required><option value="CASH">Dinheiro</option><option value="PIX">PIX</option><option value="CARD">Cartão</option><option value="BOLETO">Boleto</option><option value="ONLINE">Link de pagamento</option><option value="UPFRONT">À vista</option></select></Field>
              <Field label="Observações"><input value={paymentReference} onChange={(event) => setPaymentReference(event.target.value)} placeholder="PIX, NSU ou comprovante" maxLength={500} /></Field>
              <div className={`${styles.toolbarGroup} ${styles.formWide}`}><button className={styles.button} type="submit" disabled={!paymentAccountId || !paymentChartAccountId}>Confirmar recebimento</button><button className={`${styles.button} ${styles.buttonSoft}`} type="button" onClick={() => setPaymentTarget(null)}>Cancelar</button></div>
            </form>
          </section>
        </div>}
      </Panel>
    </div>
  );
}
