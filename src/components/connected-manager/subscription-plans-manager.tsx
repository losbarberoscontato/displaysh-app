"use client";

import Link from "next/link";
import { useRouter } from "next/navigation";
import { useState, type FormEvent } from "react";
import { Archive, ArrowLeft, X } from "lucide-react";
import { PageHeader } from "@/components/ui";
import type { loadSubscriptionPlansData } from "./server";
import type { AwaitedReturn } from "./utility-types";
import { ActionMessage, Field, Panel, StatusChip } from "./shared";
import { assertResult, connectedClient, runMutation } from "./mutation-utils";
import { centsFromInput, formatCents } from "./format";
import styles from "./connected-manager.module.css";
import { showManagerError } from "@/components/manager-error-dialog";
import { FIXED_SCHEDULE_PATTERNS, fixedSchedulePattern, fixedSchedulePatternLabel, type FixedSchedulePattern } from "@/lib/subscription-plan-frequency";

type Props = AwaitedReturn<typeof loadSubscriptionPlansData>;
type Plan = Props["plans"][number];
type PlanVersion = Props["versions"][number];

export function SubscriptionPlansManager(props: Props) {
  const router = useRouter();
  const [message, setMessage] = useState("");
  const [selected, setSelected] = useState<string[]>([]);
  const [formKey, setFormKey] = useState(0);
  const [newPlanOpen, setNewPlanOpen] = useState(false);
  const [editingPlanId, setEditingPlanId] = useState<string | null>(null);
  const [schedulingMode, setSchedulingMode] = useState<"FREE" | "FIXED">("FREE");
  const [billingPeriod, setBillingPeriod] = useState<"MONTHLY" | "BIWEEKLY">("MONTHLY");
  const [fixedPattern, setFixedPattern] = useState<FixedSchedulePattern>("CYCLE_1");
  const [planFilter, setPlanFilter] = useState<"ALL" | "ACTIVE" | "INACTIVE" | "ARCHIVED">("ALL");
  const [frequencyConfirmed, setFrequencyConfirmed] = useState(false);
  const [frequencyDialogOpen, setFrequencyDialogOpen] = useState(false);
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
    setSchedulingMode("FREE");
    setBillingPeriod("MONTHLY");
    setFixedPattern("CYCLE_1");
    setFrequencyConfirmed(false);
    setFrequencyDialogOpen(false);
    setFormKey((current) => current + 1);
  }

  function openPlanForm(planId: string | null = null) {
    setMessage("");
    setEditingPlanId(planId);
    setOmittedPlanServiceCount(0);

    if (!planId) {
      setSelected([]);
      setSchedulingMode("FREE");
      setBillingPeriod("MONTHLY");
      setFixedPattern("CYCLE_1");
      setFrequencyConfirmed(false);
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
      const mode = version.scheduling_mode === "FIXED" ? "FIXED" : "FREE";
      setSchedulingMode(mode);
      const period = version.billing_period === "BIWEEKLY" ? "BIWEEKLY" : "MONTHLY";
      setBillingPeriod(period);
      const legacyPattern = version.sessions_per_cycle === 1 ? "CYCLE_1" : version.sessions_per_cycle === 2 ? "CYCLE_2" : version.sessions_per_cycle === 8 ? "WEEKLY_2" : version.sessions_per_cycle === 12 ? "WEEKLY_3" : version.sessions_per_cycle === 20 ? "WEEKDAYS" : version.sessions_per_cycle === 24 ? "MON_SAT" : "WEEKLY_1";
      const configuredPattern = fixedSchedulePattern(version.fixed_schedule_pattern) ?? fixedSchedulePattern(legacyPattern)!;
      setFixedPattern(configuredPattern.monthlyOnly && period === "BIWEEKLY" ? "CYCLE_1" : configuredPattern.value);
      setFrequencyConfirmed(mode === "FIXED");
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
    if (schedulingMode === "FIXED" && !frequencyConfirmed) {
      setFrequencyDialogOpen(true);
      showManagerError("Escolha a frequência das sessões fixas antes de salvar o plano.");
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
          p_sessions_per_cycle: schedulingMode === "FIXED" ? fixedSchedulePattern(fixedPattern)?.sessions ?? 1 : Number(data.get("sessions_per_cycle")),
          p_payment_method: String(data.get("payment_method")),
          p_scheduling_mode: schedulingMode,
          p_fixed_schedule_cadence_weeks: schedulingMode === "FIXED" ? 1 : null,
          p_fixed_schedule_pattern: schedulingMode === "FIXED" ? fixedPattern : null,
          p_cancellation_policy: String(data.get("cancellation_policy") ?? "").trim(),
          p_session_cancellation_policy: String(data.get("session_cancellation_policy") ?? "").trim(),
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
  const fixedPatternOptions = FIXED_SCHEDULE_PATTERNS.filter((pattern) => !pattern.monthlyOnly || billingPeriod === "MONTHLY");
  const activeFixedPattern = fixedSchedulePattern(fixedPattern);

  return <div className={styles.stack}>
    <PageHeader title="Planos de Assinatura" description="Crie planos compostos por serviços. Pacotes não entram na composição da assinatura na V1." />
    <Link className={styles.backLink} href="/gestor/catalogo"><ArrowLeft size={16} aria-hidden="true" /> Voltar para serviços</Link>
    <ActionMessage message={message} />
    {!props.subscriptionModuleEnabled && <div className={styles.notice}>Planos de Assinatura está inativo em Configurações → Módulos. Assinaturas existentes continuam; novas adesões e novos planos ficam bloqueados.</div>}
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
          <span>{version?.scheduling_mode === "FIXED" ? `Agendamento fixo · ${fixedSchedulePatternLabel(version.fixed_schedule_pattern)}` : "Agendamento livre"}</span>
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
            if (period === "BIWEEKLY" && fixedSchedulePattern(fixedPattern)?.monthlyOnly) setFixedPattern("CYCLE_1");
          }}><option value="MONTHLY">Mensal</option><option value="BIWEEKLY">Quinzenal (15 dias)</option></select></Field>
          <Field label="Duração (meses)"><input name="duration_months" type="number" min={1} max={120} defaultValue={editingVersion?.duration_months ?? 1} required /></Field>
          {schedulingMode === "FREE" ? <Field label="Sessões por Período"><input name="sessions_per_cycle" type="number" min={1} max={100} defaultValue={editingVersion?.sessions_per_cycle ?? 2} required /></Field> : <Field label="Sessões por Período"><select value={fixedPattern} onChange={(event) => setFixedPattern(event.target.value as FixedSchedulePattern)}>{fixedPatternOptions.map((option) => <option key={option.value} value={option.value}>{option.label}</option>)}</select></Field>}
        </div>
        <Field label="Forma de pagamento"><select name="payment_method" defaultValue={editingVersion?.payment_method ?? "CARD"}><option value="CARD">Cartão de crédito (registro manual)</option><option value="PIX">PIX (registro manual)</option><option value="BOLETO">Boleto (registro manual)</option><option value="CASH">Dinheiro</option><option value="UPFRONT">À vista</option><option value="ONLINE">Link de pagamento (registro manual)</option></select></Field>
        <Field label="Forma de agendamento"><select name="scheduling_mode" value={schedulingMode} onChange={(event) => {
          const mode = event.target.value === "FIXED" ? "FIXED" : "FREE";
          setSchedulingMode(mode);
          if (mode === "FIXED") {
            setFrequencyConfirmed(false);
            setFrequencyDialogOpen(true);
          } else {
            setFrequencyConfirmed(false);
          }
        }}><option value="FREE">Livre</option><option value="FIXED">Fixo</option></select></Field>
        <div className={`${styles.formWide} ${styles.notice}`}>
          {schedulingMode === "FIXED" ? <>
            <strong>{frequencyConfirmed ? activeFixedPattern?.label : "Frequência a definir"}</strong>
            <span>{activeFixedPattern?.detail ?? "Escolha quantas sessões se repetem no ciclo."}</span>
            <button className={`${styles.button} ${styles.buttonSoft} ${styles.buttonSmall}`} type="button" onClick={() => setFrequencyDialogOpen(true)}>Configurar sessões</button>
          </> : <>
            <strong>Agendamento livre</strong>
            <span>O cliente escolhe as sessões no app, ou o gestor informa manualmente as datas de cada ciclo.</span>
          </>}
        </div>
        <Field label="Descrição" wide><textarea name="description" defaultValue={editingPlan?.description ?? ""} /></Field>
        <Field label="Regra de cancelamento" wide><textarea name="cancellation_policy" required defaultValue={editingVersion?.cancellation_policy ?? "Cancelamento encerra no fim do ciclo pago; ciclos futuros são cancelados sem renovação automática."} /></Field>
        <Field label="Política de cancelamento de sessão" wide><textarea name="session_cancellation_policy" required defaultValue={editingVersion?.session_cancellation_policy ?? "Cancelamento dentro do prazo devolve a sessão. Cancelamento tardio ou no-show consome a sessão, sem cobrança adicional."} /></Field>
        <div className={styles.formWide}><span className={styles.muted}>Serviços da sessão (combo completo)</span><div className={styles.inlineMeta}>{props.services.map((service) => <label className={styles.check} key={service.id}><input type="checkbox" checked={selected.includes(service.id)} onChange={(event) => setSelected((current) => event.target.checked ? [...current, service.id] : current.filter((id) => id !== service.id))} />{service.name} · {formatCents(service.price_cents)}</label>)}</div>{omittedPlanServiceCount > 0 && <small className={styles.muted} role="status">{omittedPlanServiceCount} serviço(s) da versão atual não está(ão) mais ativo(s) ou elegível(is) para assinatura e não entrará(ão) na nova versão.</small>}</div>
        <div className={`${styles.toolbarGroup} ${styles.formWide}`}>
          <button className={`${styles.button} ${styles.buttonSoft}`} type="button" onClick={() => { clearForm(); setNewPlanOpen(false); setMessage(""); }}>Cancelar</button>
          <button className={styles.button} type="submit" disabled={!props.services.length}>{editingPlan ? "Salvar alterações" : "Criar plano"}</button>
        </div>
      </div></form></div>}
    {newPlanOpen && frequencyDialogOpen && <div className={styles.modalLayer} style={{ zIndex: 60 }} role="presentation"><button className={styles.modalBackdrop} type="button" aria-label="Fechar escolha de frequência" onClick={() => setFrequencyDialogOpen(false)} /><section className={styles.modal} role="dialog" aria-modal="true" aria-labelledby="plan-frequency-title"><header className={styles.modalHeader}><div><small>Agendamento fixo</small><h2 id="plan-frequency-title">Sessões por Período</h2></div><button className={styles.modalClose} type="button" aria-label="Fechar" onClick={() => setFrequencyDialogOpen(false)}><X size={19} /></button></header><p>Quinzenal permite 1 ou 2 sessões por ciclo. As demais frequências valem para ciclos mensais; semanas extras entram no preço do ciclo.</p><div className={styles.toolbarGroup}>{fixedPatternOptions.map((option) => <button key={option.value} className={`${styles.button} ${styles.buttonSoft}`} type="button" aria-pressed={fixedPattern === option.value} onClick={() => { setFixedPattern(option.value); setFrequencyConfirmed(true); setFrequencyDialogOpen(false); }}><strong>{option.label}</strong><span>{option.detail}</span></button>)}</div><div className={styles.toolbarGroup}><button className={`${styles.button} ${styles.buttonSoft}`} type="button" onClick={() => setFrequencyDialogOpen(false)}>Voltar ao plano</button></div></section></div>}
  </div>;
}
