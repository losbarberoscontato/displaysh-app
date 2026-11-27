"use client";

import Link from "next/link";
import { useCallback, useEffect, useMemo, useRef, useState, type FormEvent } from "react";
import { useRouter } from "next/navigation";
import { CalendarClock, ChevronRight, Plus, Trash2 } from "lucide-react";
import { getSupabaseBrowserClient } from "@/lib/supabase/browser";
import { localDateTimeToIso } from "@/components/connected-manager/format";
import type { BarberAppContext } from "./types";
import styles from "./barber.module.css";

type Interval = { id: string; weekday: number; starts_at: string; ends_at: string; environment_id: string | null };
type AvailableSlot = { starts_at: string; ends_at: string };
type Environment = { id: string; name: string; location_id: string };
type Exception = { id: string; kind: "UNAVAILABLE" | "AVAILABLE_OVERRIDE"; service_period: string; reason: string | null };
type ChangeMessage = { id: string; message: string; created_at: string; details: { actor_role?: string } };
type ScheduleData = { barber_id: string; timezone: string; intervals: Interval[]; environments: Environment[]; exceptions: Exception[]; messages: ChangeMessage[] };
export type ScheduleSection = "overview" | "folgas" | "historico" | "nova-folga";

function scheduleMutationError(message: string) {
  if (/future appointments|cannot be changed|cannot be blocked/i.test(message)) return "Há um atendimento agendado nesse horário. Reagende ou cancele antes de alterar a escala.";
  if (/no active agenda environment|select an active agenda environment/i.test(message)) return "Escolha um ambiente ativo para esta escala.";
  if (/environment already has a work interval/i.test(message)) return "Este horário acabou de ser ocupado por outro profissional nesta sala. Escolha outro horário disponível.";
  if (/barber already has a work interval/i.test(message)) return "Você já possui um horário cadastrado neste período.";
  return message;
}

const weekdays = [
  { day: 1, label: "Segunda-feira" }, { day: 2, label: "Terça-feira" },
  { day: 3, label: "Quarta-feira" }, { day: 4, label: "Quinta-feira" },
  { day: 5, label: "Sexta-feira" }, { day: 6, label: "Sábado" }, { day: 0, label: "Domingo" },
];

function dateTimeDefault(date: Date, timezone: string) {
  const parts = new Intl.DateTimeFormat("en-CA", { timeZone: timezone, year: "numeric", month: "2-digit", day: "2-digit", hour: "2-digit", minute: "2-digit", hourCycle: "h23" }).formatToParts(date);
  const values = Object.fromEntries(parts.map((part) => [part.type, part.value]));
  return `${values.year}-${values.month}-${values.day}T${values.hour}:${values.minute}`;
}

function displayPeriod(period: string, timezone: string) {
  const [start, end] = period.slice(1, -1).split(",").map((value) => new Date(value.trim().replace(/^"|"$/g, "")));
  if (!start || !end || Number.isNaN(start.getTime()) || Number.isNaN(end.getTime())) return "Período indisponível";
  const formatter = new Intl.DateTimeFormat("pt-BR", { timeZone: timezone, dateStyle: "short", timeStyle: "short" });
  return `${formatter.format(start)} – ${formatter.format(end)}`;
}

export function BarberSchedule({ context, section = "overview" }: { context: BarberAppContext; section?: ScheduleSection }) {
  const router = useRouter();
  const [schedule, setSchedule] = useState<ScheduleData | null>(null);
  const [loading, setLoading] = useState(true);
  const [saving, setSaving] = useState(false);
  const [message, setMessage] = useState("");
  const [scheduleWarning, setScheduleWarning] = useState("");
  const [pendingDelete, setPendingDelete] = useState<Interval | null>(null);
  const [expandedDay, setExpandedDay] = useState<number | null>(null);
  const [editorDay, setEditorDay] = useState<number | null>(null);
  const [availableSlots, setAvailableSlots] = useState<AvailableSlot[]>([]);
  const [loadingSlots, setLoadingSlots] = useState(false);
  const [selectedSlots, setSelectedSlots] = useState<string[]>([]);
  const slotRequestId = useRef(0);
  const batchRequestId = useRef<string | null>(null);
  const [environmentId, setEnvironmentId] = useState("");
  const [exceptionStart, setExceptionStart] = useState("");
  const [exceptionEnd, setExceptionEnd] = useState("");

  const query = useMemo(() => `?barbearia=${encodeURIComponent(context.organization_slug)}`, [context.organization_slug]);
  const baseHref = `/barbeiro/escala${query}`;
  const sectionHref = (target: "folgas" | "historico" | "nova-folga") => `/barbeiro/escala/${target}${query}`;
  const load = useCallback(async (initializeDefaults = false) => {
    const supabase = getSupabaseBrowserClient();
    if (!supabase) { setMessage("Supabase indisponível."); setLoading(false); return; }
    const { data, error } = await supabase.rpc("get_my_barber_schedule", { p_organization_id: context.organization_id });
    if (error) setMessage(error.message);
    else if (data && typeof data === "object") {
      const result = data as ScheduleData;
      setSchedule(result);
      if (initializeDefaults) {
        const start = new Date(Date.now() + 60 * 60 * 1000);
        const end = new Date(Date.now() + 2 * 60 * 60 * 1000);
        setExceptionStart(dateTimeDefault(start, result.timezone));
        setExceptionEnd(dateTimeDefault(end, result.timezone));
        setEnvironmentId(result.environments[0]?.id ?? "");
      }
    }
    setLoading(false);
  }, [context.organization_id]);
  useEffect(() => { void Promise.resolve().then(() => load(true)); }, [load]);

  async function refreshSlots(day: number, selectedEnvironmentId: string) {
    const requestId = ++slotRequestId.current;
    if (!selectedEnvironmentId) {
      setAvailableSlots([]);
      setSelectedSlots([]);
      setLoadingSlots(false);
      return;
    }
    setLoadingSlots(true);
    setMessage("");
    const supabase = getSupabaseBrowserClient();
    if (!supabase) {
      setAvailableSlots([]);
      setLoadingSlots(false);
      setMessage("Supabase indisponível.");
      return;
    }
    const { data, error } = await supabase.rpc("get_my_barber_available_schedule_slots", {
      p_organization_id: context.organization_id,
      p_weekday: day,
      p_environment_id: selectedEnvironmentId,
    });
    if (requestId !== slotRequestId.current) return;
    if (error) {
      setAvailableSlots([]);
      setMessage(error.message);
    } else {
      const result = Array.isArray(data) ? data as AvailableSlot[] : [];
      setAvailableSlots(result);
      setSelectedSlots((current) => current.filter((start) => result.some((slot) => slot.starts_at.slice(0, 5) === start)));
    }
    setLoadingSlots(false);
  }

  async function mutate(action: string, input: Record<string, unknown> = {}) {
    const supabase = getSupabaseBrowserClient();
    if (!supabase) throw new Error("Supabase indisponível.");
    const { data, error } = await supabase.rpc("mutate_barber_schedule", { p_organization_id: context.organization_id, p_barber_id: context.barber_id, p_action: action, ...input });
    if (error) throw new Error(scheduleMutationError(error.message));
    const responseMessage = data && typeof data === "object" && "message" in data && typeof data.message === "string" ? data.message : "Alteração salva e registrada.";
    setMessage(responseMessage);
    await load();
    router.refresh();
  }

  function openAdd(day: number) {
    batchRequestId.current = null;
    setEditorDay(day);
    setEnvironmentId("");
    setSelectedSlots([]);
    void refreshSlots(day, "");
  }

  function closeIntervalEditor() {
    batchRequestId.current = null;
    slotRequestId.current += 1;
    setEditorDay(null);
    setSelectedSlots([]);
    setAvailableSlots([]);
    setLoadingSlots(false);
  }

  async function saveIntervals(event: FormEvent<HTMLFormElement>) {
    event.preventDefault();
    if (editorDay === null) return;
    const slots = availableSlots.filter((slot) => selectedSlots.includes(slot.starts_at.slice(0, 5)));
    if (!slots.length || slots.length !== selectedSlots.length) {
      setMessage("Selecione um ou mais horários ainda disponíveis para esta sala.");
      return;
    }
    setSaving(true);
    setMessage("");
    try {
      const supabase = getSupabaseBrowserClient();
      if (!supabase) throw new Error("Supabase indisponível.");
      const requestId = batchRequestId.current ?? crypto.randomUUID();
      batchRequestId.current = requestId;
      const { data, error } = await supabase.rpc("add_my_barber_schedule_intervals", {
        p_organization_id: context.organization_id,
        p_barber_id: context.barber_id,
        p_weekday: editorDay,
        p_environment_id: environmentId,
        p_start_times: slots.map((slot) => slot.starts_at.slice(0, 5)),
        p_request_id: requestId,
      });
      if (error) throw new Error(scheduleMutationError(error.message));
      const result = data && typeof data === "object" ? data as { message?: unknown } : null;
      setMessage(typeof result?.message === "string" ? result.message : `${slots.length} horários adicionados à escala.`);
      batchRequestId.current = null;
      closeIntervalEditor();
      await load();
      router.refresh();
    } catch (error) {
      setMessage(error instanceof Error ? error.message : "Não foi possível salvar o horário.");
    } finally {
      setSaving(false);
    }
  }

  async function saveException(event: FormEvent<HTMLFormElement>) {
    event.preventDefault();
    const form = new FormData(event.currentTarget);
    setSaving(true);
    setMessage("");
    try {
      await mutate("ADD_EXCEPTION", {
        p_exception_start: localDateTimeToIso(exceptionStart, context.timezone),
        p_exception_end: localDateTimeToIso(exceptionEnd, context.timezone),
        p_reason: String(form.get("reason") ?? "").trim() || null,
        p_exception_kind: "UNAVAILABLE",
      });
      router.push(sectionHref("folgas"));
    } catch (error) {
      setMessage(error instanceof Error ? error.message : "Não foi possível registrar a folga.");
    } finally {
      setSaving(false);
    }
  }

  async function remove(action: "DELETE_INTERVAL" | "DELETE_EXCEPTION", id: string) {
    if (saving) return;
    setSaving(true);
    setMessage("");
    try {
      await mutate(action, action === "DELETE_INTERVAL" ? { p_interval_id: id } : { p_exception_id: id });
    } catch (error) {
      const details = error instanceof Error ? error.message : "Não foi possível excluir o item.";
      if (action === "DELETE_INTERVAL" && /não é possível remover/i.test(details)) setScheduleWarning(details);
      else setMessage(details);
    } finally {
      setSaving(false);
    }
  }

  const intervals = schedule?.intervals ?? [];
  const environments = schedule?.environments ?? [];
  const exceptions = schedule?.exceptions ?? [];
  const changes = schedule?.messages ?? [];
  const pageTitle = section === "folgas" ? "Folgas e exceções" : section === "historico" ? "Histórico da escala" : section === "nova-folga" ? "Adicionar folga ou exceção" : "Escala";
  const backHref = baseHref;

  return <>
    <section className={styles.hero}>
      <div>
        <h1 className={styles.title}>{pageTitle}</h1>
        {section !== "overview" && <Link className={styles.switcher} href={backHref}>← Voltar para Escala</Link>}
      </div>
    </section>
    {message && <p className={styles.notice} role="status">{message}</p>}
    {loading ? <section className={styles.card}>Carregando sua escala…</section> : <>
      {section === "overview" && <>
        <section className={styles.card}>
          <h2>Horários semanais</h2>
          <p className={styles.muted}>Horários com atendimentos agendados não podem ser removidos.</p>
          <div className={styles.scheduleAccordion}>
            {weekdays.map(({ day, label }) => {
              const items = intervals.filter((item) => item.weekday === day).sort((a, b) => a.starts_at.localeCompare(b.starts_at));
              const expanded = expandedDay === day;
              return <article className={styles.scheduleAccordionItem} key={day}>
                <button type="button" className={styles.scheduleAccordionTrigger} aria-expanded={expanded} onClick={() => { setExpandedDay(expanded ? null : day); closeIntervalEditor(); }}>
                  <span><strong>{label}</strong><small>{items.length ? `${items.length} ${items.length === 1 ? "horário" : "horários"}` : "Sem horário cadastrado"}</small></span>
                  <ChevronRight size={20} aria-hidden="true" />
                </button>
                {expanded && <div className={styles.scheduleAccordionBody}>
                  {editorDay === day ? <form className={`${styles.scheduleIntervalForm} ${styles.form}`} onSubmit={(event) => void saveIntervals(event)}>
                    <h3>{`Adicionar horários · ${label}`}</h3>
                    <div className={`${styles.scheduleFormGrid} ${styles.scheduleSlotFields}`}>
                      <label>Ambiente<select required value={environmentId} onChange={(event) => { const nextEnvironmentId = event.target.value; setEnvironmentId(nextEnvironmentId); setSelectedSlots([]); batchRequestId.current = null; if (editorDay !== null) void refreshSlots(editorDay, nextEnvironmentId); }}><option value="">Selecione primeiro o ambiente</option>{environments.map((environment) => <option value={environment.id} key={environment.id}>{environment.name}</option>)}</select></label>
                      <div className={styles.scheduleSlotPicker}>
                        <p id={`schedule-slot-label-${day}`} className={styles.scheduleSlotPickerTitle}>Horários disponíveis <small>(marque um ou mais)</small></p>
                        {!environmentId ? <p className={styles.muted}>Selecione primeiro um ambiente.</p> : loadingSlots ? <p className={styles.muted}>Buscando horários…</p> : availableSlots.length ? <div className={styles.scheduleSlotOptions} role="group" aria-labelledby={`schedule-slot-label-${day}`}>
                          {availableSlots.map((slot) => {
                            const start = slot.starts_at.slice(0, 5);
                            const intervalLabel = `${start}–${slot.ends_at.slice(0, 5)}`;
                            return <label className={`${styles.scheduleSlotOption} ${selectedSlots.includes(start) ? styles.scheduleSlotOptionSelected : ""}`} key={start}>
                              <input type="checkbox" checked={selectedSlots.includes(start)} disabled={saving} onChange={(event) => { const checked = event.currentTarget.checked; batchRequestId.current = null; setSelectedSlots((current) => checked ? [...current, start] : current.filter((value) => value !== start)); }} />
                              <span>{intervalLabel}</span>
                            </label>;
                          })}
                        </div> : <p className={styles.muted}>Não há blocos de uma hora livres nesta sala para este dia.</p>}
                      </div>
                    </div>
                    {!environments.length && <p className={styles.muted}>Não há ambientes ativos disponíveis para esta unidade.</p>}
                    <div className={styles.formActions}>
                      <button className={`${styles.button} ${styles.secondary}`} type="button" disabled={saving} onClick={closeIntervalEditor}>Cancelar</button>
                      <button className={styles.button} disabled={saving || loadingSlots || !environments.length || !environmentId || selectedSlots.length === 0}>{saving ? "Salvando…" : "Adicionar horários"}</button>
                    </div>
                  </form> : <button className={`${styles.button} ${styles.secondary} ${styles.scheduleAddButton}`} type="button" aria-label={`Adicionar horário para ${label}`} title="Adicionar horário" onClick={() => openAdd(day)}><Plus size={20} /></button>}
                  {items.length ? <div className={styles.scheduleTableWrap}>
                    <table className={styles.scheduleTable} aria-label={`Horários de ${label}`}>
                      <thead><tr><th scope="col">Horário</th><th scope="col">Ambiente</th><th scope="col" aria-label="Ações" /></tr></thead>
                      <tbody>{items.map((item) => {
                        const environment = environments.find((entry) => entry.id === item.environment_id);
                        const intervalLabel = `${item.starts_at.slice(0, 5)}–${item.ends_at.slice(0, 5)}`;
                        return <tr key={item.id}>
                          <td>{intervalLabel}</td>
                          <td>{environment?.name ?? "Não identificado"}</td>
                          <td><div className={styles.scheduleTableActions}>
                            <button className={`${styles.button} ${styles.scheduleIconButton} ${styles.scheduleDeleteButton}`} type="button" aria-label={`Excluir horário ${intervalLabel}`} title="Excluir horário" disabled={saving} onClick={() => setPendingDelete(item)}><Trash2 size={17} /></button>
                          </div></td>
                        </tr>;
                      })}</tbody>
                    </table>
                  </div> : <p className={styles.muted}>Nenhum horário cadastrado para este dia.</p>}
                </div>}
              </article>;
            })}
          </div>
        </section>
        <div className={styles.scheduleShortcuts}>
          <Link className={`${styles.card} ${styles.scheduleShortcut}`} href={sectionHref("nova-folga")}><span><CalendarClock size={19} /><strong>Adicionar folga ou exceção</strong><small>Cadastrar uma data e horário indisponível</small></span><ChevronRight size={19} /></Link>
          <Link className={`${styles.card} ${styles.scheduleShortcut}`} href={sectionHref("folgas")}><span><CalendarClock size={19} /><strong>Folgas e exceções cadastradas</strong><small>{exceptions.length ? `${exceptions.length} cadastradas` : "Consultar e remover períodos"}</small></span><ChevronRight size={19} /></Link>
          <Link className={`${styles.card} ${styles.scheduleShortcut}`} href={sectionHref("historico")}><span><CalendarClock size={19} /><strong>Histórico de alterações</strong><small>Ver quem alterou a escala e quando</small></span><ChevronRight size={19} /></Link>
        </div>
      </>}

      {section === "nova-folga" && <form className={`${styles.card} ${styles.form}`} onSubmit={(event) => void saveException(event)}>
        <div className={styles.scheduleFormGrid}>
          <label>Início<input type="datetime-local" required value={exceptionStart} onChange={(event) => setExceptionStart(event.target.value)} /></label>
          <label>Fim<input type="datetime-local" required value={exceptionEnd} onChange={(event) => setExceptionEnd(event.target.value)} /></label>
          <label className={styles.scheduleReason}>Motivo (opcional)<input name="reason" maxLength={240} /></label>
        </div>
        <div className={styles.formActions}><button className={styles.button} disabled={saving}><CalendarClock size={15} /> {saving ? "Salvando…" : "Salvar folga ou exceção"}</button></div>
      </form>}

      {section === "folgas" && <section className={styles.card}>
        <h2>Folgas e exceções cadastradas</h2>
        {exceptions.length ? <div className={styles.list}>{exceptions.map((item) => <article className={styles.row} key={item.id}><span><strong>{displayPeriod(item.service_period, schedule?.timezone ?? context.timezone)}</strong><small>{item.reason || (item.kind === "UNAVAILABLE" ? "Indisponibilidade" : "Horário especial")}</small></span><button className={`${styles.button} ${styles.dangerButton}`} type="button" disabled={saving} onClick={() => void remove("DELETE_EXCEPTION", item.id)}><Trash2 size={14} /> Remover</button></article>)}</div> : <p className={styles.muted}>Nenhuma folga futura cadastrada.</p>}
      </section>}

      {section === "historico" && <section className={styles.card}>
        <h2>Alterações recentes</h2>
        {changes.length ? <div className={styles.list}>{changes.map((item) => <article className={styles.scheduleChange} key={item.id}><strong>{item.message}</strong><small>{new Intl.DateTimeFormat("pt-BR", { dateStyle: "medium", timeStyle: "short", timeZone: schedule?.timezone ?? context.timezone }).format(new Date(item.created_at))}</small></article>)}</div> : <p className={styles.muted}>As alterações salvas aparecerão aqui com o responsável.</p>}
      </section>}
    </>}
    {scheduleWarning && <div className={styles.modal} role="presentation" onMouseDown={(event) => { if (event.target === event.currentTarget) setScheduleWarning(""); }}>
      <section className={styles.dialog} role="alertdialog" aria-modal="true" aria-labelledby="schedule-warning-title">
        <h2 id="schedule-warning-title">Horário não pode ser removido</h2>
        <p>{scheduleWarning}</p>
        <div className={styles.formActions}><button className={styles.button} type="button" onClick={() => setScheduleWarning("")}>Entendi</button></div>
      </section>
    </div>}
    {pendingDelete && <div className={styles.modal} role="presentation" onMouseDown={(event) => { if (event.target === event.currentTarget) setPendingDelete(null); }}>
      <section className={styles.dialog} role="alertdialog" aria-modal="true" aria-labelledby="schedule-delete-title" aria-describedby="schedule-delete-description">
        <h2 id="schedule-delete-title">Excluir horário?</h2>
        <p id="schedule-delete-description">Confirma excluir {weekdays.find((item) => item.day === pendingDelete.weekday)?.label.toLowerCase()} das {pendingDelete.starts_at.slice(0, 5)} às {pendingDelete.ends_at.slice(0, 5)}? Horários com atendimentos não podem ser removidos.</p>
        <div className={styles.formActions}>
          <button className={`${styles.button} ${styles.secondary}`} type="button" onClick={() => setPendingDelete(null)}>Cancelar</button>
          <button className={`${styles.button} ${styles.dangerButton}`} type="button" disabled={saving} onClick={() => { const item = pendingDelete; setPendingDelete(null); if (item) void remove("DELETE_INTERVAL", item.id); }}><Trash2 size={16} /> Excluir horário</button>
        </div>
      </section>
    </div>}
  </>;
}
