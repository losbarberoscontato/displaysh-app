"use client";

import { useMemo, useState, type FormEvent } from "react";
import { useRouter } from "next/navigation";
import { Archive, X } from "lucide-react";
import { PageHeader } from "@/components/ui";
import type { loadSubscriptionPlansData } from "./server";
import type { AwaitedReturn } from "./utility-types";
import { ActionMessage, Field, Panel, StatusChip } from "./shared";
import { assertResult, connectedClient, runMutation } from "./mutation-utils";
import { centsFromInput, formatCents } from "./format";
import styles from "./connected-manager.module.css";
import { showManagerError } from "@/components/manager-error-dialog";

type Props = AwaitedReturn<typeof loadSubscriptionPlansData>;
type Plan = Props["plans"][number];
type PlanVersion = Props["versions"][number];
type SchedulingMode = "FREE" | "FIXED";
type DiscountType = "NONE" | "FIXED" | "PERCENT";

type BundleDraft = {
  serviceId: string;
  schedulingMode: SchedulingMode;
  sessionsPerWeek: string;
  durationMinutes: string;
  totalSessions: string;
  pricePerSession: string;
  entry: string;
  paymentMethod: string;
  installmentCount: string;
  discountType: DiscountType;
  discountValue: string;
};

const emptyDraft: BundleDraft = {
  serviceId: "",
  schedulingMode: "FREE",
  sessionsPerWeek: "1",
  durationMinutes: "30",
  totalSessions: "12",
  pricePerSession: "50,00",
  entry: "0,00",
  paymentMethod: "PIX",
  installmentCount: "1",
  discountType: "NONE",
  discountValue: "",
};

function moneyInput(cents: number | null | undefined) {
  return cents === null || cents === undefined ? "" : (cents / 100).toFixed(2).replace(".", ",");
}

function percentageInput(basisPoints: number | null | undefined) {
  return basisPoints === null || basisPoints === undefined ? "" : (basisPoints / 100).toFixed(2).replace(".", ",");
}

export function SubscriptionPlansManager(props: Props) {
  const router = useRouter();
  const [message, setMessage] = useState("");
  const [newPlanOpen, setNewPlanOpen] = useState(false);
  const [editingPlanId, setEditingPlanId] = useState<string | null>(null);
  const [draft, setDraft] = useState<BundleDraft>(emptyDraft);
  const [planFilter, setPlanFilter] = useState<"ALL" | "ACTIVE" | "INACTIVE" | "ARCHIVED">("ALL");
  const [contractPlanId, setContractPlanId] = useState<string | null>(null);
  const [contractBody, setContractBody] = useState("");

  const editingPlan = props.plans.find((plan) => plan.id === editingPlanId) ?? null;
  const totalSessions = Math.max(0, Number(draft.totalSessions) || 0);
  const installmentCount = Math.max(1, Number(draft.installmentCount) || 1);
  const unitPriceCents = centsFromInput(draft.pricePerSession);
  const entryCents = centsFromInput(draft.entry);
  const totalPriceCents = unitPriceCents * totalSessions;
  const installmentBase = Math.floor(totalPriceCents / installmentCount);
  const discountAmount = draft.discountType === "PERCENT"
    ? Math.round(installmentBase * ((Number(draft.discountValue.replace(",", ".")) || 0) * 100) / 10000)
    : draft.discountType === "FIXED" ? centsFromInput(draft.discountValue) : 0;
  const installmentAfterDiscount = Math.max(0, installmentBase - discountAmount);
  const visiblePlans = props.plans.filter((plan) => planFilter === "ALL"
    || (planFilter === "ARCHIVED" ? plan.archived_at !== null
      : plan.archived_at === null && (planFilter === "ACTIVE" ? plan.active : !plan.active)));
  const versionByPlan = useMemo(() => {
    const result = new Map<string, PlanVersion>();
    for (const version of props.versions) {
      if (!result.has(version.plan_id)) result.set(version.plan_id, version);
    }
    return result;
  }, [props.versions]);

  function resetDraft() {
    setEditingPlanId(null);
    setDraft({ ...emptyDraft, serviceId: props.services[0]?.id ?? "", durationMinutes: String(props.services[0]?.duration_minutes ?? 30) });
  }

  function openPlanForm(planId: string | null = null) {
    setMessage("");
    setEditingPlanId(planId);
    if (!planId) {
      resetDraft();
    } else {
      const version = versionByPlan.get(planId);
      const service = version?.bundle_service_id
        ? props.services.find((item) => item.id === version.bundle_service_id)
        : props.planServices.find((item) => item.plan_version_id === version?.id)
          ? props.services.find((item) => item.id === props.planServices.find((link) => link.plan_version_id === version?.id)?.service_id)
          : props.services[0];
      if (!version) {
        showManagerError("Não foi possível carregar a versão atual deste plano.");
        return;
      }
      const legacySessionCount = Math.max(1, Number(version.sessions_per_cycle) || 1);
      setDraft({
        serviceId: service?.id ?? "",
        schedulingMode: version.bundle_scheduling_mode === "FIXED" ? "FIXED" : "FREE",
        sessionsPerWeek: String(version.bundle_sessions_per_week ?? Math.min(21, legacySessionCount)),
        durationMinutes: String(version.bundle_session_duration_minutes ?? service?.duration_minutes ?? 30),
        totalSessions: String(version.bundle_total_sessions ?? legacySessionCount),
        pricePerSession: moneyInput(version.bundle_price_per_session_cents ?? Math.ceil(Number(version.price_cents) / legacySessionCount)),
        entry: moneyInput(version.bundle_entry_cents ?? 0),
        paymentMethod: version.payment_method === "ONLINE" || version.payment_method === "CARD" || version.payment_method === "PIX" || version.payment_method === "BOLETO" || version.payment_method === "CASH" || version.payment_method === "CRYPTO"
          ? version.payment_method : "PIX",
        installmentCount: String(version.bundle_installment_count ?? 1),
        discountType: version.bundle_discount_type === "FIXED" || version.bundle_discount_type === "PERCENT" ? version.bundle_discount_type : "NONE",
        discountValue: version.bundle_discount_type === "PERCENT"
          ? percentageInput(version.bundle_discount_value)
          : version.bundle_discount_type === "FIXED" ? moneyInput(version.bundle_discount_value) : "",
      });
    }
    setNewPlanOpen(true);
  }

  function setDraftField<Key extends keyof BundleDraft>(key: Key, value: BundleDraft[Key]) {
    setDraft((current) => ({ ...current, [key]: value }));
  }

  async function save(event: FormEvent<HTMLFormElement>) {
    event.preventDefault();
    const data = new FormData(event.currentTarget);
    const serviceId = String(data.get("service_id") ?? "");
    if (!serviceId) {
      showManagerError("Selecione um serviço.");
      return;
    }
    const discountType = String(data.get("discount_type") ?? "NONE") as DiscountType;
    const discountInput = String(data.get("discount_value") ?? "");
    const discountValue = discountType === "PERCENT"
      ? Math.round((Number(discountInput.replace(",", ".")) || 0) * 100)
      : discountType === "FIXED" ? centsFromInput(discountInput) : 0;
    const saved = await runMutation(
      setMessage,
      async () => {
        await assertResult(await connectedClient().rpc("save_subscription_bundle_plan", {
          p_organization_id: props.organizationId,
          p_plan_id: editingPlanId,
          p_name: String(data.get("name") ?? "").trim(),
          p_description: String(data.get("description") ?? "").trim(),
          p_service_id: serviceId,
          p_scheduling_mode: String(data.get("scheduling_mode")),
          p_sessions_per_week: Number(data.get("sessions_per_week")),
          p_session_duration_minutes: Number(data.get("session_duration_minutes")),
          p_total_sessions: Number(data.get("total_sessions")),
          p_price_per_session_cents: centsFromInput(data.get("price_per_session")),
          p_entry_cents: centsFromInput(data.get("entry")),
          p_payment_method: String(data.get("payment_method")),
          p_installment_count: Number(data.get("installment_count")),
          p_discount_type: discountType,
          p_discount_value: discountValue,
        }));
      },
      editingPlan ? "Plano atualizado para novos contratos." : "Plano criado.",
    );
    if (saved) {
      setNewPlanOpen(false);
      resetDraft();
      router.refresh();
    }
  }

  async function archivePlan(plan: Plan) {
    if (!window.confirm(`Arquivar "${plan.name}"? Contratos existentes serão preservados e novas ofertas deixarão de usar este plano.`)) return;
    const archived = await runMutation(setMessage, async () => {
      await assertResult(await connectedClient().rpc("archive_subscription_plan", {
        p_organization_id: props.organizationId,
        p_plan_id: plan.id,
      }));
    }, "Plano arquivado.");
    if (archived) router.refresh();
  }

  async function saveContract(planId: string) {
    const saved = await runMutation(setMessage, async () => {
      await assertResult(await connectedClient().rpc("set_subscription_plan_contract", {
        p_organization_id: props.organizationId,
        p_plan_id: planId,
        p_contract_body: contractBody.trim() || null,
      }));
    }, "Contrato do plano salvo.");
    if (saved) { setContractPlanId(null); router.refresh(); }
  }

  const updateService = (serviceId: string) => {
    const nextService = props.services.find((service) => service.id === serviceId);
    setDraft((current) => ({
      ...current,
      serviceId,
      durationMinutes: String(nextService?.duration_minutes ?? current.durationMinutes),
    }));
  };

  return <div className={styles.stack}>
    <PageHeader title="Planos de Assinatura" description="Configure planos por serviço, com sessões livres ou agenda semanal fixa." />
    <ActionMessage message={message} />
    {!props.subscriptionModuleEnabled && <div className={styles.notice}>Planos de Assinatura está inativo em Configurações → Módulos. Contratos existentes permanecem disponíveis.</div>}
    <Panel title="Planos cadastrados" description={`${visiblePlans.length} de ${props.plans.length} planos`} action={<button className={styles.button} type="button" disabled={!props.subscriptionModuleEnabled} onClick={() => openPlanForm()}>Novo plano</button>}>
      <div className={styles.subscriptionPlanFilters} role="group" aria-label="Filtrar planos">
        {([ ["ALL", "Todos"], ["ACTIVE", "Ativos"], ["INACTIVE", "Inativos"], ["ARCHIVED", "Arquivados"] ] as const).map(([value, label]) => <button key={value} type="button" className={`${styles.button} ${styles.buttonSoft} ${planFilter === value ? styles.subscriptionPlanFilterSelected : ""}`} aria-pressed={planFilter === value} onClick={() => setPlanFilter(value)}>{label}</button>)}
      </div>
      <div className={styles.list}>{visiblePlans.map((plan) => {
        const version = versionByPlan.get(plan.id);
        const editingContract = contractPlanId === plan.id;
        const archived = plan.archived_at !== null;
        const isBundle = version?.model === "SESSION_BUNDLE_V1";
        return <article className={`${styles.row} ${styles.subscriptionPlanRow}`} key={plan.id}>
          <span className={styles.rowTitle}><strong>{plan.name}</strong><small>{plan.description || "Sem descrição"}</small></span>
          <strong>{version ? formatCents(version.price_cents) : "—"}</strong>
          <span>{isBundle ? `${version.bundle_sessions_per_week} sessão(ões)/semana` : "Legado · contratos preservados"}</span>
          <span>{isBundle ? `${version.bundle_total_sessions} sessões · ${version.bundle_scheduling_mode === "FIXED" ? "Fixo" : "Livre"}` : "Somente contratos existentes"}</span>
          <div className={`${styles.rowActions} ${styles.subscriptionPlanActions}`}>
            <StatusChip active={!archived && plan.active} label={archived ? "ARQUIVADO" : plan.active ? "ATIVO" : "INATIVO"} />
            {!archived && <>
              <button type="button" className={`${styles.button} ${styles.buttonSoft} ${styles.buttonSmall}`} disabled={!props.subscriptionModuleEnabled} onClick={() => openPlanForm(plan.id)}>Editar</button>
              <button type="button" className={`${styles.button} ${styles.buttonSoft} ${styles.subscriptionPlanArchive}`} aria-label={`Arquivar plano ${plan.name}`} title="Arquivar plano" onClick={() => void archivePlan(plan)}><Archive size={17} aria-hidden="true" /></button>
            </>}
            <button type="button" className={`${styles.button} ${styles.buttonSoft} ${styles.buttonSmall}`} disabled={!props.subscriptionModuleEnabled} aria-expanded={editingContract} onClick={() => { setContractPlanId(editingContract ? null : plan.id); setContractBody(plan.contract_body_override ?? ""); }}>{editingContract ? "Fechar contrato" : "Editar contrato"}</button>
          </div>
          {editingContract && <div className={`${styles.formWide} ${styles.subscriptionPlanContractEditor}`}><textarea value={contractBody} onChange={(event) => setContractBody(event.target.value)} minLength={20} rows={6} placeholder="Contrato específico deste plano. Deixe vazio para usar o contrato padrão." /><div className={styles.toolbarGroup}><button type="button" className={styles.button} onClick={() => void saveContract(plan.id)}>Salvar contrato</button><small className={styles.muted}>Novas ofertas usam este texto; contratos já aceitos permanecem congelados.</small></div></div>}
        </article>;
      })}</div>
    </Panel>
    {newPlanOpen && <div className={styles.modalLayer} role="presentation">
      <button className={styles.modalBackdrop} type="button" aria-label="Fechar cadastro de plano" onClick={() => { resetDraft(); setNewPlanOpen(false); setMessage(""); }} />
      <form className={`${styles.modal} ${styles.modalWide} ${styles.subscriptionPlanModal}`} role="dialog" aria-modal="true" aria-labelledby="new-subscription-plan-title" onSubmit={save}>
        <header className={styles.modalHeader}><div><small>{editingPlan ? "Edição de plano" : "Cadastro de planos"}</small><h2 id="new-subscription-plan-title">{editingPlan ? "Editar plano" : "Novo plano"}</h2></div><button className={styles.modalClose} type="button" aria-label="Fechar" onClick={() => { resetDraft(); setNewPlanOpen(false); setMessage(""); }}><X size={19} /></button></header>
        <div className={styles.form}>
          <Field label="Nome do Plano de Assinatura"><input name="name" defaultValue={editingPlan?.name ?? ""} required minLength={2} maxLength={120} /></Field>
          <Field label="Serviço"><select name="service_id" value={draft.serviceId} onChange={(event) => updateService(event.target.value)} required><option value="">Selecione um serviço</option>{props.services.map((service) => <option key={service.id} value={service.id}>{service.name} · {formatCents(service.price_cents)}</option>)}</select></Field>
          <Field label="Descrição" wide><textarea name="description" defaultValue={editingPlan?.description ?? ""} maxLength={4000} /></Field>
          <div className={`${styles.formWide} ${styles.formCompactRow}`}>
            <Field label="Tipo de Agendamento"><select name="scheduling_mode" value={draft.schedulingMode} onChange={(event) => setDraftField("schedulingMode", event.target.value as SchedulingMode)}><option value="FREE">Livre</option><option value="FIXED">Fixo</option></select></Field>
            <Field label="Sessões por semana"><input name="sessions_per_week" type="number" min={1} max={21} value={draft.sessionsPerWeek} onChange={(event) => setDraftField("sessionsPerWeek", event.target.value)} required /></Field>
            <Field label="Duração da sessão (minutos)"><input name="session_duration_minutes" type="number" min={5} max={180} value={draft.durationMinutes} onChange={(event) => setDraftField("durationMinutes", event.target.value)} required /></Field>
          </div>
          {draft.schedulingMode === "FIXED" && <div className={`${styles.formWide} ${styles.notice}`}><strong>Agenda fixa configurada no contrato.</strong> As sessões semanais, com profissional e sala por horário, serão definidas ao enviar uma oferta para o cliente.</div>}
          <Field label="Total de sessões do Plano"><input name="total_sessions" type="number" min={1} max={300} value={draft.totalSessions} onChange={(event) => setDraftField("totalSessions", event.target.value)} required /></Field>
          <Field label="Valor por sessão (R$)"><input name="price_per_session" inputMode="decimal" value={draft.pricePerSession} onChange={(event) => setDraftField("pricePerSession", event.target.value)} required /></Field>
          <Field label="Total do plano"><input value={formatCents(totalPriceCents)} readOnly aria-label="Total do plano" /></Field>
          <Field label="Valor da entrada (R$)"><input name="entry" inputMode="decimal" value={draft.entry} onChange={(event) => setDraftField("entry", event.target.value)} required /></Field>
          <Field label="Forma de pagamento"><select name="payment_method" value={draft.paymentMethod} onChange={(event) => setDraftField("paymentMethod", event.target.value)}><option value="PIX">PIX</option><option value="CARD">Cartão</option><option value="BOLETO">Boleto</option><option value="CASH">Dinheiro</option><option value="CRYPTO">Cripto</option><option value="ONLINE">Link de pagamento</option></select></Field>
          <div className={`${styles.formWide} ${styles.formCompactRow}`}>
            <Field label="Total de parcelas"><input name="installment_count" type="number" min={1} max={24} value={draft.installmentCount} onChange={(event) => setDraftField("installmentCount", event.target.value)} required /></Field>
            <Field label="Desconto por parcela"><select name="discount_type" value={draft.discountType} onChange={(event) => setDraftField("discountType", event.target.value as DiscountType)}><option value="NONE">Sem desconto</option><option value="FIXED">Valor em reais</option><option value="PERCENT">Percentual</option></select></Field>
            {draft.discountType !== "NONE" && <Field label={draft.discountType === "PERCENT" ? "Desconto (%)" : "Desconto (R$)"}><input name="discount_value" type="number" min="0.01" step={draft.discountType === "PERCENT" ? "0.01" : "0.01"} max={draft.discountType === "PERCENT" ? "99.99" : undefined} value={draft.discountValue} onChange={(event) => setDraftField("discountValue", event.target.value)} required /></Field>}
          </div>
          <div className={`${styles.formWide} ${styles.notice}`}>
            <strong>Prévia das parcelas:</strong> {formatCents(installmentAfterDiscount)} por parcela · {draft.installmentCount} parcela(s) · entrada de {formatCents(entryCents)} à parte.
            <small className={styles.muted}>Vencimentos da entrada e da primeira parcela serão definidos no contrato. O sistema calcula as demais datas mensalmente e ajusta dias inexistentes para o último dia do mês.</small>
          </div>
          <div className={`${styles.toolbarGroup} ${styles.formWide}`}>
            <button className={`${styles.button} ${styles.buttonSoft}`} type="button" onClick={() => { resetDraft(); setNewPlanOpen(false); setMessage(""); }}>Cancelar</button>
            <button className={styles.button} type="submit" disabled={!props.services.length || !draft.serviceId}>{editingPlan ? "Salvar alterações" : "Criar plano"}</button>
          </div>
        </div>
      </form>
    </div>}
  </div>;
}
