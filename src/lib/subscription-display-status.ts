export type SubscriptionDisplayStatus = "pending" | "cancellationPending" | "due" | "finished" | "overdue" | "active" | "declined" | "canceled";

type SubscriptionStatusSource = {
  status?: unknown;
  contract_accepted_at?: unknown;
  manager_activated_provisionally_at?: unknown;
};

type SubscriptionCycleStatusSource = { status?: unknown; due_on?: unknown };

export function subscriptionDisplayStatuses(
  subscription: SubscriptionStatusSource,
  cycles: ReadonlyArray<SubscriptionCycleStatusSource>,
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

export function subscriptionDisplayStatus(
  subscription: SubscriptionStatusSource,
  cycles: ReadonlyArray<SubscriptionCycleStatusSource>,
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

export const activeSubscriptionStatuses = new Set<SubscriptionDisplayStatus>([
  "cancellationPending",
  "active",
  "due",
  "overdue",
]);

export const subscriptionDisplayStatusLabels: Record<SubscriptionDisplayStatus, string> = {
  pending: "Pendente",
  cancellationPending: "Cancelamento pendente",
  due: "À Vencer",
  finished: "Finalizado",
  overdue: "Em Atraso",
  active: "Ativo",
  declined: "Recusada",
  canceled: "Cancelada",
};
