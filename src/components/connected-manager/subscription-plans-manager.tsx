"use client";

import { useRouter } from "next/navigation";
import { useState, type FormEvent } from "react";
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

const defaultCancellationPolicy = "Cancelamento encerra no fim do ciclo pago; ciclos futuros são cancelados sem renovação automática.";
const defaultSessionCancellationPolicy = "Cancelamento dentro do prazo devolve a sessão. Cancelamento tardio ou no-show consome a sessão, sem cobrança adicional.";

export function SubscriptionPlansManager(props: Props) {
  const router = useRouter();
  const [message, setMessage] = useState("");
  const [selected, setSelected] = useState<string[]>([]);
  const [formKey, setFormKey] = useState(0);
  const [newPlanOpen, setNewPlanOpen] = useState(false);
  const [editingPlanId, setEditingPlanId] = useState<string | null>(null);
  const [billingPeriod, setBillingPeriod] = useState<"MONTHLY" | "BIWEEKLY">("MONTHLY");
  const [planFilter, setPlanFilter] = useState<"ALL" | "ACTIVE" | "INACTIVE" | "ARCHIVED">("ALL");
  const [omittedPlanServiceCount, setOmittedPlanServiceCount] = useState(0);
  const [contractPlanId, setContractPlanId] = useState<string | null>(null);
  const [contractBody, setContractBody] = useState("");

  const editingPlan = props.plans.find((plan) => plan.id === editingPlanId) ?? null;
  const editingVersion = editingPlanId
    ? props.versions.find((version) => version.plan_id === editingPlanId) ?? null
    : null;

  function clearForm() {
    setSelected([]);
    setEditingPlanId(null);
    setOmittedPlanServiceCount(0);
    setBillingPeriod("MONTHLY");
    setFormKey((current) => current + 1);
  }

  function openPlanForm(planId: string | null = null) {
    setMessage("");
    setEditingPlanId(planId);
    setOmittedPlanServiceCount(0);

    if (!planId) {
      setSelected([]);
      setBillingPeriod("MONTHLY");
    } else {
      const version = props.versions.find((item) => item.plan_id === planId);
      if (!version) {
        setEditingPlanId(null);
        showManagerError("Não foi possível carregar a versão atual deste plano.");
        return;
      }

      const planServices = props.planServices.filter(
        (item) => item.plan_version_id === version.id,
      );
      const eligibleServiceIds = new Set(props.services.map((service) => service.id));
      const eligiblePlanServices = planServices.filter((item) =>
        eligibleServiceIds.has(item.service_id),
      );
      setSelected(eligiblePlanServices.map((item) => item.service_id));
      setOmittedPlanServiceCount(planServices.length - eligiblePlanServices.length);
      const period = version.billing_period === "BIWEEKLY" ? "BIWEEKLY" : "MONTHLY";
      setBillingPeriod(period);
    }

    setFormKey((current) => current + 1);
    setNewPlanOpen(true);
  }

  async function save(event: FormEvent<HTMLFormElement>) {
    event.preventDefault();
    const data = new FormData(event.currentTarget);
    if (!selected.length) {
      showManagerError("Selecione ao menos um serviço.");
      return;
    }
    const isEditing = editingPlanId !== null;
    const saved = await runMutation(
      setMessage,
      async () => {
        await assertResult(await connectedClient().rpc("save_subscription_plan", {
          p_organization_id: props.organizationId,
          p_plan_id: editingPlanId,
          p_name: String(data.get("name") ?? "").trim(),
          p_description: String(data.get("description") ?? "").trim(),
          p_price_cents: centsFromInput(data.get("price")),
          p_billing_period: String(data.get("billing_period")),
          p_duration_months: Number(data.get("duration_months")),
          p_sessions_per_cycle: Number(data.get("sessions_per_cycle")),
          p_payment_method: String(data.get("payment_method")),
          // The database trigger stores new versions as UNCONFIGURED until enrollment returns.
          p_scheduling_mode: "FREE",
          p_fixed_schedule_cadence_weeks: null,
          p_fixed_schedule_pattern: null,
          p_cancellation_policy: editingVersion?.cancellation_policy ?? defaultCancellationPolicy,
          p_session_cancellation_policy: editingVersion?.session_cancellation_policy ?? defaultSessionCancellationPolicy,
          p_services: selected.map((service_id, position) => ({ service_id, position })),
        }));
      },
      isEditing ? "Plano atualizado." : "Plano criado.",
    );

    if (saved) {
      clearForm();
      setNewPlanOpen(false);
      router.refresh();
    }
  }

  async function archivePlan(plan: Plan) {
    if (!window.confirm(`Arquivar "${plan.name}"? Assinaturas existentes serão mantidas, mas novas adesões não poderão usar este plano.`)) return;

    const archived = await runMutation(
      setMessage,
      async () => {
        await assertResult(await connectedClient().rpc("archive_subscription_plan", {
          p_organization_id: props.organizationId,
          p_plan_id: plan.id,
        }));
      },
      "Plano arquivado. Novas adesões não poderão escolhê-lo.",
    );
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

  function priceInputValue(version: PlanVersion | null) {
    return version ? (version.price_cents / 100).toFixed(2).replace(".", ",") : "";
  }

  const visiblePlans = props.plans.filter((plan) => planFilter === "ALL"
    || (planFilter === "ARCHIVED" ? plan.archived_at !== null : plan.archived_at === null && (planFilter === "ACTIVE" ? plan.active : !plan.active)));
  return <div className={styles.stack}>
    <PageHeader title="Planos de Assinatura" description="Crie planos compostos por serviços. Pacotes não entram na composição da assinatura na V1." />
    <ActionMessage message={message} />
    {!props.subscriptionModuleEnabled && <div className={styles.notice}>Planos de Assinatura está inativo em Configurações → Módulos. Assinaturas existentes continuam; novas adesões e novos planos ficam bloqueados.</div>}
    {props.subscriptionModuleEnabled && <div className={styles.notice}>Novas adesões estão temporariamente pausadas enquanto o agendamento de assinaturas é reestruturado. Assinaturas existentes continuam disponíveis.</div>}
    <Panel title="Planos cadastrados" description={`${visiblePlans.length} de ${props.plans.length} planos`} action={<button className={styles.button} type="button" disabled={!props.subscriptionModuleEnabled} onClick={() => openPlanForm()}>Novo plano</button>}>
      <div className={styles.subscriptionPlanFilters} role="group" aria-label="Filtrar planos">
        {([["ALL", "Todos"], ["ACTIVE", "Ativos"], ["INACTIVE", "Inativos"], ["ARCHIVED", "Arquivados"]] as const).map(([value, label]) => <button key={value} type="button" className={`${styles.button} ${styles.buttonSoft} ${planFilter === value ? styles.subscriptionPlanFilterSelected : ""}`} aria-pressed={planFilter === value} onClick={() => setPlanFilter(value)}>{label}</button>)}
      </div>
      <div className={styles.list}>{visiblePlans.map((plan) => {
        const version = props.versions.find((item) => item.plan_id === plan.id);
        const editingContract = contractPlanId === plan.id;
        const archived = plan.archived_at !== null;
        return <article className={`${styles.row} ${styles.subscriptionPlanRow}`} key={plan.id}>
          <span className={styles.rowTitle}><strong>{plan.name}</strong><small>{plan.description || "Sem descrição"}</small></span>
          <strong>{version ? formatCents(version.price_cents) : "—"}</strong>
          <span>{version?.billing_period === "BIWEEKLY" ? "Quinzenal" : "Mensal"}</span>
          <span>{version ? `${version.sessions_per_cycle} sessão(ões) por ciclo` : "—"}</span>
          <div className={`${styles.rowActions} ${styles.subscriptionPlanActions}`}>
            <StatusChip active={!archived && plan.active} label={archived ? "ARQUIVADO" : plan.active ? "ATIVO" : "INATIVO"} />
            {!archived && <>
              <button type="button" className={`${styles.button} ${styles.buttonSoft} ${styles.buttonSmall}`} disabled={!props.subscriptionModuleEnabled} onClick={() => openPlanForm(plan.id)}>Editar</button>
              <button type="button" className={`${styles.button} ${styles.buttonSoft} ${styles.subscriptionPlanArchive}`} aria-label={`Arquivar plano ${plan.name}`} title="Arquivar plano" onClick={() => void archivePlan(plan)}><Archive size={17} aria-hidden="true" /></button>
            </>}
            <button type="button" className={`${styles.button} ${styles.buttonSoft} ${styles.buttonSmall}`} disabled={!props.subscriptionModuleEnabled} aria-expanded={editingContract} onClick={() => { setContractPlanId(editingContract ? null : plan.id); setContractBody(plan.contract_body_override ?? ""); }}>{editingContract ? "Fechar contrato" : "Editar contrato"}</button>
          </div>
          {editingContract && <div className={`${styles.formWide} ${styles.subscriptionPlanContractEditor}`}><textarea value={contractBody} onChange={(event) => setContractBody(event.target.value)} minLength={20} rows={6} placeholder="Contrato específico deste plano. Deixe vazio para usar o contrato padrão." /><div className={styles.toolbarGroup}><button type="button" className={styles.button} onClick={() => void saveContract(plan.id)}>Salvar contrato</button><small className={styles.muted}>Adesões futuras usam este texto; contratos já aceitos permanecem congelados.</small></div></div>}
        </article>;
      })}</div>
    </Panel>
    {newPlanOpen && <div className={styles.modalLayer} role="presentation"><button className={styles.modalBackdrop} type="button" aria-label="Fechar cadastro de plano" onClick={() => { clearForm(); setNewPlanOpen(false); setMessage(""); }} /><form key={formKey} className={`${styles.modal} ${styles.modalWide} ${styles.subscriptionPlanModal}`} role="dialog" aria-modal="true" aria-labelledby="new-subscription-plan-title" onSubmit={save}><header className={styles.modalHeader}><div><small>{editingPlan ? "Edição de plano" : "Cadastro de planos"}</small><h2 id="new-subscription-plan-title">{editingPlan ? "Editar plano" : "Novo plano"}</h2></div><button className={styles.modalClose} type="button" aria-label="Fechar" onClick={() => { clearForm(); setNewPlanOpen(false); setMessage(""); }}><X size={19} /></button></header><div className={styles.form}>
        <Field label="Nome"><input name="name" defaultValue={editingPlan?.name ?? ""} required minLength={2} /></Field>
        <Field label="Valor do ciclo (R$)"><input name="price" defaultValue={priceInputValue(editingVersion)} required inputMode="decimal" /></Field>
        <div className={`${styles.formWide} ${styles.formCompactRow}`}>
          <Field label="Periodicidade"><select name="billing_period" value={billingPeriod} onChange={(event) => {
            const period = event.target.value === "BIWEEKLY" ? "BIWEEKLY" : "MONTHLY";
            setBillingPeriod(period);
          }}><option value="MONTHLY">Mensal</option><option value="BIWEEKLY">Quinzenal (15 dias)</option></select></Field>
          <Field label="Duração (meses)"><input name="duration_months" type="number" min={1} max={120} defaultValue={editingVersion?.duration_months ?? 1} required /></Field>
          <Field label="Sessões por Período"><input name="sessions_per_cycle" type="number" min={1} max={100} defaultValue={editingVersion?.sessions_per_cycle ?? 2} required /></Field>
        </div>
        <Field label="Forma de pagamento"><select name="payment_method" defaultValue={editingVersion?.payment_method ?? "CARD"}><option value="CARD">Cartão de crédito (registro manual)</option><option value="PIX">PIX (registro manual)</option><option value="BOLETO">Boleto (registro manual)</option><option value="CASH">Dinheiro</option><option value="UPFRONT">À vista</option><option value="ONLINE">Link de pagamento (registro manual)</option></select></Field>
        <Field label="Descrição" wide><textarea name="description" defaultValue={editingPlan?.description ?? ""} /></Field>
        <div className={styles.formWide}><span className={styles.muted}>Serviços da sessão (combo completo)</span><div className={styles.inlineMeta}>{props.services.map((service) => <label className={styles.check} key={service.id}><input type="checkbox" checked={selected.includes(service.id)} onChange={(event) => setSelected((current) => event.target.checked ? [...current, service.id] : current.filter((id) => id !== service.id))} />{service.name} · {formatCents(service.price_cents)}</label>)}</div>{omittedPlanServiceCount > 0 && <small className={styles.muted} role="status">{omittedPlanServiceCount} serviço(s) da versão atual não está(ão) mais ativo(s) ou elegível(is) para assinatura e não entrará(ão) na nova versão.</small>}</div>
        <div className={`${styles.toolbarGroup} ${styles.formWide}`}>
          <button className={`${styles.button} ${styles.buttonSoft}`} type="button" onClick={() => { clearForm(); setNewPlanOpen(false); setMessage(""); }}>Cancelar</button>
          <button className={styles.button} type="submit" disabled={!props.services.length}>{editingPlan ? "Salvar alterações" : "Criar plano"}</button>
        </div>
      </div></form></div>}
  </div>;
}
