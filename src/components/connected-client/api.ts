import type { SupabaseClient } from "@supabase/supabase-js";
import { isMercadoPagoCheckoutUrl, localToday, parsePostgresRange } from "@/components/connected-client/format";
import type {
  AppointmentItem,
  Availability,
  DateAvailability,
  BookingSelection,
  ClientAccount,
  ClientClaimResult,
  ClientLinkResult,
  ClientEntryContext,
  ClientOrganization,
  Customer,
  CustomerDependent,
  CustomerAppointment,
  NextCustomerAppointment,
  FinancialStatus,
  PrivacyRequest,
  PublicBookingContext,
} from "@/components/connected-client/types";
import { parseProductKey } from "@/lib/product-routes";
import { ATELIE_PRO_IDENTITY_FALLBACK, isProductIdentityConfig, LE_GRAS_IDENTITY_FALLBACK, MUSIC_PRO_IDENTITY_FALLBACK, PRO_STETIC_IDENTITY_FALLBACK, type ProductIdentityConfig } from "@/lib/product-identity";
import type { ProductKey } from "@/lib/product-routes";
import { APPOINTMENT_SCHEDULE_CONFLICT_MESSAGE, isAppointmentOutsideCurrentSchedule } from "@/lib/appointment-errors";

type DatabaseError = { message: string; code?: string } | null;

function assertData<T>(data: T | null, error: DatabaseError, fallback: string): T {
  if (error) throw new Error(error.message || fallback);
  if (data === null) throw new Error(fallback);
  return data;
}

export type BookingErrorKind = "CONFLICT" | "EXPIRED" | "ACTIVE_IN_ANOTHER_TAB" | "OUTSIDE_SCHEDULE" | null;

export function bookingErrorKind(error: unknown): BookingErrorKind {
  if (isAppointmentOutsideCurrentSchedule(error)) return "OUTSIDE_SCHEDULE";
  if (!(error instanceof Error)) return null;
  const message = error.message.toLowerCase();
  if (message.includes("requested slot is no longer available") || error.message.includes("23P01")) return "CONFLICT";
  if (message.includes("hold expired") || message.includes("hold is not active")) return "EXPIRED";
  if (message.includes("customer already has an active booking hold")) return "ACTIVE_IN_ANOTHER_TAB";
  return null;
}

export function toClientError(error: unknown, fallback: string): string {
  if (isAppointmentOutsideCurrentSchedule(error)) return APPOINTMENT_SCHEDULE_CONFLICT_MESSAGE;
  if (!(error instanceof Error)) return fallback;
  const message = error.message.toLowerCase();
  if (bookingErrorKind(error) === "CONFLICT") {
    return "Este cliente ou dependente já tem um agendamento nesse período, ou o horário acabou de ficar indisponível. Escolha outro horário.";
  }
  if (bookingErrorKind(error) === "EXPIRED") {
    return "O tempo para concluir terminou. Escolha o horário novamente.";
  }
  if (bookingErrorKind(error) === "ACTIVE_IN_ANOTHER_TAB") {
    return "Você já está finalizando outro horário em outra aba. Conclua-o ou aguarde até 3 minutos.";
  }
  if (message.includes("not accepting")) return "Este estabelecimento não aceita novas reservas no momento.";
  if (message.includes("cannot perform") || message.includes("active barber not found")) return "Profissional não executa seleção escolhida. Escolha outro.";
  if (message.includes("outside original two-week window")) return "Só é permitido reagendar dentro de 2 semanas antes ou depois da data original da sessão.";
  if (message.includes("outside the professional schedule")) return "O dia/horário escolhido está fora da escala do profissional. Escolha um horário disponível.";
  if (message.includes("subscription_overdue_installment")) return "Há parcela vencida neste plano. Regularize o pagamento antes de reagendar a sessão.";
  if (message.includes("requested date is blocked")) return "A agenda está bloqueada neste período. Escolha outra data.";
  if (message.includes("no environment is available") || message.includes("no longer available")) return "Este horário acabou de ficar indisponível. Escolha outro horário livre.";
  if (message.includes("mercado pago account is not connected")) return "O pagamento online ainda não foi conectado por este estabelecimento.";
  if (message.includes("reschedule deadline")) return "Prazo de reagendamento já terminou.";
  if (message.includes("previous_subscription_session_not_finished")) return "A sessão anterior precisa ser concluída antes de agendar a próxima.";
  if (message.includes("authentication required") || message.includes("jwt")) return "Sessão expirou. Entre novamente.";
  if (message.includes("client account not found") || message.includes("query returned no rows")) {
    return "Complete seus dados de cliente antes de acessar este estabelecimento.";
  }
  return error.message || fallback;
}

export async function getPublicBookingContext(
  supabase: SupabaseClient,
  slug: string,
): Promise<PublicBookingContext | null> {
  const { data, error } = await supabase.rpc("get_public_booking_context", {
    p_organization_slug: slug,
  });
  if (error) throw new Error(error.message);
  return (data as PublicBookingContext | null) ?? null;
}

export async function getMyClientAccount(
  supabase: SupabaseClient,
  userId: string,
): Promise<ClientAccount | null> {
  const { data, error } = await supabase
    .from("client_accounts")
    .select("auth_user_id,full_name,phone_e164,phone_verified_at,birth_date,cpf_cnpj,terms_policy_version,terms_accepted_at,created_at,updated_at")
    .eq("auth_user_id", userId)
    .maybeSingle();
  if (error) throw new Error(error.message);
  return (data as ClientAccount | null) ?? null;
}

export async function upsertMyClientAccount(
  supabase: SupabaseClient,
  input: {
    fullName: string;
    phoneE164: string;
    birthDate: string | null;
    cpfCnpj?: string | null;
    termsPolicyVersion: string;
  },
): Promise<string> {
  const { data, error } = await supabase.rpc("upsert_my_client_account", {
    p_full_name: input.fullName,
    p_phone_e164: input.phoneE164,
    p_birth_date: input.birthDate,
    p_terms_policy_version: input.termsPolicyVersion,
    ...(input.cpfCnpj ? { p_cpf_cnpj: input.cpfCnpj } : {}),
  });
  return assertData(data as string | null, error, "Não foi possível salvar conta do cliente.");
}

export async function listMyClientOrganizations(
  supabase: SupabaseClient,
): Promise<ClientOrganization[]> {
  const { data, error } = await supabase.rpc("list_my_client_organizations");
  return assertData(data as ClientOrganization[] | null, error, "Não foi possível carregar os estabelecimentos vinculados.");
}

export async function setMyLastClientOrganization(
  supabase: SupabaseClient,
  organizationSlug: string,
): Promise<void> {
  const { error } = await supabase.rpc("set_my_last_client_organization", {
    p_organization_slug: organizationSlug,
  });
  if (error) throw new Error(error.message);
}

export async function linkMyClientToOrganization(
  supabase: SupabaseClient,
  slug: string,
  expectedOrganizationId: string,
): Promise<ClientLinkResult> {
  const { data, error } = await supabase.rpc("link_my_client_to_organization", {
    p_organization_slug: slug,
    p_expected_organization_id: expectedOrganizationId,
  });
  return assertData(data as ClientLinkResult | null, error, "Não foi possível acessar este estabelecimento.");
}

export async function claimMyExistingCustomer(
  supabase: SupabaseClient,
  organizationId: string,
  customerId: string,
): Promise<ClientClaimResult> {
  const { data, error } = await supabase.rpc("claim_my_existing_customer", {
    p_organization_id: organizationId,
    p_customer_id: customerId,
  });
  return assertData(data as ClientClaimResult | null, error, "Não foi possível confirmar cadastro existente.");
}

export async function getMyCustomer(
  supabase: SupabaseClient,
  organizationId: string,
  userId: string,
): Promise<Customer | null> {
  const { data, error } = await supabase
    .from("customers")
    .select("id,organization_id,auth_user_id,full_name,phone_e164,email,birth_date,cpf_cnpj,created_at")
    .eq("organization_id", organizationId)
    .eq("auth_user_id", userId)
    .eq("active", true)
    .is("merged_into_customer_id", null)
    .maybeSingle();
  if (error) throw new Error(error.message);
  return (data as Customer | null) ?? null;
}

export async function getPublicClientEntryContext(
  supabase: SupabaseClient,
  input: { booking?: string | null; slug?: string | null },
): Promise<ClientEntryContext | null> {
  const { data, error } = await supabase.rpc("get_public_client_entry_context", {
    p_booking_public_id: input.booking ?? null,
    p_organization_slug: input.slug ?? null,
  });
  if (error) throw new Error(error.message);
  if (!data) return null;
  const value = data as ClientEntryContext;
  return {
    ...value,
    product_key: parseProductKey(value.product_key),
  };
}

export async function getPublicClientProductIdentity(
  supabase: SupabaseClient,
  productKey: ProductKey,
): Promise<ProductIdentityConfig | null> {
  const fallback = productKey === "ateliepro" ? ATELIE_PRO_IDENTITY_FALLBACK
    : productKey === "le-gras" ? LE_GRAS_IDENTITY_FALLBACK
    : productKey === "music-pro" ? MUSIC_PRO_IDENTITY_FALLBACK
    : productKey === "pro-stetic" ? PRO_STETIC_IDENTITY_FALLBACK : null;
  const { data, error } = await supabase.from("platform_product_identities")
    .select("config")
    .eq("product_key", productKey)
    .maybeSingle();
  return !error && isProductIdentityConfig(data?.config) ? data.config : fallback;
}

export async function listCustomerDependents(supabase: SupabaseClient, organizationId: string, customerId: string): Promise<CustomerDependent[]> {
  const { data, error } = await supabase.from("customer_dependents").select("id,organization_id,customer_id,full_name,birth_date,relationship,active").eq("organization_id", organizationId).eq("customer_id", customerId).eq("active", true).order("full_name");
  if (error) throw new Error(error.message);
  return (data as CustomerDependent[] | null) ?? [];
}

export async function createCustomerDependent(supabase: SupabaseClient, input: { organizationId: string; customerId: string; fullName: string; birthDate: string; relationship: CustomerDependent["relationship"] }) {
  const { data, error } = await supabase.rpc("create_customer_dependent", { p_organization_id: input.organizationId, p_customer_id: input.customerId, p_full_name: input.fullName, p_birth_date: input.birthDate, p_relationship: input.relationship });
  return assertData(data as CustomerDependent | null, error, "Não foi possível adicionar dependente.");
}

export async function updateCustomerDependent(supabase: SupabaseClient, input: { organizationId: string; dependentId: string; fullName: string; birthDate: string; relationship: CustomerDependent["relationship"] }) {
  const { data, error } = await supabase.rpc("update_customer_dependent", { p_organization_id: input.organizationId, p_dependent_id: input.dependentId, p_full_name: input.fullName, p_birth_date: input.birthDate, p_relationship: input.relationship });
  return assertData(data as CustomerDependent | null, error, "Não foi possível editar dependente.");
}

export async function deleteCustomerDependent(supabase: SupabaseClient, organizationId: string, dependentId: string) {
  const { data, error } = await supabase.rpc("delete_customer_dependent", { p_organization_id: organizationId, p_dependent_id: dependentId });
  return assertData(data as boolean | null, error, "Não foi possível excluir dependente.");
}

export async function setAppointmentAttendee(supabase: SupabaseClient, appointmentId: string, dependentId: string | null) {
  const { data, error } = await supabase.rpc("set_appointment_attendee", { p_appointment_id: appointmentId, p_attendee_dependent_id: dependentId });
  return assertData(data as boolean | null, error, "Não foi possível definir pessoa atendida.");
}

export async function upsertMyCustomer(
  supabase: SupabaseClient,
  input: {
    organizationId: string;
    fullName: string;
    phoneE164: string;
    email: string | null;
    birthDate: string | null;
  },
): Promise<string> {
  const { data, error } = await supabase.rpc("upsert_my_customer", {
    p_organization_id: input.organizationId,
    p_full_name: input.fullName,
    p_phone_e164: input.phoneE164,
    p_email: input.email,
    p_birth_date: input.birthDate,
  });
  return assertData(data as string | null, error, "Não foi possível salvar cliente.");
}

export async function getAvailableSlots(
  supabase: SupabaseClient,
  input: {
    organizationSlug: string;
    barberId: string;
    localDate: string;
    selections: BookingSelection[];
    walkinQueueHoldId?: string | null;
  },
): Promise<Availability | null> {
  const { data, error } = await supabase.rpc("get_available_slots", {
    p_organization_slug: input.organizationSlug,
    p_barber_id: input.barberId,
    p_local_date: input.localDate,
    p_selections: input.selections,
    ...(input.walkinQueueHoldId ? { p_walkin_queue_hold_id: input.walkinQueueHoldId } : {}),
  });
  if (error) throw new Error(error.message);
  return (data as Availability | null) ?? null;
}

export async function getPublicBookingOrganization(
  supabase: SupabaseClient,
  bookingPublicId: string,
): Promise<{ id: string; slug: string; name: string } | null> {
  const { data, error } = await supabase.rpc("get_public_booking_organization", {
    p_booking_public_id: bookingPublicId,
  });
  if (error) throw new Error(error.message);
  return (data as { id: string; slug: string; name: string } | null) ?? null;
}

export type WalkinQueueAvailability = {
  organization: { name: string; slug: string; timezone: string };
  slots: Array<{ barber_id: string; barber_name: string; starts_at: string; ends_at: string }>;
};

export async function getWalkinQueueAvailability(
  supabase: SupabaseClient,
  queuePublicId: string,
): Promise<WalkinQueueAvailability | null> {
  const { data, error } = await supabase.rpc("get_walkin_queue_availability", {
    p_queue_public_id: queuePublicId,
  });
  return assertData(data as WalkinQueueAvailability | null, error, "Não foi possível consultar a fila.");
}

export async function createWalkinQueueHold(
  supabase: SupabaseClient,
  input: { queuePublicId: string; barberId: string; startsAt: string },
): Promise<{ hold_id: string; expires_at: string }> {
  const { data, error } = await supabase.rpc("create_walkin_queue_hold", {
    p_queue_public_id: input.queuePublicId,
    p_barber_id: input.barberId,
    p_starts_at: input.startsAt,
  });
  return assertData(data as { hold_id: string; expires_at: string } | null, error, "Esse horário acabou de ser ocupado.");
}

export async function getAvailableSlotsForDate(
  supabase: SupabaseClient,
  input: {
    organizationSlug: string;
    localDate: string;
    selections: BookingSelection[];
  },
): Promise<DateAvailability | null> {
  const { data, error } = await supabase.rpc("get_available_slots_for_date", {
    p_organization_slug: input.organizationSlug,
    p_local_date: input.localDate,
    p_selections: input.selections,
  });
  if (error) throw new Error(error.message);
  return (data as DateAvailability | null) ?? null;
}

export type BookingHold = {
  appointment_id: string;
  status: "HELD" | "CONFIRMED";
  expires_at: string | null;
  total_cents: number;
  amount_due_now_cents: number;
  service_period: string;
};

export async function acquireBookingHold(
  supabase: SupabaseClient,
  input: {
    organizationId: string;
    customerId: string;
    barberId: string;
    startsAt: string;
    selections: BookingSelection[];
    idempotencyKey: string;
    walkinQueueHoldId?: string | null;
    attendeeDependentId?: string | null;
  },
): Promise<BookingHold> {
  const { data, error } = await supabase.rpc("create_customer_booking_hold", {
    p_organization_id: input.organizationId,
    p_customer_id: input.customerId,
    p_barber_id: input.barberId,
    p_starts_at: input.startsAt,
    p_selections: input.selections,
    p_idempotency_key: input.idempotencyKey,
    p_walkin_queue_hold_id: input.walkinQueueHoldId ?? null,
    p_attendee_dependent_id: input.attendeeDependentId ?? null,
  });
  return assertData<BookingHold>(data as BookingHold | null, error, "Não foi possível proteger horário.");
}

export async function confirmBookingHold(
  supabase: SupabaseClient,
  appointmentId: string,
): Promise<{ appointment_id: string; status: "CONFIRMED" | "EXPIRED"; service_period?: string }> {
  const { data, error } = await supabase.rpc("confirm_customer_booking_hold", {
    p_appointment_id: appointmentId,
  });
  return assertData(data as { appointment_id: string; status: "CONFIRMED" | "EXPIRED"; service_period?: string } | null, error, "Não foi possível confirmar reserva.");
}

export async function releaseBookingHold(
  supabase: SupabaseClient,
  appointmentId: string,
): Promise<{ appointment_id: string; status: "EXPIRED" }> {
  const { data, error } = await supabase.rpc("release_customer_booking_hold", {
    p_appointment_id: appointmentId,
  });
  return assertData(data as { appointment_id: string; status: "EXPIRED" } | null, error, "Não foi possível liberar horário.");
}

export async function createPaymentCheckoutOrder(
  supabase: SupabaseClient,
  appointmentId: string,
  idempotencyKey: string,
): Promise<{
  appointment_id: string;
  payment_order_id?: string;
  status: "PENDING_PAYMENT" | "CONFIRMED";
  amount_cents: number;
  currency?: string;
  expires_at?: string;
}> {
  const { data, error } = await supabase.rpc("create_payment_checkout_order", {
    p_appointment_id: appointmentId,
    p_idempotency_key: idempotencyKey,
  });
  return assertData<{
    appointment_id: string;
    payment_order_id?: string;
    status: "PENDING_PAYMENT" | "CONFIRMED";
    amount_cents: number;
    currency?: string;
    expires_at?: string;
  }>(data, error, "Não foi possível iniciar pagamento.");
}

export async function createMercadoPagoCheckout(
  supabase: SupabaseClient,
  paymentOrderId: string,
  idempotencyKey: string,
): Promise<string> {
  const { data, error } = await supabase.functions.invoke("mercado-pago-create-checkout", {
    body: { paymentOrderId },
    headers: { "Idempotency-Key": idempotencyKey },
  });
  if (error) throw new Error(error.message || "Mercado Pago indisponível.");
  const checkoutUrl = (data as { checkoutUrl?: unknown } | null)?.checkoutUrl;
  if (typeof checkoutUrl !== "string" || !isMercadoPagoCheckoutUrl(checkoutUrl)) {
    throw new Error("URL de checkout inválida.");
  }
  return checkoutUrl;
}

type AppointmentRow = Omit<CustomerAppointment, "items" | "financial" | "pending_payment_order_id">;
type FinancialRow = CustomerAppointment["financial"] & { appointment_id: string };
type PaymentOrderRow = { id: string; appointment_id: string; status: string; created_at: string };

export async function getMyAppointments(
  supabase: SupabaseClient,
  organizationId: string,
  customerId: string,
  timezone: string,
): Promise<CustomerAppointment[]> {
  const { data: appointments, error } = await supabase
    .from("appointments")
    .select("id,organization_id,customer_id,barber_id,status,whatsapp_response_status,service_period,payment_mode,currency,total_cents_snapshot,deposit_required_cents_snapshot,cancellation_lead_minutes_snapshot,cancellation_outcome,cancellation_actor_name,cancelled_at,subscription_session_id,created_at")
    .eq("organization_id", organizationId)
    .eq("customer_id", customerId)
    .order("created_at", { ascending: false });
  if (error) throw new Error(error.message);
  const rows = (appointments as AppointmentRow[] | null) ?? [];
  if (!rows.length) return [];
  const ids = rows.map((appointment) => appointment.id);
  const subscriptionSessionIds = [...new Set(rows.flatMap((appointment) =>
    appointment.status === "CONFIRMED" && appointment.subscription_session_id
      ? [appointment.subscription_session_id]
      : [],
  ))];
  const [
    { data: items, error: itemsError },
    { data: financial, error: financialError },
    { data: paymentOrders, error: paymentOrdersError },
  ] = await Promise.all([
    supabase
      .from("appointment_items")
      .select("id,appointment_id,selection_key,source,service_id,package_id,service_name_snapshot,quantity,charged_price_cents_snapshot,list_price_cents_snapshot,duration_minutes_snapshot,position")
      .eq("organization_id", organizationId)
      .in("appointment_id", ids)
      .order("position", { ascending: true }),
    supabase
      .from("appointment_financial_summary")
      .select("appointment_id,captured_cents,refunded_cents,net_paid_cents,outstanding_cents,financial_status")
      .eq("organization_id", organizationId)
      .in("appointment_id", ids),
    supabase
      .from("payment_orders")
      .select("id,appointment_id,status,created_at")
      .eq("organization_id", organizationId)
      .in("appointment_id", ids)
      .in("kind", ["DEPOSIT", "FULL"])
      .in("status", ["CREATED", "PENDING"])
      .order("created_at", { ascending: false }),
  ]);
  if (itemsError) throw new Error(itemsError.message);
  if (financialError) throw new Error(financialError.message);
  if (paymentOrdersError) throw new Error(paymentOrdersError.message);
  let schedulingModeBySession = new Map<string, "FIXED" | "FREE">();
  let planIdBySession = new Map<string, string>();
  let subscriptionIdBySession = new Map<string, string>();
  let originalStartBySession = new Map<string, string | null>();
  const overdueSubscriptionIds = new Set<string>();
  if (subscriptionSessionIds.length) {
    const { data: sessionRows, error: sessionError } = await supabase
      .from("customer_subscription_sessions")
      .select("id,subscription_id,rescheduled_from")
      .eq("organization_id", organizationId)
      .in("id", subscriptionSessionIds);
    if (sessionError) throw new Error(sessionError.message);
    const sessions = (sessionRows as Array<{ id: string; subscription_id: string }> | null) ?? [];
    subscriptionIdBySession = new Map(sessions.map((session) => [session.id, session.subscription_id]));
    const subscriptionIds = [...new Set(sessions.map((session) => session.subscription_id))];
    originalStartBySession = new Map(sessions.map((session) => [
      session.id,
      (session as { rescheduled_from?: string | null }).rescheduled_from ?? null,
    ]));
    if (subscriptionIds.length) {
      const [
        { data: subscriptionRows, error: subscriptionError },
        { data: cycleRows, error: cycleError },
      ] = await Promise.all([
        supabase.from("customer_subscriptions")
          .select("id,plan_id,plan_version_id")
          .eq("organization_id", organizationId)
          .in("id", subscriptionIds),
        supabase.from("customer_subscription_cycles")
          .select("subscription_id,due_on,status")
          .eq("organization_id", organizationId)
          .in("subscription_id", subscriptionIds)
          .in("status", ["OPEN", "OVERDUE"]),
      ]);
      if (subscriptionError) throw new Error(subscriptionError.message);
      if (cycleError) throw new Error(cycleError.message);
      const subscriptions = (subscriptionRows as Array<{ id: string; plan_version_id: string }> | null) ?? [];
      const planBySubscription = new Map((subscriptionRows as Array<{ id: string; plan_id: string }> | null ?? [])
        .map((subscription) => [subscription.id, subscription.plan_id]));
      const today = localToday(timezone);
      for (const cycle of (cycleRows as Array<{ subscription_id: string; due_on: string; status: string }> | null) ?? []) {
        if (cycle.status === "OVERDUE" || (cycle.status === "OPEN" && cycle.due_on < today)) {
          overdueSubscriptionIds.add(cycle.subscription_id);
        }
      }
      const versionIds = [...new Set(subscriptions.map((subscription) => subscription.plan_version_id))];
      if (versionIds.length) {
        const { data: versions, error: versionsError } = await supabase
          .from("subscription_plan_versions")
          .select("id,scheduling_mode")
          .eq("organization_id", organizationId)
          .in("id", versionIds);
        if (versionsError) throw new Error(versionsError.message);
        const modeByVersion = new Map((versions as Array<{ id: string; scheduling_mode: string }> | null ?? [])
          .map((version) => [version.id, version.scheduling_mode === "FIXED" ? "FIXED" as const : "FREE" as const]));
        const versionBySubscription = new Map(subscriptions.map((subscription) => [subscription.id, subscription.plan_version_id]));
        schedulingModeBySession = new Map(sessions.flatMap((session) => {
          const versionId = versionBySubscription.get(session.subscription_id);
          const mode = versionId ? modeByVersion.get(versionId) : undefined;
          return mode ? [[session.id, mode] as const] : [];
        }));
        planIdBySession = new Map(sessions.flatMap((session) => {
          const planId = planBySubscription.get(session.subscription_id);
          return planId ? [[session.id, planId] as const] : [];
        }));
      }
    }
  }
  const itemRows = (items as AppointmentItem[] | null) ?? [];
  const financialRows = (financial as FinancialRow[] | null) ?? [];
  const paymentOrderRows = (paymentOrders as PaymentOrderRow[] | null) ?? [];
  return rows.map((appointment) => ({
    ...appointment,
    subscription_scheduling_mode: appointment.subscription_session_id
      ? schedulingModeBySession.get(appointment.subscription_session_id) ?? null
      : null,
    subscription_plan_id: appointment.subscription_session_id
      ? planIdBySession.get(appointment.subscription_session_id) ?? null
      : null,
    subscription_reschedule_original_starts_at: appointment.subscription_session_id
      ? originalStartBySession.get(appointment.subscription_session_id) ?? null
      : null,
    subscription_has_overdue_installment: appointment.subscription_session_id
      ? overdueSubscriptionIds.has(subscriptionIdBySession.get(appointment.subscription_session_id) ?? "")
      : false,
    pending_payment_order_id: paymentOrderRows.find((item) => item.appointment_id === appointment.id)?.id ?? null,
    items: itemRows.filter((item) => item.appointment_id === appointment.id),
    financial: financialRows.find((item) => item.appointment_id === appointment.id) ?? {
      captured_cents: 0,
      refunded_cents: 0,
      net_paid_cents: 0,
      outstanding_cents: appointment.total_cents_snapshot,
      financial_status: "UNPAID" as FinancialStatus,
    },
  }));
}

export async function getClientManagerNotificationPhone(
  supabase: SupabaseClient,
  organizationId: string,
): Promise<string | null> {
  const { data, error } = await supabase.rpc("get_client_manager_notification_phone", {
    p_organization_id: organizationId,
  });
  if (error) throw new Error(error.message);
  return typeof data === "string" ? data : null;
}

export async function getNextMyAppointment(
  supabase: SupabaseClient,
  organizationId: string,
  customerId: string,
): Promise<NextCustomerAppointment | null> {
  const now = new Date().toISOString();
  const { data, error } = await supabase
    .from("appointments")
    .select("id,barber_id,status,service_period,payment_mode,currency,total_cents_snapshot")
    .eq("organization_id", organizationId)
    .eq("customer_id", customerId)
    .in("status", ["HELD", "PENDING_PAYMENT", "CONFIRMED"])
    .overlaps("service_period", `[${now},)`)
    .order("service_period", { ascending: true })
    .limit(25);
  if (error) throw new Error(error.message);

  const rows = (data as Array<Omit<NextCustomerAppointment, "items"> & { id: string }> | null) ?? [];
  const appointment = rows.find((row) => new Date(parsePostgresRange(row.service_period).startsAt).getTime() >= Date.now());
  if (!appointment) return null;

  const { data: items, error: itemsError } = await supabase
    .from("appointment_items")
    .select("service_name_snapshot,position")
    .eq("organization_id", organizationId)
    .eq("appointment_id", appointment.id)
    .order("position", { ascending: true });
  if (itemsError) throw new Error(itemsError.message);

  return {
    barber_id: appointment.barber_id,
    status: appointment.status,
    service_period: appointment.service_period,
    payment_mode: appointment.payment_mode,
    currency: appointment.currency,
    total_cents_snapshot: appointment.total_cents_snapshot,
    items: (items as Array<Pick<NextCustomerAppointment["items"][number], "service_name_snapshot" | "position">> | null) ?? [],
  };
}

export async function cancelAppointment(
  supabase: SupabaseClient,
  appointmentId: string,
  reason: string,
): Promise<{ appointment_id: string; refund_amount_cents: number; refund_order_id: string | null }> {
  const { data, error } = await supabase.rpc("cancel_appointment", {
    p_appointment_id: appointmentId,
    p_reason: reason || "customer_requested",
    p_requested_by_customer: true,
  });
  return assertData<{ appointment_id: string; refund_amount_cents: number; refund_order_id: string | null }>(data, error, "Não foi possível cancelar reserva.");
}

export async function rescheduleAppointment(
  supabase: SupabaseClient,
  input: { appointmentId: string; barberId: string; startsAt: string; selections?: BookingSelection[] | null },
): Promise<{ appointment_id: string; service_period: string; total_cents: number }> {
  const { data, error } = await supabase.rpc("reschedule_appointment", {
    p_appointment_id: input.appointmentId,
    p_new_barber_id: input.barberId,
    p_new_starts_at: input.startsAt,
    p_selections: input.selections ?? null,
    p_override_reason: null,
  });
  return assertData<{ appointment_id: string; service_period: string; total_cents: number }>(data, error, "Não foi possível reagendar reserva.");
}

export async function rescheduleFixedSubscriptionSession(
  supabase: SupabaseClient,
  input: { organizationId: string; subscriptionSessionId: string; barberId: string; startsAt: string },
): Promise<{ appointment_id: string; subscription_session_id: string; service_period: string; status: string }> {
  const { data, error } = await supabase.rpc("reschedule_fixed_customer_subscription_session", {
    p_organization_id: input.organizationId,
    p_subscription_session_id: input.subscriptionSessionId,
    p_new_starts_at: input.startsAt,
    p_new_barber_id: input.barberId,
  });
  return assertData<{ appointment_id: string; subscription_session_id: string; service_period: string; status: string }>(
    data,
    error,
    "Não foi possível reagendar a sessão do plano.",
  );
}

export async function getCustomerPrivacy(
  supabase: SupabaseClient,
  organizationId: string,
  customerId: string,
): Promise<{ whatsappGranted: boolean; marketingGranted: boolean; requests: PrivacyRequest[] }> {
  const [{ data: consents, error: consentError }, { data: marketing, error: marketingError }, { data: requests, error: requestError }] = await Promise.all([
    supabase
      .from("consent_events")
      .select("action,occurred_at")
      .eq("organization_id", organizationId)
      .eq("customer_id", customerId)
      .eq("kind", "WHATSAPP_TRANSACTIONAL")
      .order("occurred_at", { ascending: false }).order("id", { ascending: false }).limit(1),
    supabase.from("consent_events").select("action,occurred_at")
      .eq("organization_id", organizationId).eq("customer_id", customerId).eq("kind", "MARKETING")
      .order("occurred_at", { ascending: false }).order("id", { ascending: false }).limit(1),
    supabase
      .from("privacy_requests")
      .select("id,kind,status,requested_at,due_at")
      .eq("organization_id", organizationId)
      .eq("customer_id", customerId)
      .order("requested_at", { ascending: false }),
  ]);
  if (consentError) throw new Error(consentError.message);
  if (requestError) throw new Error(requestError.message);
  if (marketingError) throw new Error(marketingError.message);
  const latest = (consents as { action: string }[] | null)?.[0];
  return {
    whatsappGranted: latest?.action === "GRANTED",
    marketingGranted: (marketing as { action: string }[] | null)?.[0]?.action === "GRANTED",
    requests: (requests as PrivacyRequest[] | null) ?? [],
  };
}

export async function recordWhatsappConsent(
  supabase: SupabaseClient,
  input: { organizationId: string; customerId: string; granted: boolean; kind?: "WHATSAPP_TRANSACTIONAL" | "MARKETING"; source?: "PWA_PROFILE" | "PWA_BOOKING" },
): Promise<string> {
  const { data, error } = await supabase.rpc("record_consent_event", {
    p_organization_id: input.organizationId,
    p_customer_id: input.customerId,
    p_kind: input.kind ?? "WHATSAPP_TRANSACTIONAL",
    p_action: input.granted ? "GRANTED" : "REVOKED",
    p_source: input.source ?? "PWA_PROFILE",
    p_proof: { interface: "connected-client", locale: "pt-BR", explicit_control: true },
    p_policy_version: "mvp-2026-08",
  });
  return assertData(data as string | null, error, "Não foi possível atualizar consentimento.");
}

export async function submitPrivacyRequest(
  supabase: SupabaseClient,
  input: { organizationId: string; customerId: string; kind: PrivacyRequest["kind"] },
): Promise<string> {
  const { data, error } = await supabase.rpc("submit_privacy_request", {
    p_organization_id: input.organizationId,
    p_customer_id: input.customerId,
    p_kind: input.kind,
  });
  return assertData(data as string | null, error, "Não foi possível abrir solicitação.");
}
