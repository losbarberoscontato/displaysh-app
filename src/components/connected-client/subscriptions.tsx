"use client";

import { useEffect, useState, type FormEvent } from "react";
import Link from "next/link";
import { CalendarClock, CalendarDays, CalendarPlus, CircleDollarSign, FileText, ReceiptText, XCircle } from "lucide-react";
import { useConnectedClient } from "./context";
import { localToday } from "./format";
import { getAvailableSlots } from "./api";
import type { AvailableSlot, BookingSelection } from "./types";
import { getSupabaseBrowserClient } from "@/lib/supabase/browser";
import { subscriptionDisplayStatus, subscriptionDisplayStatusLabels } from "@/lib/subscription-display-status";
import styles from "./connected-client.module.css";

type Row = {
  id: string;
  plan_id: string;
  status: string;
  contract_accepted_at: string | null;
  manager_activated_provisionally_at: string | null;
  start_date: string | null;
  end_date: string | null;
  first_due_date: string | null;
  payment_method: string;
  created_by: string | null;
  contract_body_snapshot: string | null;
  plan: { name: string; description: string | null } | null;
  plan_version: {
    id: string;
    model: string;
    scheduling_mode: "FREE" | "FIXED" | null;
    price_cents: number;
    billing_period: string;
    sessions_per_cycle: number;
    duration_months: number;
    payment_method: string;
    bundle_scheduling_mode: "FREE" | "FIXED" | null;
    bundle_service_id: string | null;
    bundle_sessions_per_week: number | null;
    bundle_sessions_per_month: number | null;
    bundle_session_duration_minutes: number | null;
    bundle_total_sessions: number | null;
    bundle_price_per_session_cents: number | null;
    bundle_entry_cents: number | null;
    bundle_installment_count: number | null;
    bundle_discount_type: "NONE" | "FIXED" | "PERCENT" | null;
    bundle_discount_value: number | null;
  } | null;
};
type Cycle = {
  id: string;
  subscription_id: string;
  cycle_number: number;
  starts_on: string;
  ends_on: string;
  due_on: string;
  amount_cents: number;
  status: string;
  paid_at?: string | null;
  sessions: {
    id: string;
    session_number: number;
    status: string;
    appointment_id?: string | null;
    rescheduled_from?: string | null;
    appointment?: { status: string; service_period?: string; cancellation_outcome?: string | null; cancelled_at?: string | null; barber_id?: string | null; whatsapp_response_status?: string | null } | null;
  }[];
};
type CancellationRequest = {
  id: string;
  subscription_id: string;
  status: "PENDING" | "CONFIRMED";
  reason: string;
  observations: string | null;
  last_session_id: string | null;
};
type CancellationDraft = { subscriptionId: string; reason: string; observations: string; lastSessionId: string };
type BundleContract = {
  id: string;
  subscription_id: string;
  scheduling_mode: "FREE" | "FIXED";
  service_id: string;
  sessions_per_week: number;
  sessions_per_month: number | null;
  session_duration_minutes: number;
  total_sessions: number;
  price_per_session_cents: number;
  total_price_cents: number;
  entry_cents: number;
  installment_count: number;
  discount_type: "NONE" | "FIXED" | "PERCENT";
  discount_value: number;
  entry_due_on: string | null;
  first_installment_due_on: string;
  first_session_date: string;
};
type BundleInstallment = { id: string; subscription_id: string; installment_number: number; kind: "ENTRY" | "INSTALLMENT"; due_on: string; amount_cents: number; status: "OPEN" | "PAID" | "OVERDUE" | "CANCELED"; paid_at: string | null };
type BundleSession = { id: string; subscription_id: string; session_number: number; release_on: string; scheduled_for: string | null; rescheduled_from?: string | null; installment_number: number; status: "AVAILABLE" | "SCHEDULED" | "COMPLETED" | "CONSUMED" | "CANCELED"; appointment_id: string | null; barber_id?: string | null; appointment?: { status: string; service_period: string | null; cancellation_outcome?: string | null; cancelled_at?: string | null; barber_id?: string | null; whatsapp_response_status?: string | null } | null };
type BundleFixedSlot = { id: string; subscription_id: string; slot_number: number; weekday: number; local_time: string; barber_name_snapshot: string; environment_name_snapshot: string };
type ActivePlanTab = "financeiro" | "agenda" | "contrato";
type SessionCancellationDraft = { sessionId: string; model: "bundle" | "legacy"; reason: string };
type BundleRescheduleDraft = { sessionId: string; barberId: string; localDate: string; startsAt: string; observation: string; slots: Array<{ starts_at: string; ends_at: string }>; loading: boolean };
type LegacyRescheduleDraft = { sessionId: string; barberId: string; localDate: string; startsAt: string; selections: BookingSelection[]; slots: AvailableSlot[]; loading: boolean };

function formatDate(value: string | null) {
  if (!value) return "—";
  const [year, month, day] = value.split("-").map(Number);
  return year && month && day
    ? new Intl.DateTimeFormat("pt-BR").format(new Date(year, month - 1, day))
    : value;
}

function formatDateTime(value: string | null, timezone: string) {
  if (!value) return "—";
  return new Intl.DateTimeFormat("pt-BR", {
    day: "2-digit", month: "2-digit", year: "numeric", hour: "2-digit", minute: "2-digit", timeZone: timezone,
  }).format(new Date(value));
}

function appointmentStart(value: string | null | undefined) {
  const start = value?.match(/\[(.*?),/)?.[1];
  return start ? new Date(start) : null;
}

function localDateKey(value: Date, timezone: string) {
  const parts = new Intl.DateTimeFormat("en-CA", { timeZone: timezone, year: "numeric", month: "2-digit", day: "2-digit" }).formatToParts(value);
  const part = (type: string) => parts.find((item) => item.type === type)?.value ?? "";
  return `${part("year")}-${part("month")}-${part("day")}`;
}

function shiftDateKey(value: string, days: number) {
  const [year, month, day] = value.split("-").map(Number);
  const date = new Date(Date.UTC(year, month - 1, day + days));
  return `${date.getUTCFullYear()}-${String(date.getUTCMonth() + 1).padStart(2, "0")}-${String(date.getUTCDate()).padStart(2, "0")}`;
}

function installmentStatus(status: string, dueOn: string, today: string) {
  if (status === "PAID") return { label: "Pago", tone: "success" };
  if (status === "CANCELED") return { label: "Cancelada", tone: "neutral" };
  if (status === "OVERDUE" || (status === "OPEN" && dueOn < today)) return { label: "Em atraso", tone: "danger" };
  return { label: "Em aberto", tone: "warning" };
}

function sessionStatusLabel(status: string) {
  return ({ AVAILABLE: "Em aberto", SCHEDULED: "Agendada", COMPLETED: "Concluída", CANCELED: "Cancelada", CONSUMED: "Cancelada" } as Record<string, string>)[status] ?? status;
}

function sessionTone(status: string) {
  return status === "COMPLETED" ? "#2f7a4e" : status === "CANCELED" || status === "CONSUMED" ? "#a84136" : status === "SCHEDULED" ? "#b67816" : "#2872ad";
}

function sessionDate(period?: string) {
  const start = period?.match(/\[(.*?),/)?.[1];
  return start ? new Intl.DateTimeFormat("pt-BR", { day: "2-digit", month: "2-digit" }).format(new Date(start)) : "";
}
type AvailablePlan = {
  id: string;
  name: string;
  description: string | null;
  version: {
    id: string;
    version: number;
    price_cents: number;
    billing_period: string;
    duration_months: number;
    sessions_per_cycle: number;
    payment_method: string;
  } | null;
  service_ids: string[];
};

type ProjectOffer = { id: string; project_id: string; package_id: string; status: string; contracted_cents: number; created_by: string; accepted_at: string | null; project: { name: string; description: string | null } | null; package: { name: string; description: string | null; sessions_count: number } | null };
type ProjectInstallment = { id: string; engagement_id: string; installment_number: number; due_on: string; amount_cents: number; status: string; paid_at: string | null };
type ProjectSession = { id: string; engagement_id: string; session_number: number; status: string; appointment_id: string | null; service_id: string | null; barber_id: string | null; appointment?: { status: string; service_period: string | null } | null };
type ProjectCancellationRequest = { id: string; engagement_id: string; status: "PENDING" | "CONFIRMED"; reason: string; observations: string | null; last_session_id: string | null; last_installment_id: string | null };
type ProjectBookingOption = { service_id: string; service_name: string; barber_id: string; barber_name: string };
type ProjectCancellationDraft = { engagementId: string; reason: string; observations: string; lastSessionId: string };
type ProjectBookingDraft = { session: ProjectSession; options: ProjectBookingOption[]; barberId: string; serviceId: string; date: string; time: string; environmentId: string; environments: Array<{ id: string; name: string; sort_order: number }>; loading: boolean };
type PublicProject = { id: string; name: string; description: string | null; starts_on: string | null; sales_close_on: string | null; ends_on: string | null; package: { id: string; name: string; description: string | null; price_cents: number; sessions_count: number }[] };
type SubscriptionView = "my-plans" | "closed-plans" | "my-plan" | "new-plan" | "subscription" | "project" | "subscription-offer" | "project-offer";

const paymentMethodLabel: Record<string, string> = {
  CARD: "Cartão de crédito",
  PIX: "PIX",
  BOLETO: "Boleto",
  CASH: "Dinheiro",
  UPFRONT: "À vista",
  ONLINE: "Link de pagamento",
  CRYPTO: "Cripto",
};
const bundlePaymentMethodLabel: Record<string, string> = {
  ONLINE: "Link de pagamento",
  CARD: "Cartão",
  PIX: "Pix",
  BOLETO: "Boleto",
  CASH: "Dinheiro",
  CRYPTO: "Cripto",
  UPFRONT: "À vista",
};

export function ConnectedSubscriptions({ view = "my-plans", itemId, initialTab = "financeiro" }: { view?: SubscriptionView; itemId?: string; initialTab?: ActivePlanTab }) {
  const { context, customer, user } = useConnectedClient();
  const [rows, setRows] = useState<Row[]>([]);
  const [cycles, setCycles] = useState<Cycle[]>([]);
  const [bundleContracts, setBundleContracts] = useState<BundleContract[]>([]);
  const [bundleInstallments, setBundleInstallments] = useState<BundleInstallment[]>([]);
  const [bundleSessions, setBundleSessions] = useState<BundleSession[]>([]);
  const [bundleFixedSlots, setBundleFixedSlots] = useState<BundleFixedSlot[]>([]);
  const [activePlanTab, setActivePlanTab] = useState<ActivePlanTab>(initialTab);
  const [sessionCancellationDraft, setSessionCancellationDraft] = useState<SessionCancellationDraft | null>(null);
  const [sessionActionBusy, setSessionActionBusy] = useState(false);
  const [bundleRescheduleDraft, setBundleRescheduleDraft] = useState<BundleRescheduleDraft | null>(null);
  const [legacyRescheduleDraft, setLegacyRescheduleDraft] = useState<LegacyRescheduleDraft | null>(null);
  const bundleRescheduleSessionId = bundleRescheduleDraft?.sessionId;
  const bundleRescheduleBarberId = bundleRescheduleDraft?.barberId;
  const bundleRescheduleLocalDate = bundleRescheduleDraft?.localDate;
  const legacyRescheduleSessionId = legacyRescheduleDraft?.sessionId;
  const legacyRescheduleBarberId = legacyRescheduleDraft?.barberId;
  const legacyRescheduleLocalDate = legacyRescheduleDraft?.localDate;
  const legacyRescheduleSelections = legacyRescheduleDraft?.selections;
  const [subscriptionDetailsLoadedFor, setSubscriptionDetailsLoadedFor] = useState("");
  const [projectDetailsLoadedFor, setProjectDetailsLoadedFor] = useState("");
  const [cancellationRequests, setCancellationRequests] = useState<CancellationRequest[]>([]);
  const [cancellationDraft, setCancellationDraft] = useState<CancellationDraft | null>(null);
  const [plans, setPlans] = useState<AvailablePlan[]>([]);
  const [projectOffers, setProjectOffers] = useState<ProjectOffer[]>([]);
  const [projectInstallments, setProjectInstallments] = useState<ProjectInstallment[]>([]);
  const [projectSessions, setProjectSessions] = useState<ProjectSession[]>([]);
  const [projectCancellationRequests, setProjectCancellationRequests] = useState<ProjectCancellationRequest[]>([]);
  const [projectCancellationDraft, setProjectCancellationDraft] = useState<ProjectCancellationDraft | null>(null);
  const [projectBookingDraft, setProjectBookingDraft] = useState<ProjectBookingDraft | null>(null);
  const [publicProjects, setPublicProjects] = useState<PublicProject[]>([]);
  const [contractBody, setContractBody] = useState<string | null>(null);
  const [offerContractOpenFor, setOfferContractOpenFor] = useState<string | null>(null);
  const [message, setMessage] = useState("Carregando assinaturas…");
  const [acceptingSubscriptionOffer, setAcceptingSubscriptionOffer] = useState(false);
  const customerDetailsKey = context && customer && user ? `${context.organization.id}:${customer.id}:${user.id}` : "";
  const subscriptionDetailsLoaded = Boolean(customerDetailsKey) && subscriptionDetailsLoadedFor === customerDetailsKey;
  const projectDetailsLoaded = Boolean(customerDetailsKey) && projectDetailsLoadedFor === customerDetailsKey;
  useEffect(() => {
    const client = getSupabaseBrowserClient();
    if (!client || !context || !customer || !user) {
      queueMicrotask(() =>
        setMessage("Entre na sua conta para consultar assinaturas."),
      );
      return;
    }
    void Promise.all([
      client
        .from("customer_subscriptions")
        .select(
          "id,plan_id,status,contract_accepted_at,manager_activated_provisionally_at,start_date,end_date,first_due_date,payment_method,contract_body_snapshot,created_by,plan:subscription_plans(name,description),plan_version:subscription_plan_versions(id,model,scheduling_mode,price_cents,billing_period,sessions_per_cycle,duration_months,payment_method,bundle_scheduling_mode,bundle_service_id,bundle_sessions_per_week,bundle_sessions_per_month,bundle_session_duration_minutes,bundle_total_sessions,bundle_price_per_session_cents,bundle_entry_cents,bundle_installment_count,bundle_discount_type,bundle_discount_value)",
        )
        .eq("organization_id", context.organization.id)
        .eq("customer_id", customer.id)
        .in("status", ["REQUESTED", "PENDING_PAYMENT", "ACTIVE", "CANCELED", "DECLINED", "EXPIRED"]),
      client.from("customer_subscription_cancellation_requests")
        .select("id,subscription_id,status,reason,observations,last_session_id")
        .eq("organization_id", context.organization.id)
        .eq("customer_id", customer.id)
        .order("requested_at", { ascending: false }),
      client
        .from("subscription_plans")
        .select(
          "id,name,description,version:subscription_plan_versions(id,version,price_cents,billing_period,duration_months,sessions_per_cycle,payment_method)",
        )
        .eq("organization_id", context.organization.id)
        .eq("active", true)
        .is("archived_at", null),
      client.from("project_engagements").select("id,project_id,package_id,status,contracted_cents,created_by,accepted_at,project:projects(name,description),package:project_packages(name,description,sessions_count)")
        .eq("organization_id", context.organization.id).eq("customer_id", customer.id).in("status", ["PROPOSAL", "ACTIVE", "DECLINED", "CANCELED", "CANCELED_BY_ORGANIZATION", "COMPLETED"]),
      client.from("customer_project_cancellation_requests")
        .select("id,engagement_id,status,reason,observations,last_session_id,last_installment_id")
        .eq("organization_id", context.organization.id).eq("customer_id", customer.id).order("requested_at", { ascending: false }),
      client.from("projects").select("id,name,description,starts_on,sales_close_on,ends_on,package:project_packages(id,name,description,price_cents,sessions_count)")
        .eq("organization_id", context.organization.id).eq("status", "PUBLISHED"),
    ]).then(async ([subscriptionsResult, cancellationResult, plansResult, projectResult, projectCancellationResult, publicProjectResult]) => {
      const { data, error } = subscriptionsResult;
      if (error) {
        setMessage(error.message);
        return;
      }
      if (projectResult.error || projectCancellationResult.error) {
        setMessage(projectResult.error?.message ?? projectCancellationResult.error?.message ?? "Não foi possível carregar os planos de projeto.");
        return;
      }
      const subscriptions = (data ?? []) as unknown as Row[];
      setRows(subscriptions);
      const bundleSubscriptionIds = subscriptions
        .filter((item) => item.plan_version?.model === "SESSION_BUNDLE_V1")
        .map((item) => item.id);
      if (bundleSubscriptionIds.length) {
        const [contractResult, installmentResult, bundleSessionResult, fixedSlotResult] = await Promise.all([
          client.from("subscription_bundle_contracts")
            .select("id,subscription_id,scheduling_mode,service_id,sessions_per_week,sessions_per_month,session_duration_minutes,total_sessions,price_per_session_cents,total_price_cents,entry_cents,installment_count,discount_type,discount_value,entry_due_on,first_installment_due_on,first_session_date")
            .eq("organization_id", context.organization.id).in("subscription_id", bundleSubscriptionIds),
          client.from("subscription_bundle_installments")
            .select("id,subscription_id,installment_number,kind,due_on,amount_cents,status,paid_at")
            .eq("organization_id", context.organization.id).in("subscription_id", bundleSubscriptionIds).neq("status", "CANCELED").order("installment_number"),
          client.from("subscription_bundle_sessions")
            .select("id,subscription_id,session_number,release_on,scheduled_for,rescheduled_from,installment_number,status,appointment_id,barber_id")
            .eq("organization_id", context.organization.id).in("subscription_id", bundleSubscriptionIds).is("deleted_at", null).order("session_number"),
          client.from("subscription_bundle_fixed_slots")
            .select("id,subscription_id,slot_number,weekday,local_time,barber_name_snapshot,environment_name_snapshot")
            .eq("organization_id", context.organization.id).in("subscription_id", bundleSubscriptionIds).order("slot_number"),
        ]);
        const bundleError = contractResult.error ?? installmentResult.error ?? bundleSessionResult.error ?? fixedSlotResult.error;
        if (bundleError) { setMessage(bundleError.message); return; }
        const rawBundleSessions = (bundleSessionResult.data ?? []) as BundleSession[];
        const bundleAppointmentIds = rawBundleSessions.map((session) => session.appointment_id).filter((id): id is string => Boolean(id));
        const bundleAppointmentResult = bundleAppointmentIds.length
          ? await client.from("appointments").select("id,status,service_period,cancellation_outcome,cancelled_at,barber_id,whatsapp_response_status").in("id", bundleAppointmentIds)
          : { data: [] as Array<{ id: string; status: string; service_period: string | null; cancellation_outcome?: string | null; cancelled_at?: string | null; barber_id?: string | null; whatsapp_response_status?: string | null }>, error: null };
        if (bundleAppointmentResult.error) { setMessage(bundleAppointmentResult.error.message); return; }
        const bundleAppointmentMap = new Map((bundleAppointmentResult.data ?? []).map((appointment) => [appointment.id, appointment]));
        setBundleContracts((contractResult.data ?? []) as BundleContract[]);
        setBundleInstallments((installmentResult.data ?? []) as BundleInstallment[]);
        setBundleSessions(rawBundleSessions.filter((session) => !session.appointment_id || bundleAppointmentMap.has(session.appointment_id)).map((session) => ({
          ...session,
          appointment: session.appointment_id ? bundleAppointmentMap.get(session.appointment_id) ?? null : null,
        })));
        setBundleFixedSlots((fixedSlotResult.data ?? []) as BundleFixedSlot[]);
      } else {
        setBundleContracts([]);
        setBundleInstallments([]);
        setBundleSessions([]);
        setBundleFixedSlots([]);
      }
      setCancellationRequests((cancellationResult.data ?? []) as CancellationRequest[]);
      const engagements = (projectResult.data ?? []) as unknown as ProjectOffer[];
      setProjectOffers(engagements);
      setProjectCancellationRequests((projectCancellationResult.data ?? []) as ProjectCancellationRequest[]);
      const engagementIds = engagements.map((item) => item.id);
      if (engagementIds.length) {
        const [installmentResult, sessionResult] = await Promise.all([
          client.from("project_installments").select("id,engagement_id,installment_number,due_on,amount_cents,status,paid_at")
            .eq("organization_id", context.organization.id).in("engagement_id", engagementIds).neq("status", "CANCELED").order("installment_number"),
          client.from("project_engagement_sessions").select("id,engagement_id,session_number,status,appointment_id,service_id,barber_id")
            .eq("organization_id", context.organization.id).in("engagement_id", engagementIds).order("session_number"),
        ]);
        if (installmentResult.error) { setMessage(installmentResult.error.message); return; }
        if (sessionResult.error) { setMessage(sessionResult.error.message); return; }
        const sessionRows = (sessionResult.data ?? []) as ProjectSession[];
        const appointmentIds = sessionRows.map((session) => session.appointment_id).filter((id): id is string => Boolean(id));
        const appointmentResult = appointmentIds.length
          ? await client.from("appointments").select("id,status,service_period").in("id", appointmentIds)
          : { data: [] as Array<{ id: string; status: string; service_period: string | null }>, error: null };
        if (appointmentResult.error) { setMessage(appointmentResult.error.message); return; }
        const visibleProjectAppointmentIds = new Set((appointmentResult.data ?? []).map((appointment) => appointment.id));
        setProjectInstallments((installmentResult.data ?? []) as ProjectInstallment[]);
        setProjectSessions(sessionRows.filter((session) => !session.appointment_id || visibleProjectAppointmentIds.has(session.appointment_id)).map((session) => ({
          ...session,
          appointment: session.appointment_id ? (appointmentResult.data ?? []).find((appointment) => appointment.id === session.appointment_id) ?? null : null,
        })));
      } else {
        setProjectInstallments([]);
        setProjectSessions([]);
      }
      setProjectDetailsLoadedFor(customerDetailsKey);
      setPublicProjects(((publicProjectResult.data ?? []) as unknown as PublicProject[]).map((project) => ({ ...project, package: Array.isArray(project.package) ? project.package : project.package ? [project.package] : [] })));
      const normalizedPlans = ((plansResult.data ?? []) as unknown as AvailablePlan[]).map((plan) => {
        const versions = Array.isArray(plan.version) ? plan.version : plan.version ? [plan.version] : [];
        return {
          ...plan,
          version: versions.sort((left, right) => right.version - left.version)[0] ?? null,
        };
      });
      const planVersionIds = normalizedPlans.map((plan) => plan.version?.id).filter((id): id is string => Boolean(id));
      if (planVersionIds.length) {
        const { data: serviceRows } = await client
          .from("subscription_plan_services")
          .select("plan_version_id,service_id")
          .eq("organization_id", context.organization.id)
          .in("plan_version_id", planVersionIds);
        setPlans(normalizedPlans.map((plan) => ({
          ...plan,
          service_ids: (serviceRows ?? [])
            .filter((row) => row.plan_version_id === plan.version?.id)
            .map((row) => row.service_id),
        })));
      } else {
        setPlans(normalizedPlans.map((plan) => ({ ...plan, service_ids: [] })));
      }
      const contract = await client
        .from("subscription_contract_versions")
        .select("body")
        .eq("active", true)
        .maybeSingle();
      if (!contract.error) setContractBody(contract.data?.body ?? null);
      setMessage("");
      if (!subscriptions.some((item) => item.status !== "DECLINED")) {
        setCycles([]);
        setSubscriptionDetailsLoadedFor(customerDetailsKey);
        return;
      }
      const { data: cycleRows, error: cycleError } = await client
        .from("customer_subscription_cycles")
        .select("id,subscription_id,cycle_number,starts_on,ends_on,due_on,amount_cents,status,paid_at")
        .eq("organization_id", context.organization.id)
        .in(
          "subscription_id",
          subscriptions.filter((item) => item.status !== "DECLINED").map((item) => item.id),
        )
        .order("cycle_number");
      if (cycleError) {
        setMessage(cycleError.message);
        return;
      }
      const normalizedCycles = (cycleRows ?? []) as unknown as Omit<Cycle, "sessions">[];
      const { data: sessionRows, error: sessionError } = await client
        .from("customer_subscription_sessions")
        .select("id,subscription_id,cycle_id,session_number,status,appointment_id,rescheduled_from")
        .eq("organization_id", context.organization.id)
        .in("subscription_id", subscriptions.filter((item) => item.status !== "DECLINED").map((item) => item.id))
        .order("session_number");
      if (sessionError) {
        setMessage(sessionError.message);
        return;
      }
      const appointmentIds = (sessionRows ?? []).map((session) => session.appointment_id).filter(Boolean) as string[];
      const appointmentResult = appointmentIds.length
        ? await client.from("appointments").select("id,status,service_period,cancellation_outcome,cancelled_at,barber_id,whatsapp_response_status").in("id", appointmentIds)
        : { data: [] as Array<{ id: string; status: string; service_period?: string; cancellation_outcome?: string | null; cancelled_at?: string | null; barber_id?: string | null; whatsapp_response_status?: string | null }>, error: null };
      if (appointmentResult.error) {
        setMessage(appointmentResult.error.message);
        return;
      }
      const visibleSubscriptionAppointmentIds = new Set((appointmentResult.data ?? []).map((appointment) => appointment.id));
      setCycles(normalizedCycles.map((cycle) => ({
        ...cycle,
        sessions: (sessionRows ?? []).filter((session) => session.cycle_id === cycle.id && (!session.appointment_id || visibleSubscriptionAppointmentIds.has(session.appointment_id))).map((session) => ({
          id: session.id,
          session_number: session.session_number,
          status: session.status,
          appointment_id: session.appointment_id,
          rescheduled_from: session.rescheduled_from,
          appointment: session.appointment_id ? (appointmentResult.data ?? []).find((appointment) => appointment.id === session.appointment_id) ?? null : null,
        })),
      })));
      setSubscriptionDetailsLoadedFor(customerDetailsKey);
    });
  }, [context, customer, customerDetailsKey, user]);

  useEffect(() => {
    if (!context || !customer || !bundleRescheduleSessionId || !bundleRescheduleBarberId || !bundleRescheduleLocalDate) return;
    const client = getSupabaseBrowserClient();
    if (!client) return;
    let active = true;
    const sessionId = bundleRescheduleSessionId;
    const barberId = bundleRescheduleBarberId;
    const localDate = bundleRescheduleLocalDate;
    queueMicrotask(() => setBundleRescheduleDraft((current) => current?.sessionId === sessionId ? { ...current, loading: true, slots: [], startsAt: "" } : current));
    void Promise.resolve(client.rpc("get_customer_subscription_bundle_reschedule_slots", {
      p_organization_id: context.organization.id,
      p_customer_id: customer.id,
      p_session_id: sessionId,
      p_barber_id: barberId,
      p_local_date: localDate,
    })).then(({ data, error }) => {
      if (error) throw error;
      const slots = ((data as { slots?: BundleRescheduleDraft["slots"] } | null)?.slots ?? []);
      if (active) setBundleRescheduleDraft((current) => current?.sessionId === sessionId && current.barberId === barberId && current.localDate === localDate
        ? { ...current, loading: false, slots }
        : current);
    }).catch((error: unknown) => {
      if (!active) return;
      setMessage(error instanceof Error ? error.message : "Não foi possível consultar os horários.");
      setBundleRescheduleDraft((current) => current?.sessionId === sessionId ? { ...current, loading: false, slots: [] } : current);
    });
    return () => { active = false; };
  }, [bundleRescheduleSessionId, bundleRescheduleBarberId, bundleRescheduleLocalDate, context, customer]);

  useEffect(() => {
    if (!context || !legacyRescheduleSessionId || !legacyRescheduleBarberId || !legacyRescheduleLocalDate || !legacyRescheduleSelections) return;
    const client = getSupabaseBrowserClient();
    if (!client) return;
    let active = true;
    const sessionId = legacyRescheduleSessionId;
    const barberId = legacyRescheduleBarberId;
    const localDate = legacyRescheduleLocalDate;
    const selections = legacyRescheduleSelections;
    queueMicrotask(() => setLegacyRescheduleDraft((current) => current?.sessionId === sessionId ? { ...current, loading: true, slots: [], startsAt: "" } : current));
    void getAvailableSlots(client, {
      organizationSlug: context.organization.slug,
      barberId,
      localDate,
      selections,
    }).then((availability) => {
      if (active) setLegacyRescheduleDraft((current) => current?.sessionId === sessionId && current.barberId === barberId && current.localDate === localDate
        ? { ...current, loading: false, slots: availability?.slots ?? [] }
        : current);
    }).catch((error: unknown) => {
      if (!active) return;
      setMessage(error instanceof Error ? error.message : "Não foi possível consultar os horários.");
      setLegacyRescheduleDraft((current) => current?.sessionId === sessionId ? { ...current, loading: false, slots: [] } : current);
    });
    return () => { active = false; };
  }, [context, legacyRescheduleSessionId, legacyRescheduleBarberId, legacyRescheduleLocalDate, legacyRescheduleSelections]);

  async function acceptSubscriptionOffer(id: string) {
    if (!context || acceptingSubscriptionOffer) return;
    const client = getSupabaseBrowserClient();
    if (!client) {
      setMessage("Não foi possível conectar ao sistema. Atualize a página e tente novamente.");
      return;
    }
    setAcceptingSubscriptionOffer(true);
    try {
      const { error } = await client.rpc("accept_customer_subscription_offer", { p_organization_id: context.organization.id, p_subscription_id: id });
      if (error) {
        setMessage(`Não foi possível confirmar a assinatura: ${error.message}`);
        return;
      }
      window.location.assign(route("/cliente/assinaturas"));
    } catch (error) {
      setMessage(`Não foi possível confirmar a assinatura: ${error instanceof Error ? error.message : "falha de comunicação"}`);
    } finally {
      setAcceptingSubscriptionOffer(false);
    }
  }
  async function acceptProjectOffer(offer: ProjectOffer) {
    if (!context) return;
    if (!window.confirm(`Confirmar o plano ${offer.project?.name ?? "oferecido"} · ${offer.package?.name ?? "pacote"}?`)) return;
    const client = getSupabaseBrowserClient(); if (!client) return;
    const { error } = await client.rpc("accept_customer_project_engagement", { p_organization_id: context.organization.id, p_engagement_id: offer.id });
    setMessage(error ? error.message : "Plano confirmado.");
    if (!error) window.location.assign(route("/cliente/assinaturas"));
  }
  async function declineSubscriptionOffer(id: string) {
    if (!context || !window.confirm("Recusar este plano? Ele será arquivado como recusado e o gestor será avisado.")) return;
    const client = getSupabaseBrowserClient(); if (!client) return;
    const { error } = await client.rpc("decline_customer_subscription_offer", { p_organization_id: context.organization.id, p_subscription_id: id });
    setMessage(error ? error.message : "Plano recusado e arquivado.");
    if (!error) window.location.assign(route("/cliente/assinaturas"));
  }
  async function declineProjectOffer(offer: ProjectOffer) {
    if (!context || !window.confirm("Recusar este plano? Ele será arquivado como recusado e o gestor será avisado.")) return;
    const client = getSupabaseBrowserClient(); if (!client) return;
    const { error } = await client.rpc("decline_customer_project_engagement", { p_organization_id: context.organization.id, p_engagement_id: offer.id });
    setMessage(error ? error.message : "Plano recusado e arquivado.");
    if (!error) window.location.assign(route("/cliente/assinaturas"));
  }
  async function requestProject(projectId: string, packageId: string, projectName: string, packageName: string) {
    if (!context || !window.confirm(`Solicitar o pacote ${packageName} do plano ${projectName}?`)) return;
    const client = getSupabaseBrowserClient(); if (!client) return;
    const { error } = await client.rpc("request_customer_project_engagement", { p_organization_id: context.organization.id, p_project_id: projectId, p_package_id: packageId });
    setMessage(error ? error.message : "Solicitação enviada. Aguarde contato do gestor.");
    if (!error) window.location.assign(route("/cliente/assinaturas"));
  }
  async function requestSubscriptionCancellation(event: FormEvent<HTMLFormElement>) {
    event.preventDefault();
    if (!context || !cancellationDraft) return;
    const client = getSupabaseBrowserClient();
    if (!client) return;
    const draft = cancellationDraft;
    const { error } = await client.rpc("request_customer_subscription_cancellation", {
      p_organization_id: context.organization.id,
      p_subscription_id: draft.subscriptionId,
      p_last_session_id: draft.lastSessionId || null,
      p_reason: draft.reason,
      p_observations: draft.reason === "OTHER" ? draft.observations : null,
    });
    setMessage(error ? error.message : "Solicitação enviada. O cancelamento será concluído após a confirmação do estabelecimento.");
    if (!error) window.location.reload();
    else setCancellationDraft(draft);
  }
  async function requestProjectCancellation(event: FormEvent<HTMLFormElement>) {
    event.preventDefault();
    if (!context || !projectCancellationDraft) return;
    const draft = projectCancellationDraft;
    const client = getSupabaseBrowserClient();
    if (!client) return;
    const { error } = await client.rpc("request_customer_project_cancellation", {
      p_organization_id: context.organization.id,
      p_engagement_id: draft.engagementId,
      p_last_session_id: draft.lastSessionId || null,
      p_reason: draft.reason,
      p_observations: draft.reason === "OTHER" ? draft.observations : null,
    });
    setMessage(error ? error.message : "Solicitação enviada. O cancelamento será concluído após a confirmação do estabelecimento.");
    if (!error) window.location.reload();
  }
  async function openProjectBooking(session: ProjectSession) {
    if (!context) return;
    const client = getSupabaseBrowserClient();
    if (!client) return;
    const { data, error } = await client.rpc("get_customer_project_booking_options", { p_organization_id: context.organization.id, p_session_id: session.id });
    if (error) { setMessage(error.message); return; }
    const options = (data ?? []) as ProjectBookingOption[];
    if (!options.length) { setMessage("Este pacote ainda não possui serviços e profissionais habilitados para agendamento."); return; }
    const first = options[0];
    setProjectBookingDraft({ session, options, barberId: first.barber_id, serviceId: first.service_id, date: localToday(context.organization.timezone), time: "09:00", environmentId: "", environments: [], loading: false });
  }
  async function refreshProjectBookingEnvironments(draft: ProjectBookingDraft) {
    if (!context || !draft.barberId || !draft.serviceId || !draft.date || !draft.time) return;
    const client = getSupabaseBrowserClient();
    if (!client) return;
    setProjectBookingDraft((current) => current ? { ...current, loading: true, environments: [], environmentId: "" } : current);
    const { data, error } = await client.rpc("get_project_session_environments", {
      p_organization_id: context.organization.id,
      p_session_id: draft.session.id,
      p_barber_id: draft.barberId,
      p_service_id: draft.serviceId,
      p_starts_at: new Date(`${draft.date}T${draft.time}:00`).toISOString(),
    });
    const environments = (data ?? []) as Array<{ id: string; name: string; sort_order: number }>;
    setProjectBookingDraft((current) => current ? { ...current, loading: false, environments: error ? [] : environments, environmentId: error ? "" : environments[0]?.id ?? "" } : current);
    if (error) setMessage(error.message);
  }
  async function bookProjectSession(event: FormEvent<HTMLFormElement>) {
    event.preventDefault();
    if (!context || !projectBookingDraft || projectBookingDraft.loading || !projectBookingDraft.environmentId) return;
    const draft = projectBookingDraft;
    const client = getSupabaseBrowserClient();
    if (!client) return;
    const { error } = await client.rpc("create_project_appointment", {
      p_organization_id: context.organization.id,
      p_session_id: draft.session.id,
      p_barber_id: draft.barberId,
      p_service_id: draft.serviceId,
      p_starts_at: new Date(`${draft.date}T${draft.time}:00`).toISOString(),
      p_environment_id: draft.environmentId,
      p_override_reason: null,
      p_notes: "Atendimento de projeto agendado pelo cliente",
    });
    setMessage(error ? error.message : "Sessão do plano agendada.");
    if (!error) window.location.reload();
  }
  async function submitSessionCancellation(event: FormEvent<HTMLFormElement>) {
    event.preventDefault();
    if (!context || !customer || !sessionCancellationDraft || sessionActionBusy) return;
    const client = getSupabaseBrowserClient();
    if (!client) return;
    const draft = sessionCancellationDraft;
    setSessionActionBusy(true);
    try {
      const { error } = draft.model === "bundle"
        ? await client.rpc("cancel_customer_subscription_bundle_session", {
            p_organization_id: context.organization.id,
            p_customer_id: customer.id,
            p_session_id: draft.sessionId,
            p_reason: draft.reason.trim(),
          })
        : await client.rpc("cancel_customer_subscription_session", {
            p_organization_id: context.organization.id,
            p_customer_id: customer.id,
            p_subscription_session_id: draft.sessionId,
            p_reason: draft.reason.trim(),
          });
      setMessage(error ? error.message : "Cancelamento de sessão registrado.");
      if (!error) window.location.reload();
    } catch (error) {
      setMessage(error instanceof Error ? error.message : "Não foi possível cancelar a sessão.");
    } finally {
      setSessionActionBusy(false);
    }
  }

  async function openBundleReschedule(session: BundleSession, row: Row) {
    if (!context) return;
    const contract = bundleContracts.find((item) => item.subscription_id === row.id);
    const eligible = context.barbers.filter((barber) => barber.subscription_plan_ids?.includes(row.plan_id)
      && barber.service_ids?.includes(contract?.service_id ?? ""));
    const currentBarberId = session.appointment?.barber_id ?? session.barber_id ?? "";
    const barberId = eligible.find((barber) => barber.id === currentBarberId)?.id ?? eligible[0]?.id ?? currentBarberId;
    const today = localToday(context.organization.timezone);
    const originalDate = session.rescheduled_from || session.scheduled_for
      ? localDateKey(new Date(session.rescheduled_from ?? session.scheduled_for!), context.organization.timezone)
      : today;
    const earliest = shiftDateKey(originalDate, -14);
    const localDate = today > earliest ? today : earliest;
    setBundleRescheduleDraft({ sessionId: session.id, barberId, localDate, startsAt: "", observation: "", slots: [], loading: false });
  }

  async function openLegacyReschedule(session: Cycle["sessions"][number], row: Row) {
    if (!context || !row.plan_version?.id) return;
    const client = getSupabaseBrowserClient();
    if (!client) return;
    const { data, error } = await client.from("subscription_plan_services").select("service_id")
      .eq("organization_id", context.organization.id).eq("plan_version_id", row.plan_version.id);
    if (error) { setMessage(error.message); return; }
    const serviceIds = [...new Set((data ?? []).map((item) => item.service_id).filter(Boolean))];
    const selections: BookingSelection[] = serviceIds.map((serviceId) => ({ type: "SERVICE", service_id: serviceId, quantity: 1 }));
    const eligible = context.barbers.filter((barber) => barber.subscription_plan_ids?.includes(row.plan_id)
      && serviceIds.length > 0 && serviceIds.every((serviceId) => barber.service_ids?.includes(serviceId)));
    if (!selections.length || !eligible.length) {
      setMessage("Não há serviços e profissionais habilitados para reagendar esta sessão.");
      return;
    }
    const currentBarberId = session.appointment?.barber_id ?? "";
    const barberId = eligible.find((barber) => barber.id === currentBarberId)?.id ?? eligible[0]?.id ?? "";
    const today = localToday(context.organization.timezone);
    const source = session.rescheduled_from ?? appointmentStart(session.appointment?.service_period)?.toISOString() ?? today;
    const sourceDate = source === today ? today : localDateKey(new Date(source), context.organization.timezone);
    const earliest = shiftDateKey(sourceDate, -14);
    setLegacyRescheduleDraft({ sessionId: session.id, barberId, localDate: today > earliest ? today : earliest, startsAt: "", selections, slots: [], loading: false });
  }

  async function submitBundleReschedule(event: FormEvent<HTMLFormElement>) {
    event.preventDefault();
    if (!context || !customer || !bundleRescheduleDraft || !bundleRescheduleDraft.barberId || !bundleRescheduleDraft.startsAt || sessionActionBusy) return;
    const client = getSupabaseBrowserClient();
    if (!client) return;
    const draft = bundleRescheduleDraft;
    setSessionActionBusy(true);
    try {
      const { error } = await client.rpc("reschedule_customer_subscription_bundle_session", {
        p_organization_id: context.organization.id,
        p_customer_id: customer.id,
        p_session_id: draft.sessionId,
        p_barber_id: draft.barberId,
        p_starts_at: draft.startsAt,
        p_reason: draft.observation.trim() || null,
      });
      setMessage(error ? error.message : "Sessão reagendada. O estabelecimento e os participantes serão avisados.");
      if (!error) window.location.reload();
    } catch (error) {
      setMessage(error instanceof Error ? error.message : "Não foi possível reagendar a sessão.");
    } finally {
      setSessionActionBusy(false);
    }
  }

  async function submitLegacyReschedule(event: FormEvent<HTMLFormElement>) {
    event.preventDefault();
    if (!context || !legacyRescheduleDraft?.barberId || !legacyRescheduleDraft.startsAt || sessionActionBusy) return;
    const client = getSupabaseBrowserClient();
    if (!client) return;
    const draft = legacyRescheduleDraft;
    setSessionActionBusy(true);
    try {
      const { error } = await client.rpc("reschedule_fixed_customer_subscription_session", {
        p_organization_id: context.organization.id,
        p_subscription_session_id: draft.sessionId,
        p_new_starts_at: draft.startsAt,
        p_new_barber_id: draft.barberId,
      });
      setMessage(error ? error.message : "Sessão reagendada. O estabelecimento e os participantes serão avisados.");
      if (!error) window.location.reload();
    } catch (error) {
      setMessage(error instanceof Error ? error.message : "Não foi possível reagendar a sessão.");
    } finally {
      setSessionActionBusy(false);
    }
  }
  const route = (path: string) => `${path}${context?.organization.slug ? `?barbearia=${encodeURIComponent(context.organization.slug)}` : ""}`;
  const money = (cents: number) => new Intl.NumberFormat("pt-BR", { style: "currency", currency: "BRL" }).format(cents / 100);
  const percentage = (basisPoints: number) => `${(basisPoints / 100).toFixed(2).replace(".", ",")}%`;
  const subscriptionStatusLabel: Record<string, string> = { REQUESTED: "Aguardando aprovação", PENDING_PAYMENT: "Aguardando pagamento", ACTIVE: "Ativa", CANCELED: "Cancelada", EXPIRED: "Encerrada", DECLINED: "Recusada" };
  const projectCancellationRequestByEngagement = new Map(projectCancellationRequests.map((request) => [request.engagement_id, request]));
  const projectCancellationArchiveReady = (engagement: ProjectOffer) => ["CANCELED", "CANCELED_BY_ORGANIZATION", "COMPLETED"].includes(engagement.status)
    && projectDetailsLoaded
    && !projectInstallments.some((item) => item.engagement_id === engagement.id && item.status === "OPEN")
    && !projectSessions.some((item) => item.engagement_id === engagement.id && ["OPEN", "BOOKED"].includes(item.status));
  const projectSessionLabel = (session: ProjectSession) => session.status === "BOOKED" ? "Agendada" : session.status === "COMPLETED" ? "Concluída" : session.status === "CANCELED" ? "Cancelada" : "Disponível";
  const cancellationRequestBySubscription = new Map(cancellationRequests.map((request) => [request.subscription_id, request]));
  const subscriptionHasPendingCancellation = (id: string) => cancellationRequestBySubscription.get(id)?.status === "PENDING";
  const cancellationArchiveReady = (row: Row) => {
    if (!["CANCELED", "EXPIRED"].includes(row.status) || !subscriptionDetailsLoaded) return false;
    if (row.plan_version?.model === "SESSION_BUNDLE_V1") {
      return !bundleInstallments.some((item) => item.subscription_id === row.id && ["OPEN", "OVERDUE"].includes(item.status))
        && !bundleSessions.some((item) => item.subscription_id === row.id && ["AVAILABLE", "SCHEDULED"].includes(item.status));
    }
    const rowCycles = cycles.filter((cycle) => cycle.subscription_id === row.id);
    return !rowCycles.some((cycle) => cycle.status === "OPEN" || cycle.status === "OVERDUE")
      && !rowCycles.some((cycle) => cycle.sessions.some((session) => session.status === "AVAILABLE" || session.status === "SCHEDULED"));
  };
  const dateRange = (start: string | null, end: string | null) => start || end ? `${start ? formatDate(start) : "—"} a ${end ? formatDate(end) : "—"}` : null;
  const isPendingManagerOffer = (row: Row) => row.created_by !== user?.id
    && !row.contract_accepted_at
    && (row.status === "REQUESTED" || (row.status === "ACTIVE" && Boolean(row.manager_activated_provisionally_at)));
  const statusToday = context ? localToday(context.organization.timezone) : new Date().toISOString().slice(0, 10);
  const subscriptionDisplayStatusFor = (row: Row) => subscriptionDisplayStatus(
    row,
    cycles.filter((cycle) => cycle.subscription_id === row.id),
    statusToday,
    subscriptionHasPendingCancellation(row.id),
  );
  const requestedOffers = rows.filter(isPendingManagerOffer);
  const selectedPlan = plans.find((plan) => plan.id === itemId);
  const selectedProject = publicProjects.find((project) => project.id === itemId);
  const selectedSubscriptionOffer = requestedOffers.find((row) => row.id === itemId);
  const selectedBundleOfferContract = bundleContracts.find((contract) => contract.subscription_id === selectedSubscriptionOffer?.id);
  const selectedBundleOfferSlots = bundleFixedSlots.filter((slot) => slot.subscription_id === selectedSubscriptionOffer?.id);
  const selectedProjectOffer = projectOffers.find((offer) => offer.status === "PROPOSAL" && offer.created_by !== user?.id && offer.id === itemId);
  const selectedCustomerProject = projectOffers.find((offer) => offer.id === itemId && offer.status !== "DECLINED" && !projectCancellationArchiveReady(offer));
  const selectedCustomerSubscription = rows.find((row) => row.id === itemId && row.status !== "DECLINED" && !isPendingManagerOffer(row) && !cancellationArchiveReady(row));

  if (view === "new-plan") return <section className={styles.subscriptionStack}>
    <header><Link href={route("/cliente/assinaturas")} className={styles.subscriptionBack}>← Assinaturas</Link><h1>Planos e projetos</h1><p>Consulte as opções disponíveis deste estabelecimento.</p></header>
    {message && <p>{message}</p>}
    {!user && <p>Entre na sua conta para consultar e solicitar planos.</p>}
    {user && publicProjects.filter((project) => project.package.length > 0).map((project) => {
      const prices = project.package.map((pkg) => pkg.price_cents);
      const range = Math.min(...prices) === Math.max(...prices) ? money(prices[0]) : `${money(Math.min(...prices))} a ${money(Math.max(...prices))}`;
      return <Link className={styles.subscriptionCard} key={project.id} href={route(`/cliente/assinaturas/novo-plano/projeto/${project.id}`)}>
        <span className={styles.planKind}>Plano</span><h2>{project.name}</h2><p>{project.description ?? "Plano com opções de pacote."}</p><strong>{range}</strong><small>{project.package.length} opção(ões) de pacote</small><span>Ver detalhes e pacotes</span>
      </Link>;
    })}
    {user && !publicProjects.some((project) => project.package.length) && <p>Nenhum projeto disponível neste estabelecimento no momento.</p>}
  </section>;

  if (view === "subscription" && selectedPlan) return <section className={styles.subscriptionStack}>
    <header><Link href={route("/cliente/assinaturas/novo-plano")} className={styles.subscriptionBack}>← Novo Plano</Link><span className={styles.planKind}>Plano</span><h1>{selectedPlan.name}</h1><p>{selectedPlan.description ?? "Sem descrição cadastrada."}</p></header>
    <article className={styles.subscriptionCard}>
      <h2>Detalhes do plano</h2><strong>{selectedPlan.version ? money(selectedPlan.version.price_cents) : "Valor sob consulta"}</strong>
      {selectedPlan.version && <p>{selectedPlan.version.billing_period === "BIWEEKLY" ? "Quinzenal" : "Mensal"} · {selectedPlan.version.duration_months} mês(es) · {selectedPlan.version.sessions_per_cycle} sessão(ões) por ciclo · pagamento: {paymentMethodLabel[selectedPlan.version.payment_method] ?? selectedPlan.version.payment_method}</p>}
      {selectedPlan.service_ids.length > 0 && <div><h3>Serviços incluídos</h3><ul>{selectedPlan.service_ids.map((id) => <li key={id}>{context?.services.find((service) => service.id === id)?.name ?? "Serviço incluído"}</li>)}</ul></div>}
      {contractBody && <details><summary>Contrato padrão</summary><p>{contractBody}</p></details>}
    </article>

  </section>;

  if (view === "project" && selectedProject) return <section className={styles.subscriptionStack}>
    <header><Link href={route("/cliente/assinaturas/novo-plano")} className={styles.subscriptionBack}>← Novo Plano</Link><span className={styles.planKind}>Plano</span><h1>{selectedProject.name}</h1><p>{selectedProject.description ?? "Consulte os pacotes disponíveis para este plano."}</p>{dateRange(selectedProject.starts_on, selectedProject.ends_on) && <small>Período: {dateRange(selectedProject.starts_on, selectedProject.ends_on)}{selectedProject.sales_close_on ? ` · Solicitações até ${formatDate(selectedProject.sales_close_on)}` : ""}</small>}</header>
    <h2>Escolha uma opção</h2>
    {selectedProject.package.map((pkg) => <article className={styles.subscriptionCard} key={pkg.id}><h3>{pkg.name}</h3><p>{pkg.description ?? selectedProject.description ?? "Detalhes do pacote."}</p><small>{pkg.sessions_count} sessão(ões)</small><strong>{money(pkg.price_cents)}</strong><button className={styles.subscriptionAction} type="button" onClick={() => void requestProject(selectedProject.id, pkg.id, selectedProject.name, pkg.name)}>Solicitar plano</button></article>)}
  </section>;

  if (view === "subscription-offer" && selectedSubscriptionOffer) return <section className={styles.subscriptionStack}>
    <header>
      <Link href={route("/cliente/assinaturas")} className={styles.subscriptionBack}>← Assinaturas</Link>
      <span className={styles.planKind}>Plano enviado pelo gestor</span>
      <h1 className={styles.subscriptionOfferTitle}>{selectedSubscriptionOffer.plan?.name ?? "Plano"}</h1>
      <p className={styles.subscriptionOfferDescription}>{selectedSubscriptionOffer.plan?.description ?? "Confira os detalhes antes de aceitar ou recusar."}</p>
    </header>
    <article className={styles.subscriptionCard}>
      {selectedSubscriptionOffer.plan_version?.model === "SESSION_BUNDLE_V1" ? (() => {
        const version = selectedSubscriptionOffer.plan_version;
        const contract = selectedBundleOfferContract;
        const totalSessions = Number(contract?.total_sessions ?? version.bundle_total_sessions ?? 0);
        const sessionsPerWeek = Number(contract?.sessions_per_week ?? version.bundle_sessions_per_week ?? 1);
        const sessionsPerMonth = Number(contract?.sessions_per_month ?? (contract ? 0 : version.bundle_sessions_per_month ?? 0));
        const sessionDuration = Number(contract?.session_duration_minutes ?? version.bundle_session_duration_minutes ?? 0);
        const schedulingMode = contract?.scheduling_mode ?? version.bundle_scheduling_mode;
        const pricePerSession = Number(contract?.price_per_session_cents ?? version.bundle_price_per_session_cents ?? 0);
        const total = Number(contract?.total_price_cents ?? pricePerSession * totalSessions);
        const entryCents = Number(contract?.entry_cents ?? version.bundle_entry_cents ?? 0);
        const installmentCount = Math.max(1, Number(contract?.installment_count ?? version.bundle_installment_count ?? 1));
        const baseInstallment = Math.floor(total / installmentCount);
        const discountType = contract?.discount_type ?? version.bundle_discount_type;
        const discountValue = Number(contract?.discount_value ?? version.bundle_discount_value ?? 0);
        const discount = discountType === "PERCENT"
          ? Math.round(baseInstallment * discountValue / 10000)
          : discountType === "FIXED" ? discountValue : 0;
        const discountedInstallment = Math.max(0, baseInstallment - discount);
        const discountLabel = discountType === "PERCENT"
          ? percentage(discountValue)
          : discountType === "FIXED" ? money(discountValue) : "Sem desconto";
        const weekdays = ["Domingo", "Segunda-feira", "Terça-feira", "Quarta-feira", "Quinta-feira", "Sexta-feira", "Sábado"];
        const serviceName = context?.services.find((service) => service.id === contract?.service_id)?.name ?? "Serviço do plano";
        return <>
          <div className={styles.subscriptionOfferSummary}>
            <h2>Resumo da assinatura</h2>
            <p><strong>Plano:</strong> {selectedSubscriptionOffer.plan?.name ?? "Plano"} · <strong>Serviço:</strong> {serviceName}</p>
            <p><strong>Agendamento:</strong> {schedulingMode === "FIXED" ? `Fixo · ${sessionsPerWeek} sessões por semana` : `Livre · ${totalSessions} sessões${sessionsPerMonth > 0 ? ` · ${sessionsPerMonth} por mês` : ` · ${sessionsPerWeek} por semana`}`}</p>
            <p><strong>Primeira sessão:</strong> {formatDate(contract?.first_session_date ?? null)} · <strong>Duração:</strong> {sessionDuration} min</p>
            {schedulingMode === "FIXED" && <ul>{selectedBundleOfferSlots.map((slot) => <li key={slot.id}>Sessão {slot.slot_number}: {slot.barber_name_snapshot} · {slot.environment_name_snapshot} · {weekdays[slot.weekday] ?? "Dia não definido"} · {slot.local_time.slice(0, 5)}</li>)}</ul>}
            <div className={styles.subscriptionOfferFinance}>
              <p><strong>Total do plano:</strong> {money(total)} <span aria-hidden="true">|</span> <strong>Parcelas:</strong> {installmentCount} <span aria-hidden="true">|</span> <strong>Desconto por parcela:</strong> {discountLabel}</p>
              <p><strong>Valor por sessão:</strong> {money(pricePerSession)}</p>
              {entryCents > 0
                ? <p><strong>Entrada:</strong> {money(entryCents)} <span aria-hidden="true">|</span> <strong>Venc.:</strong> {formatDate(contract?.entry_due_on ?? null)}</p>
                : <p><strong>Entrada:</strong> Sem entrada</p>}
              <p><strong>Parcela:</strong> {money(discountedInstallment)} <span aria-hidden="true">|</span> <strong>Venc.:</strong> {formatDate(contract?.first_installment_due_on ?? null)} <span aria-hidden="true">|</span> <strong>Recorrência:</strong> Mensal</p>
              <p><strong>Forma de pagamento:</strong> {bundlePaymentMethodLabel[selectedSubscriptionOffer.payment_method] ?? selectedSubscriptionOffer.payment_method}</p>
            </div>
          </div>
        </>;
      })() : selectedSubscriptionOffer.plan_version && <p>{selectedSubscriptionOffer.plan_version.billing_period === "BIWEEKLY" ? "Quinzenal" : "Mensal"} · {selectedSubscriptionOffer.plan_version.duration_months} mês(es) · {selectedSubscriptionOffer.plan_version.sessions_per_cycle} sessão(ões) por ciclo · pagamento: {paymentMethodLabel[selectedSubscriptionOffer.plan_version.payment_method] ?? selectedSubscriptionOffer.plan_version.payment_method}</p>}
      {selectedSubscriptionOffer.contract_body_snapshot && <button className={styles.subscriptionContractTrigger} type="button" onClick={() => setOfferContractOpenFor(selectedSubscriptionOffer.id)}>Contrato <span aria-hidden="true">⌄</span></button>}
      {message && <p role="alert">{message}</p>}
      <div className={styles.planActions}>
        <button className={styles.subscriptionAction} type="button" disabled={acceptingSubscriptionOffer || (selectedSubscriptionOffer.plan_version?.model === "SESSION_BUNDLE_V1" && !selectedBundleOfferContract)} onClick={() => void acceptSubscriptionOffer(selectedSubscriptionOffer.id)}>{acceptingSubscriptionOffer ? "Assinando…" : "Assinar contrato"}</button>
        <button className={styles.subscriptionSecondary} type="button" disabled={acceptingSubscriptionOffer} onClick={() => void declineSubscriptionOffer(selectedSubscriptionOffer.id)}>Recusar</button>
      </div>
      {offerContractOpenFor === selectedSubscriptionOffer.id && selectedSubscriptionOffer.contract_body_snapshot && <div className={styles.subscriptionContractLayer}>
        <button className={styles.subscriptionContractBackdrop} type="button" aria-label="Fechar contrato" onClick={() => setOfferContractOpenFor(null)} />
        <section className={styles.subscriptionContractDialog} role="dialog" aria-modal="true" aria-labelledby="subscription-contract-title" aria-describedby="subscription-contract-body">
          <header className={styles.subscriptionContractHeader}>
            <h2 id="subscription-contract-title">Contrato</h2>
            <button className={styles.subscriptionContractClose} type="button" aria-label="Fechar contrato" onClick={() => setOfferContractOpenFor(null)}>×</button>
          </header>
          <div className={styles.subscriptionContractBody} id="subscription-contract-body"><p>{selectedSubscriptionOffer.contract_body_snapshot}</p></div>
          <footer className={`${styles.planActions} ${styles.subscriptionContractActions}`}>
            <button className={styles.subscriptionAction} type="button" disabled={acceptingSubscriptionOffer || (selectedSubscriptionOffer.plan_version?.model === "SESSION_BUNDLE_V1" && !selectedBundleOfferContract)} onClick={() => void acceptSubscriptionOffer(selectedSubscriptionOffer.id)}>{acceptingSubscriptionOffer ? "Assinando…" : "Assinar contrato"}</button>
            <button className={styles.subscriptionSecondary} type="button" disabled={acceptingSubscriptionOffer} onClick={() => void declineSubscriptionOffer(selectedSubscriptionOffer.id)}>Recusar</button>
          </footer>
        </section>
      </div>}
    </article>
  </section>;

  if (view === "project-offer" && selectedProjectOffer) return <section className={styles.subscriptionStack}>
    <header><Link href={route("/cliente/assinaturas")} className={styles.subscriptionBack}>← Assinaturas</Link><span className={styles.planKind}>Plano enviado pelo gestor</span><h1>{selectedProjectOffer.project?.name ?? "Plano"} · {selectedProjectOffer.package?.name ?? "Pacote"}</h1><p>{selectedProjectOffer.project?.description ?? selectedProjectOffer.package?.description ?? "Confira os detalhes antes de aceitar ou recusar."}</p></header>
    <article className={styles.subscriptionCard}><p>{selectedProjectOffer.package?.description ?? "Pacote selecionado pelo gestor."}</p><small>{selectedProjectOffer.package?.sessions_count ?? 0} sessão(ões)</small><strong>{money(selectedProjectOffer.contracted_cents)}</strong><div className={styles.planActions}><button className={styles.subscriptionAction} type="button" onClick={() => void acceptProjectOffer(selectedProjectOffer)}>Confirmar assinatura</button><button className={styles.subscriptionSecondary} type="button" onClick={() => void declineProjectOffer(selectedProjectOffer)}>Recusar contrato</button></div></article>
  </section>;

  if (view === "my-plan" && !selectedCustomerSubscription && !selectedCustomerProject) return <section className={styles.subscriptionStack}><Link href={route("/cliente/assinaturas")} className={styles.subscriptionBack}>← Voltar</Link><h1>{message ? "Carregando plano…" : "Plano indisponível"}</h1>{message && <p>{message}</p>}</section>;

  if (view === "my-plan" && selectedCustomerProject) {
    const engagement = selectedCustomerProject;
    const request = projectCancellationRequestByEngagement.get(engagement.id);
    const installments = projectInstallments.filter((item) => item.engagement_id === engagement.id).sort((a, b) => a.installment_number - b.installment_number);
    const sessions = projectSessions.filter((item) => item.engagement_id === engagement.id).sort((a, b) => a.session_number - b.session_number);
    const canBook = (session: ProjectSession) => session.status === "OPEN" && (engagement.status === "ACTIVE"
      ? request?.status !== "PENDING" || Boolean(request.last_session_id && session.session_number <= (sessions.find((item) => item.id === request.last_session_id)?.session_number ?? 0))
      : request?.status === "CONFIRMED" && request.last_session_id === session.id);
    return <section className={styles.subscriptionStack}>
      <header><Link href={route("/cliente/assinaturas")} className={styles.subscriptionBack}>← Voltar</Link><span className={styles.planKind}>Plano de projeto</span><h1>{engagement.project?.name ?? "Projeto"} · {engagement.package?.name ?? "Pacote"}</h1><p>{engagement.project?.description ?? engagement.package?.description ?? "Detalhes do plano contratado."}</p></header>
      <article className={styles.subscriptionCard}>
        {request?.status === "PENDING" && <span className={styles.planStatus}>Cancelamento pendente · aguarde confirmação</span>}
        {(engagement.status === "CANCELED" || engagement.status === "CANCELED_BY_ORGANIZATION") && <span className={styles.planStatus}>Aguardando regular pendências</span>}
        <p>{engagement.package?.description ?? "Pacote selecionado para este projeto."}</p><strong>{money(engagement.contracted_cents)}</strong>
        <small>{engagement.status === "PROPOSAL" ? "Solicitação enviada · aguardando retorno" : engagement.status === "CANCELED_BY_ORGANIZATION" ? "Contrato cancelado pelo estabelecimento" : engagement.status === "CANCELED" ? "Contrato cancelado" : engagement.status === "COMPLETED" ? "Plano concluído" : "Plano ativo"} · {engagement.package?.sessions_count ?? sessions.length} sessão(ões)</small>
        <div className={styles.subscriptionStack}><h2>Parcelas</h2>{installments.length ? installments.map((installment) => <div className={styles.subscriptionCycle} key={installment.id}><p><strong>{installment.installment_number === 0 ? "Entrada" : `Parcela ${installment.installment_number}`}</strong> · venc. {formatDate(installment.due_on)}</p><strong>{money(installment.amount_cents)}</strong><small>{installment.status === "PAID" ? `Pago${installment.paid_at ? ` em ${formatDate(installment.paid_at.slice(0, 10))}` : ""}` : installment.status === "CANCELED" ? "Cobrança encerrada" : installment.due_on < new Date().toISOString().slice(0, 10) ? "Em atraso · em aberto" : "Em aberto"}</small></div>) : <p>Sem parcelas cadastradas.</p>}</div>
        <div className={styles.subscriptionStack}><h2>Sessões do plano</h2>{sessions.length ? sessions.map((session) => <div className={styles.subscriptionCycle} key={session.id}><p><strong>Sessão {session.session_number}</strong> · {projectSessionLabel(session)}{session.appointment?.service_period ? ` · ${sessionDate(session.appointment.service_period)}` : ""}</p>{canBook(session) && <button className={styles.subscriptionAction} type="button" onClick={() => void openProjectBooking(session)}>Agendar sessão</button>}</div>) : <p>As sessões serão liberadas após a confirmação do contrato.</p>}</div>
        <div className={styles.planActions}>
          {engagement.status === "ACTIVE" && request?.status !== "PENDING" && <button className={styles.subscriptionSecondary} type="button" onClick={() => setProjectCancellationDraft({ engagementId: engagement.id, reason: "", observations: "", lastSessionId: "" })}>Solicitar cancelamento</button>}
          {request?.status === "PENDING" && <span className={styles.planStatus}>Solicitação aguardando confirmação do estabelecimento</span>}
        </div>
      </article>
      {projectCancellationDraft && projectCancellationDraft.engagementId === engagement.id && <div className={styles.modalLayer} role="presentation"><button className={styles.backdrop} type="button" aria-label="Fechar solicitação de cancelamento" onClick={() => setProjectCancellationDraft(null)} /><form className={styles.modal} role="dialog" aria-modal="true" aria-labelledby="project-cancellation-title" onSubmit={(event) => void requestProjectCancellation(event)}>
        <h2 id="project-cancellation-title">Solicitar cancelamento</h2><p>O cancelamento será concluído após o estabelecimento confirmar o contrato.</p>
        <label>Motivo do cancelamento<select required value={projectCancellationDraft.reason} onChange={(event) => setProjectCancellationDraft((current) => current ? { ...current, reason: event.target.value } : current)}><option value="">Selecione</option><option value="FINANCIAL_DIFFICULTY">Dificuldade Financeira</option><option value="LACK_OF_TIME">Falta de tempo</option><option value="ADDRESS_CHANGE">Mudança de endereço</option><option value="OTHER">Outros</option></select></label>
        {projectCancellationDraft.reason === "OTHER" && <label>Observações<textarea required maxLength={2000} value={projectCancellationDraft.observations} onChange={(event) => setProjectCancellationDraft((current) => current ? { ...current, observations: event.target.value } : current)} /></label>}
        <label>Última sessão que pretende comparecer<select value={projectCancellationDraft.lastSessionId} onChange={(event) => setProjectCancellationDraft((current) => current ? { ...current, lastSessionId: event.target.value } : current)}><option value="">Nenhuma sessão adicional</option>{sessions.filter((session) => session.status === "OPEN" || session.status === "BOOKED").map((session) => <option key={session.id} value={session.id}>Sessão {session.session_number} · {projectSessionLabel(session)}</option>)}</select></label>
        <footer><button className={styles.subscriptionSecondary} type="button" onClick={() => setProjectCancellationDraft(null)}>Cancelar</button><button className={styles.subscriptionAction} type="submit">Enviar solicitação</button></footer>
      </form></div>}
      {projectBookingDraft && projectBookingDraft.session.engagement_id === engagement.id && <div className={styles.modalLayer} role="presentation"><button className={styles.backdrop} type="button" aria-label="Fechar agendamento" onClick={() => setProjectBookingDraft(null)} /><form className={styles.modal} role="dialog" aria-modal="true" aria-labelledby="project-booking-title" onSubmit={(event) => void bookProjectSession(event)}>
        <h2 id="project-booking-title">Agendar sessão {projectBookingDraft.session.session_number}</h2>
        <label>Profissional<select value={projectBookingDraft.barberId} onChange={(event) => setProjectBookingDraft((current) => current ? { ...current, barberId: event.target.value, environmentId: "", environments: [] } : current)}>{[...new Map(projectBookingDraft.options.map((option) => [option.barber_id, option.barber_name])).entries()].map(([id, name]) => <option key={id} value={id}>{name}</option>)}</select></label>
        <label>Serviço<select value={projectBookingDraft.serviceId} onChange={(event) => setProjectBookingDraft((current) => current ? { ...current, serviceId: event.target.value, environmentId: "", environments: [] } : current)}>{projectBookingDraft.options.filter((option) => option.barber_id === projectBookingDraft.barberId).map((option) => <option key={option.service_id} value={option.service_id}>{option.service_name}</option>)}</select></label>
        <label>Data<input required type="date" min={context ? localToday(context.organization.timezone) : undefined} value={projectBookingDraft.date} onChange={(event) => setProjectBookingDraft((current) => current ? { ...current, date: event.target.value, environmentId: "", environments: [] } : current)} /></label>
        <label>Horário<input required type="time" step={900} value={projectBookingDraft.time} onChange={(event) => setProjectBookingDraft((current) => current ? { ...current, time: event.target.value, environmentId: "", environments: [] } : current)} /></label>
        <button className={styles.subscriptionSecondary} type="button" disabled={projectBookingDraft.loading} onClick={() => void refreshProjectBookingEnvironments(projectBookingDraft)}>{projectBookingDraft.loading ? "Consultando…" : "Ver horários disponíveis"}</button>
        <label>Ambiente<select required value={projectBookingDraft.environmentId} onChange={(event) => setProjectBookingDraft((current) => current ? { ...current, environmentId: event.target.value } : current)}><option value="">{projectBookingDraft.environments.length ? "Selecione" : "Consulte os horários"}</option>{projectBookingDraft.environments.map((environment) => <option key={environment.id} value={environment.id}>{environment.name}</option>)}</select></label>
        <footer><button className={styles.subscriptionSecondary} type="button" onClick={() => setProjectBookingDraft(null)}>Cancelar</button><button className={styles.subscriptionAction} type="submit" disabled={!projectBookingDraft.environmentId || projectBookingDraft.loading}>Agendar sessão</button></footer>
      </form></div>}
    </section>;
  }

  if (view === "my-plan" && selectedCustomerSubscription) {
    const row = selectedCustomerSubscription;
    const isBundle = row.plan_version?.model === "SESSION_BUNDLE_V1";
    const contract = bundleContracts.find((item) => item.subscription_id === row.id);
    const today = context ? localToday(context.organization.timezone) : new Date().toISOString().slice(0, 10);
    const timezone = context?.organization.timezone ?? "UTC";
    const bundleRows = bundleSessions.filter((item) => item.subscription_id === row.id).sort((a, b) => a.session_number - b.session_number);
    const installmentRows = bundleInstallments.filter((item) => item.subscription_id === row.id).sort((a, b) => a.installment_number - b.installment_number);
    const cycleRows = cycles.filter((item) => item.subscription_id === row.id).sort((a, b) => a.cycle_number - b.cycle_number);
    const fixedSlots = bundleFixedSlots.filter((item) => item.subscription_id === row.id).sort((a, b) => a.slot_number - b.slot_number);
    const acceptedActivePlan = row.status === "ACTIVE" && Boolean(row.contract_accepted_at);
    const bundleOverdue = installmentRows.some((item) => item.status === "OVERDUE" || (item.status === "OPEN" && item.due_on < today));
    const legacyOverdue = cycleRows.some((item) => item.status === "OVERDUE" || (item.status === "OPEN" && item.due_on < today));
    const weekdays = ["domingo", "segunda-feira", "terça-feira", "quarta-feira", "quinta-feira", "sexta-feira", "sábado"];
    const activeSession = bundleRescheduleDraft ? bundleRows.find((item) => item.id === bundleRescheduleDraft.sessionId) : null;
    const activeLegacySession = legacyRescheduleDraft ? cycleRows.flatMap((cycle) => cycle.sessions).find((item) => item.id === legacyRescheduleDraft.sessionId) : null;
    const eligibleBarbers = context?.barbers.filter((barber) => barber.subscription_plan_ids?.includes(row.plan_id)
      && barber.service_ids?.includes(contract?.service_id ?? "")) ?? [];
    const sourceSchedule = activeSession?.rescheduled_from ?? activeSession?.scheduled_for ?? null;
    const sourceDate = sourceSchedule ? localDateKey(new Date(sourceSchedule), timezone) : today;
    const rescheduleMin = today > shiftDateKey(sourceDate, -14) ? today : shiftDateKey(sourceDate, -14);
    const rescheduleMax = shiftDateKey(sourceDate, 14);
    const legacySource = activeLegacySession?.rescheduled_from ?? appointmentStart(activeLegacySession?.appointment?.service_period)?.toISOString() ?? today;
    const legacySourceDate = legacySource === today ? today : localDateKey(new Date(legacySource), timezone);
    const legacyRescheduleMin = today > shiftDateKey(legacySourceDate, -14) ? today : shiftDateKey(legacySourceDate, -14);
    const legacyRescheduleMax = shiftDateKey(legacySourceDate, 14);
    const legacyServiceIds = legacyRescheduleDraft?.selections.filter((selection) => selection.type === "SERVICE").map((selection) => selection.type === "SERVICE" ? selection.service_id : "") ?? [];
    const legacyEligibleBarbers = context?.barbers.filter((barber) => barber.subscription_plan_ids?.includes(row.plan_id)
      && legacyServiceIds.length > 0 && legacyServiceIds.every((serviceId) => barber.service_ids?.includes(serviceId))) ?? [];
    const financeRows = isBundle
      ? installmentRows.map((item) => {
          const status = installmentStatus(item.status, item.due_on, today);
          return { id: item.id, number: item.kind === "ENTRY" ? "Entrada" : String(item.installment_number).padStart(2, "0"), value: item.amount_cents, due: item.due_on, paid: item.paid_at ? item.paid_at.slice(0, 10) : null, status };
        })
      : cycleRows.map((item) => ({
          id: item.id,
          number: String(item.cycle_number).padStart(2, "0"),
          value: item.amount_cents,
          due: item.due_on,
          paid: item.paid_at ? item.paid_at.slice(0, 10) : null,
          status: installmentStatus(item.status, item.due_on, today),
        }));
    const agendaRows = isBundle
      ? bundleRows.map((session) => ({
          id: session.id,
          number: session.session_number,
          date: session.scheduled_for ?? appointmentStart(session.appointment?.service_period)?.toISOString() ?? null,
          professional: context?.barbers.find((barber) => barber.id === (session.appointment?.barber_id ?? session.barber_id))?.name
            ?? "—",
          status: sessionStatusLabel(session.status),
          tone: sessionTone(session.status),
          scheduled: session.status === "SCHEDULED",
          bookable: acceptedActivePlan && session.status === "AVAILABLE"
            && contract?.scheduling_mode === "FREE"
            && session.release_on <= today
            && Boolean(contract.first_session_date && contract.first_session_date <= today)
            && !bundleOverdue,
          model: "bundle" as const,
        }))
      : cycleRows.flatMap((cycle) => cycle.sessions.map((session) => ({
          id: session.id,
          number: session.session_number,
          date: appointmentStart(session.appointment?.service_period)?.toISOString() ?? null,
          professional: context?.barbers.find((barber) => barber.id === session.appointment?.barber_id)?.name
            ?? "—",
          status: session.appointment?.status === "CONFIRMED"
            ? session.appointment.whatsapp_response_status === "CONFIRMED_BY_WHATSAPP" ? "Confirmada" : "Agendada"
            : sessionStatusLabel(session.status),
          tone: session.appointment?.status === "CONFIRMED" ? "#2872ad" : sessionTone(session.status),
          scheduled: session.status === "SCHEDULED",
          bookable: acceptedActivePlan && session.status === "AVAILABLE" && !legacyOverdue,
          model: "legacy" as const,
        })));

    return <section className={styles.subscriptionStack}>
      <header className={styles.activePlanHeader}>
        <Link href={route("/cliente/assinaturas")} className={styles.subscriptionBack}>← Voltar</Link>
        <h1 className={styles.activePlanTitle}>{row.plan?.name ?? "Plano ativo"}</h1>
      </header>
      <article className={`${styles.subscriptionCard} ${styles.activePlanCard}`}>
        {subscriptionHasPendingCancellation(row.id) && <span className={styles.planStatus}>Cancelamento pendente</span>}
        {row.status === "CANCELED" && <span className={styles.planStatus}>Aguardando regular pendências</span>}
        <p className={styles.activePlanDescription}>{row.plan?.description ?? "Sem descrição cadastrada."}</p>
        {isBundle && contract?.scheduling_mode === "FIXED" && <section className={styles.activePlanWeeklyAgenda}>
          <h2>Agenda</h2>
          {fixedSlots.length ? fixedSlots.map((slot) => <p key={slot.id}>Sessão {slot.slot_number}: {weekdays[slot.weekday]} às {slot.local_time.slice(0, 5)} · {slot.barber_name_snapshot} · {slot.environment_name_snapshot}</p>) : <p>Agenda semanal não informada.</p>}
        </section>}
        <div className={styles.activePlanTabs} role="tablist" aria-label="Detalhes do plano">
          {(["financeiro", "agenda", "contrato"] as const).map((tab) => <button key={tab} type="button" role="tab" aria-selected={activePlanTab === tab} className={activePlanTab === tab ? styles.activePlanTabSelected : ""} onClick={() => setActivePlanTab(tab)}>
            {tab === "financeiro" ? <CircleDollarSign size={17} aria-hidden="true" /> : tab === "agenda" ? <CalendarDays size={17} aria-hidden="true" /> : <FileText size={17} aria-hidden="true" />}
            {tab === "financeiro" ? "Financeiro" : tab === "agenda" ? "Agenda" : "Contrato"}
          </button>)}
        </div>
        {!subscriptionDetailsLoaded && <p role="status" className={styles.subscriptionHint}>{message || "Carregando dados do plano…"}</p>}
        <section className={styles.activePlanTabPanel} role="tabpanel">
          {subscriptionDetailsLoaded && activePlanTab === "financeiro" && <div className={styles.activePlanTableWrap}>
            <table className={styles.activePlanTable}>
              <thead><tr><th>N. Parcela</th><th>Valor</th><th>Vencimento</th><th>Data Pgto</th><th>Status</th><th>Ações</th></tr></thead>
              <tbody>{financeRows.map((item) => <tr key={item.id}>
                <td>{item.number}</td><td>{money(item.value)}</td><td>{formatDate(item.due)}</td><td>{formatDate(item.paid)}</td>
                <td><span className={`${styles.activePlanStatus} ${styles[`activePlanStatus${item.status.tone[0].toUpperCase()}${item.status.tone.slice(1)}`]}`}>{item.status.label}</span></td>
                <td><div className={styles.activePlanActions}>
                  <button type="button" disabled aria-label={`Pagar parcela ${item.number}`} title="Pagamento online será disponibilizado futuramente"><CircleDollarSign size={17} aria-hidden="true" /></button>
                  <button type="button" disabled aria-label={`Imprimir recibo da parcela ${item.number}`} title="Emissão de recibo será disponibilizada futuramente"><ReceiptText size={17} aria-hidden="true" /></button>
                </div></td>
              </tr>)}</tbody>
            </table>
            {!financeRows.length && <p className={styles.subscriptionHint}>Nenhuma parcela cadastrada.</p>}
          </div>}
          {subscriptionDetailsLoaded && activePlanTab === "agenda" && <div className={styles.activePlanTableWrap}>
            <table className={styles.activePlanTable}>
              <thead><tr><th>Sessão</th><th>Data/hora</th><th>Profissional</th><th>Status</th><th>Ações</th></tr></thead>
              <tbody>{agendaRows.map((item) => <tr key={item.id}>
                <td>{String(item.number).padStart(2, "0")}</td><td>{formatDateTime(item.date, timezone)}</td><td>{item.professional}</td>
                <td><span className={styles.activePlanStatus} style={{ color: item.tone, background: `${item.tone}18` }}>{item.status}</span></td>
                <td><div className={styles.activePlanActions}>
                  {item.bookable && <Link className={styles.activePlanIconLink} href={(() => {
                    const query = new URLSearchParams(item.model === "bundle"
                      ? { subscriptionBundleSession: item.id }
                      : { subscriptionSession: item.id });
                    if (context?.organization.slug) query.set("barbearia", context.organization.slug);
                    return `/cliente/agendar?${query.toString()}`;
                  })()} aria-label={`Agendar sessão ${item.number}`} title="Agendar sessão"><CalendarPlus size={17} aria-hidden="true" /></Link>}
                  {item.scheduled && acceptedActivePlan && <>
                    <button type="button" aria-label={`Cancelar sessão ${item.number}`} title="Cancelar sessão" onClick={() => { setMessage(""); setSessionCancellationDraft({ sessionId: item.id, model: item.model, reason: "" }); }}><XCircle size={17} aria-hidden="true" /></button>
                    {item.model === "bundle" ? <button type="button" aria-label={`Reagendar sessão ${item.number}`} title="Reagendar sessão" onClick={() => {
                      const session = bundleRows.find((candidate) => candidate.id === item.id);
                      if (session) { setMessage(""); void openBundleReschedule(session, row); }
                    }}><CalendarClock size={17} aria-hidden="true" /></button> : row.plan_version?.scheduling_mode === "FIXED" ? <button type="button" aria-label={`Reagendar sessão ${item.number}`} title="Reagendar sessão" onClick={() => {
                      const session = cycleRows.flatMap((cycle) => cycle.sessions).find((candidate) => candidate.id === item.id);
                      if (session) { setMessage(""); void openLegacyReschedule(session, row); }
                    }}><CalendarClock size={17} aria-hidden="true" /></button> : <button type="button" disabled aria-label={`Reagendar sessão ${item.number}`} title="Este plano não permite reagendamento pelo cliente"><CalendarClock size={17} aria-hidden="true" /></button>}
                  </>}
                </div></td>
              </tr>)}</tbody>
            </table>
            {!agendaRows.length && <p className={styles.subscriptionHint}>Nenhuma sessão cadastrada.</p>}
          </div>}
          {subscriptionDetailsLoaded && activePlanTab === "contrato" && <div className={styles.activePlanContract}><pre>{row.contract_body_snapshot ?? contractBody ?? "Contrato não disponível."}</pre></div>}
        </section>
      </article>
      {sessionCancellationDraft && <div className={styles.modalLayer} role="presentation">
        <button className={styles.backdrop} type="button" aria-label="Fechar cancelamento" onClick={() => setSessionCancellationDraft(null)} />
        <form className={styles.modal} role="dialog" aria-modal="true" aria-labelledby="session-cancellation-title" onSubmit={(event) => void submitSessionCancellation(event)}>
          <h2 id="session-cancellation-title">Cancelar sessão</h2>
          <p>Informe o motivo. O sistema atualizará a agenda e enviará os avisos de cancelamento.</p>
          {message && <p role="alert">{message}</p>}
          <label>Motivo do cancelamento<textarea required maxLength={500} value={sessionCancellationDraft.reason} onChange={(event) => setSessionCancellationDraft((current) => current ? { ...current, reason: event.target.value } : current)} /></label>
          <footer><button className={styles.subscriptionSecondary} type="button" onClick={() => setSessionCancellationDraft(null)}>Voltar</button><button className={styles.subscriptionAction} type="submit" disabled={sessionActionBusy}>{sessionActionBusy ? "Cancelando…" : "Confirmar cancelamento"}</button></footer>
        </form>
      </div>}
      {bundleRescheduleDraft && <div className={styles.modalLayer} role="presentation">
        <button className={styles.backdrop} type="button" aria-label="Fechar reagendamento" onClick={() => setBundleRescheduleDraft(null)} />
        <form className={styles.modal} role="dialog" aria-modal="true" aria-labelledby="bundle-reschedule-title" onSubmit={(event) => void submitBundleReschedule(event)}>
          <h2 id="bundle-reschedule-title">Reagendar sessão {String(activeSession?.session_number ?? "")}</h2>
          {message && <p role="alert">{message}</p>}
          <label>Motivo do reagendamento<textarea maxLength={500} value={bundleRescheduleDraft.observation} onChange={(event) => setBundleRescheduleDraft((current) => current ? { ...current, observation: event.target.value } : current)} placeholder="Opcional" /></label>
          <label>Profissional<select required value={bundleRescheduleDraft.barberId} onChange={(event) => setBundleRescheduleDraft((current) => current ? { ...current, barberId: event.target.value, startsAt: "" } : current)}>
            <option value="">Selecione</option>{eligibleBarbers.map((barber) => <option key={barber.id} value={barber.id}>{barber.name}</option>)}
          </select></label>
          {!eligibleBarbers.length && <p role="alert">Nenhum profissional habilitado para este plano está disponível.</p>}
          <label>Data<input type="date" required min={rescheduleMin} max={rescheduleMax} value={bundleRescheduleDraft.localDate} onChange={(event) => setBundleRescheduleDraft((current) => current ? { ...current, localDate: event.target.value, startsAt: "" } : current)} /></label>
          <label>Horário disponível<select required value={bundleRescheduleDraft.startsAt} disabled={bundleRescheduleDraft.loading || !bundleRescheduleDraft.slots.length} onChange={(event) => setBundleRescheduleDraft((current) => current ? { ...current, startsAt: event.target.value } : current)}>
            <option value="">{bundleRescheduleDraft.loading ? "Consultando horários…" : bundleRescheduleDraft.slots.length ? "Selecione um horário" : "Nenhum horário disponível"}</option>
            {bundleRescheduleDraft.slots.map((slot) => <option key={slot.starts_at} value={slot.starts_at}>{new Intl.DateTimeFormat("pt-BR", { hour: "2-digit", minute: "2-digit", timeZone: timezone }).format(new Date(slot.starts_at))}</option>)}
          </select></label>
          <footer><button className={styles.subscriptionSecondary} type="button" onClick={() => setBundleRescheduleDraft(null)}>Cancelar</button><button className={styles.subscriptionAction} type="submit" disabled={!bundleRescheduleDraft.startsAt || bundleRescheduleDraft.loading || sessionActionBusy}>{sessionActionBusy ? "Reagendando…" : "Confirmar reagendamento"}</button></footer>
        </form>
      </div>}
      {legacyRescheduleDraft && <div className={styles.modalLayer} role="presentation">
        <button className={styles.backdrop} type="button" aria-label="Fechar reagendamento" onClick={() => setLegacyRescheduleDraft(null)} />
        <form className={styles.modal} role="dialog" aria-modal="true" aria-labelledby="legacy-reschedule-title" onSubmit={(event) => void submitLegacyReschedule(event)}>
          <h2 id="legacy-reschedule-title">Reagendar sessão {String(activeLegacySession?.session_number ?? "")}</h2>
          {message && <p role="alert">{message}</p>}
          <label>Profissional<select required value={legacyRescheduleDraft.barberId} onChange={(event) => setLegacyRescheduleDraft((current) => current ? { ...current, barberId: event.target.value, startsAt: "" } : current)}>
            <option value="">Selecione</option>{legacyEligibleBarbers.map((barber) => <option key={barber.id} value={barber.id}>{barber.name}</option>)}
          </select></label>
          {!legacyEligibleBarbers.length && <p role="alert">Nenhum profissional habilitado para este plano está disponível.</p>}
          <label>Data<input type="date" required min={legacyRescheduleMin} max={legacyRescheduleMax} value={legacyRescheduleDraft.localDate} onChange={(event) => setLegacyRescheduleDraft((current) => current ? { ...current, localDate: event.target.value, startsAt: "" } : current)} /></label>
          <label>Horário disponível<select required value={legacyRescheduleDraft.startsAt} disabled={legacyRescheduleDraft.loading || !legacyRescheduleDraft.slots.length} onChange={(event) => setLegacyRescheduleDraft((current) => current ? { ...current, startsAt: event.target.value } : current)}>
            <option value="">{legacyRescheduleDraft.loading ? "Consultando horários…" : legacyRescheduleDraft.slots.length ? "Selecione um horário" : "Nenhum horário disponível"}</option>
            {legacyRescheduleDraft.slots.map((slot) => <option key={slot.starts_at} value={slot.starts_at}>{new Intl.DateTimeFormat("pt-BR", { hour: "2-digit", minute: "2-digit", timeZone: timezone }).format(new Date(slot.starts_at))}</option>)}
          </select></label>
          <footer><button className={styles.subscriptionSecondary} type="button" onClick={() => setLegacyRescheduleDraft(null)}>Cancelar</button><button className={styles.subscriptionAction} type="submit" disabled={!legacyRescheduleDraft.startsAt || legacyRescheduleDraft.loading || sessionActionBusy}>{sessionActionBusy ? "Reagendando…" : "Confirmar reagendamento"}</button></footer>
        </form>
      </div>}
    </section>;
  }

  if (view === "subscription" || view === "project" || view === "subscription-offer" || view === "project-offer") return <section className={styles.subscriptionStack}><Link href={route(view === "subscription" || view === "project" ? "/cliente/assinaturas/novo-plano" : "/cliente/assinaturas")} className={styles.subscriptionBack}>← Voltar</Link><h1>Plano indisponível</h1><p>Este plano não está mais disponível neste estabelecimento.</p></section>;

  return (
    <section className={styles.subscriptionStack}>
      <header>
        {view !== "my-plans" && <Link href={route("/cliente/assinaturas")} className={styles.subscriptionBack}>← Minhas Assinaturas</Link>}
        <h1>{view === "my-plan" ? selectedCustomerSubscription?.plan?.name ?? "Detalhes do plano" : view === "closed-plans" ? "Planos Encerrados" : "Minhas Assinaturas"}</h1>
      </header>
      {message && <p>{message}</p>}
      {view === "my-plans" && requestedOffers.length > 0 && <div className={styles.subscriptionStack}>
        <h2>Planos aguardando sua decisão</h2>
        {requestedOffers.map((row) => <Link className={styles.subscriptionCard} key={row.id} href={route(`/cliente/assinaturas/ofertas/assinatura/${row.id}`)}>
          <span className={`${styles.planStatus} ${styles.pendingOfferPulse}`}>Aguardando aceite</span><h3>{row.plan?.name ?? "Plano"}</h3><p>Confirme os detalhes e realize o aceite do seu plano.</p>
          <span className={styles.offerViewButton}>Clique para ver</span>
        </Link>)}
      </div>}
      {view === "closed-plans" && <div className={styles.subscriptionStack}>
        <h2>Planos Encerrados</h2>
        {rows.filter((row) => row.status === "DECLINED").map((row) => <article className={styles.subscriptionCard} key={`declined-${row.id}`}><span className={styles.planStatus}>Recusado</span><h3>{row.plan?.name ?? "Plano"}</h3><p>Oferta recusada e arquivada.</p></article>)}
        {rows.filter((row) => row.status === "CANCELED" || cancellationArchiveReady(row)).map((row) => row.status === "CANCELED" && !cancellationArchiveReady(row) ? <Link className={`${styles.subscriptionCard} ${styles.subscriptionCardLink}`} href={route(`/cliente/assinaturas/meus-planos/${row.id}`)} key={`closed-subscription-${row.id}`}>
          <span className={styles.planStatus}>Cancelada · finalizando pendências</span><h3>{row.plan?.name ?? "Plano"}</h3><p>{row.plan?.description ?? "Assinatura cancelada."}</p><strong>{row.plan_version ? money(bundleContracts.find((contract) => contract.subscription_id === row.id)?.total_price_cents ?? row.plan_version.price_cents) : "—"}</strong><small className={styles.subscriptionMeta}>{row.plan_version?.billing_period === "BIWEEKLY" ? "Quinzenal" : "Mensal"} · venc. {formatDate(row.first_due_date)} · pagamento: {paymentMethodLabel[row.payment_method] ?? row.payment_method} · {subscriptionStatusLabel[row.status] ?? row.status}</small><span>Ver detalhes do plano</span>
        </Link> : <article className={styles.subscriptionCard} key={`closed-subscription-${row.id}`}><span className={styles.planStatus}>{row.status === "CANCELED" ? "Cancelado" : "Encerrado"}</span><h3>{row.plan?.name ?? "Plano"}</h3><p>{row.plan?.description ?? "Assinatura encerrada sem pendências."}</p><strong>{row.plan_version ? money(bundleContracts.find((contract) => contract.subscription_id === row.id)?.total_price_cents ?? row.plan_version.price_cents) : "—"}</strong></article>)}
        {!rows.some((row) => row.status === "DECLINED" || row.status === "CANCELED" || cancellationArchiveReady(row)) && <p>Nenhum plano encerrado disponível.</p>}
      </div>}
      {(view === "my-plan" ? rows.filter((row) => row.id === itemId && row.status !== "DECLINED" && !isPendingManagerOffer(row) && !cancellationArchiveReady(row)) : view === "closed-plans" ? [] : rows.filter((row) => row.status !== "DECLINED" && row.status !== "CANCELED" && !cancellationArchiveReady(row) && !isPendingManagerOffer(row))).map((row) => view === "my-plan" && row.plan_version?.model === "SESSION_BUNDLE_V1" ? (() => {
        const contract = bundleContracts.find((item) => item.subscription_id === row.id);
        const sessions = bundleSessions.filter((item) => item.subscription_id === row.id).sort((a, b) => a.session_number - b.session_number);
        const installments = bundleInstallments.filter((item) => item.subscription_id === row.id).sort((a, b) => a.installment_number - b.installment_number);
        const fixedSlots = bundleFixedSlots.filter((item) => item.subscription_id === row.id).sort((a, b) => a.slot_number - b.slot_number);
        const today = context ? localToday(context.organization.timezone) : new Date().toISOString().slice(0, 10);
        const overdue = installments.some((item) => item.status === "OVERDUE" || (item.status === "OPEN" && item.due_on < today));
        const weekdays = ["domingo", "segunda-feira", "terça-feira", "quarta-feira", "quinta-feira", "sexta-feira", "sábado"];
        return <article className={styles.subscriptionCard} key={row.id}>
          {subscriptionHasPendingCancellation(row.id) && <span className={styles.planStatus}>Cancelamento pendente</span>}
          <h2>{row.plan?.name ?? "Plano"}</h2><p>{row.plan?.description ?? "Plano de sessões."}</p>
          <strong>{money(Number(contract?.total_price_cents ?? row.plan_version?.price_cents ?? 0))}</strong>
          <small className={styles.subscriptionMeta}>{subscriptionStatusLabel[row.status] ?? row.status} · {contract?.total_sessions ?? row.plan_version.bundle_total_sessions} sessões · {contract?.scheduling_mode === "FIXED"
            ? `${contract.sessions_per_week}/semana`
            : contract?.sessions_per_month != null
              ? `${contract.sessions_per_month}/mês`
              : `${contract?.sessions_per_week ?? row.plan_version.bundle_sessions_per_week}/semana`
          } · {contract?.session_duration_minutes ?? row.plan_version.bundle_session_duration_minutes} min · {paymentMethodLabel[row.payment_method] ?? row.payment_method}</small>
          {contract && <>
            <p>Serviço: {context?.services.find((service) => service.id === contract.service_id)?.name ?? "Serviço do plano"} · {contract.scheduling_mode === "FIXED" ? "Agendamento fixo" : "Agendamento livre"}</p>
            <p>{money(contract.price_per_session_cents)} por sessão · entrada {money(contract.entry_cents)} · {contract.installment_count} parcela(s) com desconto configurado</p>
            {contract.scheduling_mode === "FIXED" && <div className={styles.subscriptionStack}><strong>Agenda semanal</strong>{fixedSlots.map((slot) => <small key={slot.id}>Sessão semanal {slot.slot_number}: {slot.barber_name_snapshot} · {slot.environment_name_snapshot} · {weekdays[slot.weekday]} às {slot.local_time.slice(0, 5)}</small>)}</div>}
          </>}
          <div className={styles.subscriptionCycle}>
            <strong>Cobranças</strong>
            {installments.map((installment) => {
              const late = installment.status === "OVERDUE" || (installment.status === "OPEN" && installment.due_on < today);
              const label = installment.kind === "ENTRY" ? "Entrada" : `Parcela ${installment.installment_number}`;
              const status = installment.status === "PAID" ? "Pago" : installment.status === "CANCELED" ? "Cancelada" : late ? "Em atraso" : "Em aberto";
              return <small key={installment.id}>{label}: {money(installment.amount_cents)} · venc. {formatDate(installment.due_on)} · {status}{installment.paid_at ? ` em ${new Intl.DateTimeFormat("pt-BR").format(new Date(installment.paid_at))}` : ""}</small>;
            })}
          </div>
          {overdue && <p className={styles.subscriptionHint} role="status">Há parcela vencida. Novos agendamentos ficam bloqueados até a regularização.</p>}
          <div className={styles.subscriptionCycle}>
            <strong>Sessões ({sessions.length}/{contract?.total_sessions ?? row.plan_version.bundle_total_sessions})</strong>
            <div style={{ display: "flex", flexWrap: "wrap", gap: ".5rem" }}>
              {sessions.map((session) => {
                const title = `Sessão ${String(session.session_number).padStart(2, "0")}`;
                const released = Boolean(contract?.first_session_date && session.release_on <= today && contract.first_session_date <= today);
                if (session.status === "AVAILABLE" && released && !overdue && contract?.scheduling_mode === "FREE") {
                  const query = new URLSearchParams({ subscriptionBundleSession: session.id });
                  if (context?.organization.slug) query.set("barbearia", context.organization.slug);
                  return <Link className={styles.subscriptionAction} key={session.id} href={`/cliente/agendar?${query.toString()}`} aria-label={`Agendar ${title}`}>{title} · Agendar</Link>;
                }
                if (session.status === "SCHEDULED") return <button className={styles.subscriptionSecondary} type="button" key={session.id} onClick={() => setSessionCancellationDraft({ sessionId: session.id, model: "bundle", reason: "" })}>{title} · {session.scheduled_for ? new Intl.DateTimeFormat("pt-BR", { dateStyle: "short", timeStyle: "short", timeZone: context?.organization.timezone }).format(new Date(session.scheduled_for)) : "Agendada"} · Cancelar</button>;
                const label = session.status === "COMPLETED" ? "Concluída" : session.status === "CONSUMED" ? "Consumida" : session.status === "CANCELED" ? "Cancelada" : released ? (overdue ? "Bloqueada por atraso" : "Disponível") : `Libera em ${formatDate(session.release_on)}`;
                return <span key={session.id} className={styles.subscriptionSecondary}>{title} · {label}</span>;
              })}
            </div>
          </div>
          {contract && contract.scheduling_mode === "FREE" && <small className={styles.subscriptionHint}>Sessões liberadas por mês; as não utilizadas acumulam. Limite de {contract.sessions_per_month ?? contract.sessions_per_week} agendamento(s) por {contract.sessions_per_month == null ? "semana" : "mês"}.</small>}
          {row.contract_body_snapshot && <details><summary>Contrato</summary><p>{row.contract_body_snapshot}</p></details>}
        </article>;
      })() : view === "my-plan" ? (
        <article className={styles.subscriptionCard} key={row.id}>
          {subscriptionHasPendingCancellation(row.id) && <span className={styles.planStatus}>Cancelamento pendente</span>}
          {row.status === "CANCELED" && <span className={styles.planStatus}>Aguardando regular pendências</span>}
          <h2>{row.plan?.name ?? "Plano"}</h2>
          <p>{row.plan?.description ?? "Sem descrição"}</p>
          <strong>
            {row.plan_version
              ? new Intl.NumberFormat("pt-BR", {
                  style: "currency",
                  currency: "BRL",
                }).format(row.plan_version.price_cents / 100)
              : "—"}
          </strong>
          <small className={styles.subscriptionMeta}>
            {row.plan_version?.billing_period === "BIWEEKLY"
              ? "Quinzenal"
              : "Mensal"}{" "}
            · venc. {formatDate(row.first_due_date)} · pagamento:{" "}
            {paymentMethodLabel[row.payment_method] ?? row.payment_method} · {subscriptionStatusLabel[row.status] ?? row.status}
          </small>
          <div>
            {cycles
              .filter((cycle) => cycle.subscription_id === row.id)
              .map((cycle) => (
                <div className={styles.subscriptionCycle} key={cycle.id}>
                  <div className={styles.subscriptionCycleHeader}>
                    <strong>
                      {row.plan_version?.billing_period === "BIWEEKLY" ? "Quinzena" : "Mês"} {cycle.cycle_number}
                    </strong>
                    <span>Venc. {formatDate(cycle.due_on)}</span>
                  </div>
                  <div style={{ display: "flex", flexWrap: "wrap", gap: ".5rem" }}>
                    {cycle.sessions.map((session) => {
                      const title = `Sessão ${session.session_number}`;
                      const tone = sessionTone(session.status);
                      if (session.status === "AVAILABLE") {
                        return (
                          <Link
                            key={session.id}
                            className={styles.subscriptionAction}
                            href={`/cliente/agendar?subscriptionSession=${encodeURIComponent(session.id)}`}
                            style={{ color: tone, borderColor: `${tone}66`, background: `${tone}14` }}
                            aria-label={sessionStatusLabel(session.status)}
                          >
                            {title}
                          </Link>
                        );
                      }
                      if (session.status === "SCHEDULED") {
                        return (
                          <button
                            key={session.id}
                            type="button"
                            className={styles.subscriptionSecondary}
                            onClick={() => setSessionCancellationDraft({ sessionId: session.id, model: "legacy", reason: "" })}
                            style={{ color: tone, borderColor: `${tone}66`, background: `${tone}14` }}
                            aria-label={sessionStatusLabel(session.status)}
                          >
                            {title}
                          </button>
                        );
                      }
                      return (
                        <span
                          key={session.id}
                          style={{ display: "inline-flex", alignItems: "center", border: `1px solid ${tone}66`, borderRadius: "999px", padding: ".55rem .75rem", color: tone, background: `${tone}14`, fontWeight: 700 }}
                          aria-label={sessionStatusLabel(session.status)}
                        >
                          {title}
                        </span>
                      );
                    })}
                  </div>
                  {cycle.status === "PAID" && cycle.sessions.every((session) => session.status !== "AVAILABLE") && <small className={styles.subscriptionHint}>Todas as sessões deste ciclo já foram utilizadas ou agendadas.</small>}
                </div>
              ))}
          </div>
          <div className={styles.planActions}>
            {contractBody && <button className={styles.subscriptionSecondary} type="button" onClick={() => window.alert(row.contract_body_snapshot ?? contractBody)}>Acessar contrato</button>}
            {row.plan_version?.model !== "SESSION_BUNDLE_V1" && (row.status === "ACTIVE" || row.status === "PENDING_PAYMENT") && !subscriptionHasPendingCancellation(row.id) && <button className={styles.subscriptionSecondary} type="button" onClick={() => setCancellationDraft({ subscriptionId: row.id, reason: "", observations: "", lastSessionId: "" })}>Solicitar cancelamento</button>}
            {row.plan_version?.model !== "SESSION_BUNDLE_V1" && subscriptionHasPendingCancellation(row.id) && <span className={styles.planStatus} role="status">Cancelamento pendente · aguarde confirmação</span>}
          </div>
        </article>
      ) : (
        <Link className={`${styles.subscriptionCard} ${styles.subscriptionCardLink}`} href={route(`/cliente/assinaturas/meus-planos/${row.id}`)} key={row.id}>
          <h2>{row.plan?.name ?? "Plano"}</h2>
          {(() => {
            const displayStatus = subscriptionDisplayStatusFor(row);
            const statusClass = `subscriptionSummaryStatus${displayStatus[0].toUpperCase()}${displayStatus.slice(1)}`;
            return <span className={`${styles.subscriptionSummaryStatus} ${styles[statusClass]}`}>{subscriptionDisplayStatusLabels[displayStatus]}</span>;
          })()}
          <span className={styles.subscriptionAction}>Ver mais</span>
        </Link>
      ))}
      {view === "my-plans" && !rows.some((row) => row.status !== "DECLINED" && row.status !== "CANCELED" && !cancellationArchiveReady(row) && !isPendingManagerOffer(row)) && requestedOffers.length === 0 && <p>Você ainda não possui planos neste estabelecimento.</p>}
      {view === "my-plans" && <Link className={`${styles.subscriptionCard} ${styles.subscriptionCardLink}`} href={route("/cliente/assinaturas/meus-planos/encerrados")}><h2>Planos Encerrados</h2><span className={styles.subscriptionAction}>Ver planos encerrados</span></Link>}
      {cancellationDraft && (() => {
        const rowCycles = cycles.filter((cycle) => cycle.subscription_id === cancellationDraft.subscriptionId);
        const finalSessions = rowCycles.flatMap((cycle) => cycle.sessions
          .filter((session) => session.status === "AVAILABLE" || session.status === "SCHEDULED")
          .map((session) => ({ ...session, cycleNumber: cycle.cycle_number })));
        return <div className={styles.modalLayer} role="presentation">
          <button className={styles.backdrop} type="button" aria-label="Fechar solicitação de cancelamento" onClick={() => setCancellationDraft(null)} />
          <form className={`${styles.modal} ${styles.modalWide}`} role="dialog" aria-modal="true" aria-labelledby="subscription-cancellation-title" onSubmit={(event) => void requestSubscriptionCancellation(event)}>
            <h2 id="subscription-cancellation-title">Solicitar cancelamento</h2>
            <p>O cancelamento será concluído somente após a confirmação do estabelecimento.</p>
            <label>Motivo do cancelamento<select required value={cancellationDraft.reason} onChange={(event) => setCancellationDraft((draft) => draft ? { ...draft, reason: event.target.value } : draft)}><option value="">Selecione</option><option value="FINANCIAL_DIFFICULTY">Dificuldade Financeira</option><option value="LACK_OF_TIME">Falta de tempo</option><option value="ADDRESS_CHANGE">Mudança de endereço</option><option value="OTHER">Outros</option></select></label>
            {cancellationDraft.reason === "OTHER" && <label>Observações<textarea required maxLength={2000} value={cancellationDraft.observations} onChange={(event) => setCancellationDraft((draft) => draft ? { ...draft, observations: event.target.value } : draft)} /></label>}
            <label>Última sessão que pretende comparecer<select value={cancellationDraft.lastSessionId} onChange={(event) => setCancellationDraft((draft) => draft ? { ...draft, lastSessionId: event.target.value } : draft)}><option value="">Nenhuma sessão adicional</option>{finalSessions.map((session) => <option key={session.id} value={session.id}>Ciclo {session.cycleNumber} · Sessão {session.session_number}</option>)}</select></label>
            <footer><button type="button" className={styles.subscriptionSecondary} onClick={() => setCancellationDraft(null)}>Cancelar</button><button type="submit" className={styles.subscriptionAction} disabled={!cancellationDraft.reason}>Enviar solicitação</button></footer>
          </form>
        </div>;
      })()}
    </section>
  );
}
