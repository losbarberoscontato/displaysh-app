"use client";

import { useEffect, useRef, useState, type FormEvent } from "react";
import { useRouter } from "next/navigation";
import Image from "next/image";
import Link from "next/link";
import { CalendarClock, Camera, UserRound } from "lucide-react";
import { normalizePhoneE164 } from "@/lib/phone";
import { getSupabaseBrowserClient } from "@/lib/supabase/browser";
import type { BarberAppContext } from "./types";
import styles from "./barber.module.css";

export function BarberProfile({ context }: { context: BarberAppContext }) {
  const query = `?barbearia=${encodeURIComponent(context.organization_slug)}`;
  return <>
    <section className={styles.hero}>
      <div>
        <h1 className={styles.title}>Meu Perfil</h1>
      </div>
    </section>
    <div className={styles.profileMenu}>
      <Link className={`${styles.card} ${styles.profileMenuItem}`} href={`/barbeiro/perfil/dados-pessoais${query}`}>
        <span><UserRound size={21} /><strong>Dados pessoais</strong><small>Foto, contato e apresentação</small></span>
        <span aria-hidden="true">›</span>
      </Link>
      <Link className={`${styles.card} ${styles.profileMenuItem}`} href={`/barbeiro/escala${query}`}>
        <span><CalendarClock size={21} /><strong>Escala</strong><small>Horários de trabalho, folgas e exceções</small></span>
        <span aria-hidden="true">›</span>
      </Link>
    </div>
    <BarberCalendarIntegration context={context} />
  </>;
}

function BarberCalendarIntegration({ context }: { context: BarberAppContext }) {
  const [message, setMessage] = useState("");
  const [calendar, setCalendar] = useState<{ google_account_email: string; status: string } | null>(null);
  const [connectingCalendar, setConnectingCalendar] = useState(false);
  const returnPath = `/barbeiro/perfil?barbearia=${encodeURIComponent(context.organization_slug)}`;

  useEffect(() => {
    const supabase = getSupabaseBrowserClient();
    if (!supabase) return;
    let active = true;
    void (async () => {
      const { data, error } = await supabase.from("google_calendar_connections")
        .select("google_account_email,status")
        .eq("organization_id", context.organization_id)
        .eq("target_type", "BARBER")
        .eq("barber_id", context.barber_id)
        .maybeSingle();
      if (!active) return;
      if (error) setMessage(error.message);
      else setCalendar(data);
    })();
    return () => { active = false; };
  }, [context.organization_id, context.barber_id]);

  async function connectGoogleCalendar() {
    setConnectingCalendar(true);
    setMessage("Abrindo autorização do Google Agenda…");
    try {
      const supabase = getSupabaseBrowserClient();
      if (!supabase) throw new Error("Supabase indisponível.");
      const { data, error } = await supabase.functions.invoke("google-calendar-oauth-start", {
        body: { organizationId: context.organization_id, targetType: "BARBER", barberId: context.barber_id, returnPath },
      });
      const authorizationUrl = data && typeof data === "object" && "authorizationUrl" in data ? data.authorizationUrl : null;
      if (error || typeof authorizationUrl !== "string") throw new Error(error?.message ?? "URL de autorização não recebida.");
      window.location.assign(authorizationUrl);
    } catch (error) {
      setConnectingCalendar(false);
      setMessage(error instanceof Error ? error.message : "Não foi possível abrir a conexão.");
    }
  }

  return <section className={styles.card} style={{ marginTop: 16 }}>
    <h2>Integração Google Agenda</h2>
    {calendar?.google_account_email && <p className={styles.muted}>{calendar.google_account_email} · agenda conectada.</p>}
    {message && <p className={styles.notice} role="status">{message}</p>}
    <button type="button" className={styles.button} disabled={connectingCalendar} onClick={() => void connectGoogleCalendar()}>
      {connectingCalendar ? "Abrindo…" : calendar?.status === "CONNECTED" ? "Reconectar Google Agenda" : "Conectar Google Agenda"}
    </button>
  </section>;
}

export function BarberPersonalData({ context }: { context: BarberAppContext }) {
  const router = useRouter();
  const input = useRef<HTMLInputElement>(null);
  const [message, setMessage] = useState("");
  const [avatarUrl, setAvatarUrl] = useState(context.barber_avatar_url);
  const [cropSource, setCropSource] = useState<{ url: string } | null>(null);
  const [savingPhoto, setSavingPhoto] = useState(false);

  useEffect(() => {
    if (!cropSource) return;
    return () => URL.revokeObjectURL(cropSource.url);
  }, [cropSource]);

  async function uploadPhoto(file: File) {
    if (!/^image\/(png|jpeg|webp)$/u.test(file.type) || file.size > 2 * 1024 * 1024) throw new Error("Use PNG, JPEG ou WebP de até 2 MB.");
    const supabase = getSupabaseBrowserClient();
    if (!supabase) throw new Error("Supabase indisponível.");
    const path = `${context.organization_id}/${context.barber_id}/${crypto.randomUUID()}.webp`;
    const { error } = await supabase.storage.from("barber-avatars").upload(path, file, { contentType: "image/webp", cacheControl: "31536000" });
    if (error) throw error;
    return { path, url: supabase.storage.from("barber-avatars").getPublicUrl(path).data.publicUrl };
  }

  function selectPhoto(file: File | undefined) {
    if (!file) return;
    if (!/^image\/(png|jpeg|webp)$/u.test(file.type)) {
      setMessage("Escolha uma foto no formato PNG, JPEG ou WebP.");
      return;
    }
    if (file.size > 10 * 1024 * 1024) {
      setMessage("Esta foto tem mais de 10 MB. Escolha uma imagem menor para continuar.");
      return;
    }
    setMessage("");
    setCropSource({ url: URL.createObjectURL(file) });
  }

  async function saveCroppedPhoto(file: File) {
    const supabase = getSupabaseBrowserClient();
    if (!supabase) throw new Error("Supabase indisponível.");
    setSavingPhoto(true);
    let uploadedPath: string | null = null;
    try {
      const uploaded = await uploadPhoto(file);
      uploadedPath = uploaded.path;
      const { error } = await supabase.rpc("update_my_barber_avatar", {
        p_organization_id: context.organization_id,
        p_avatar_url: uploaded.url,
      });
      if (error) throw error;
      setAvatarUrl(uploaded.url);
      setCropSource(null);
      setMessage("Foto de perfil atualizada.");
      router.refresh();
    } catch (error) {
      if (uploadedPath) await supabase.storage.from("barber-avatars").remove([uploadedPath]);
      throw error;
    } finally {
      setSavingPhoto(false);
    }
  }

  async function save(event: FormEvent<HTMLFormElement>) {
    event.preventDefault();
    const data = new FormData(event.currentTarget);
    const supabase = getSupabaseBrowserClient();
    try {
      const rawWhatsapp = String(data.get("whatsapp") ?? "").trim();
      const whatsapp = normalizePhoneE164(rawWhatsapp);
      if (rawWhatsapp && !whatsapp) throw new Error("Informe um WhatsApp válido.");
      if (!supabase) throw new Error("Supabase indisponível.");
      const { error } = await supabase.rpc("update_my_barber_profile", {
        p_organization_id: context.organization_id,
        p_display_name: String(data.get("display_name") ?? "").trim(),
        p_whatsapp_e164: whatsapp,
        p_bio: String(data.get("bio") ?? "").trim() || null,
        p_avatar_url: avatarUrl,
      });
      if (error) throw error;
      setMessage("Perfil atualizado.");
      router.refresh();
    } catch (error) {
      setMessage(error instanceof Error ? error.message : "Não foi possível atualizar o perfil.");
    }
  }

  return <>
    <section className={styles.hero}>
      <div>
        <h1 className={styles.title}>Dados pessoais</h1>
      </div>
    </section>
    {message && <p className={styles.notice} role="status">{message}</p>}
    <form className={`${styles.card} ${styles.form}`} onSubmit={save}>
      <div className={styles.row}>
        {avatarUrl ? <Image src={avatarUrl} alt="Foto de perfil" width={78} height={78} unoptimized style={{ borderRadius: "50%", objectFit: "cover" }} /> : <span className={styles.status}>Sem foto</span>}
        <button type="button" className={`${styles.button} ${styles.secondary}`} disabled={savingPhoto} onClick={() => input.current?.click()}><Camera size={16} /> {savingPhoto ? "Salvando foto…" : "Trocar foto"}</button>
        <input ref={input} type="file" accept="image/png,image/jpeg,image/webp" hidden onChange={(event) => { selectPhoto(event.currentTarget.files?.[0]); event.currentTarget.value = ""; }} />
      </div>
      <label>Nome<input name="display_name" defaultValue={context.barber_name} minLength={2} required /></label>
      <label>WhatsApp<input name="whatsapp" defaultValue={context.barber_whatsapp_e164 ?? ""} inputMode="tel" /></label>
      <label>Descrição de perfil<textarea name="bio" defaultValue={context.barber_bio ?? ""} maxLength={1000} /></label>
      <div className={styles.formActions}><button className={styles.button}>Salvar alterações</button></div>
    </form>
    {cropSource && <BarberAvatarCropper imageUrl={cropSource.url} onCancel={() => setCropSource(null)} onApply={saveCroppedPhoto} />}
  </>;
}

function BarberAvatarCropper({ imageUrl, onCancel, onApply }: { imageUrl: string; onCancel: () => void; onApply: (file: File) => Promise<void> }) {
  const imageRef = useRef<HTMLImageElement>(null);
  const dragRef = useRef<{ x: number; y: number; offsetX: number; offsetY: number } | null>(null);
  const [naturalSize, setNaturalSize] = useState({ width: 0, height: 0 });
  const [frameSize, setFrameSize] = useState(280);
  const [zoom, setZoom] = useState(1);
  const [offset, setOffset] = useState({ x: 0, y: 0 });
  const [saving, setSaving] = useState(false);
  const [error, setError] = useState("");
  const baseScale = naturalSize.width && naturalSize.height ? frameSize / Math.min(naturalSize.width, naturalSize.height) : 1;
  const imageWidth = naturalSize.width * baseScale * zoom;
  const imageHeight = naturalSize.height * baseScale * zoom;
  const imageLeft = (frameSize - imageWidth) / 2 + offset.x;
  const imageTop = (frameSize - imageHeight) / 2 + offset.y;

  function clampOffset(next: { x: number; y: number }, nextZoom = zoom) {
    const scale = naturalSize.width && naturalSize.height ? frameSize / Math.min(naturalSize.width, naturalSize.height) * nextZoom : 1;
    const width = naturalSize.width * scale;
    const height = naturalSize.height * scale;
    return {
      x: Math.max(-(width - frameSize) / 2, Math.min((width - frameSize) / 2, next.x)),
      y: Math.max(-(height - frameSize) / 2, Math.min((height - frameSize) / 2, next.y)),
    };
  }

  async function applyCrop() {
    if (!imageRef.current || !naturalSize.width || !naturalSize.height) return;
    setSaving(true);
    setError("");
    try {
      const scale = frameSize / Math.min(naturalSize.width, naturalSize.height) * zoom;
      const sourceX = Math.max(0, Math.min(naturalSize.width - frameSize / scale, -imageLeft / scale));
      const sourceY = Math.max(0, Math.min(naturalSize.height - frameSize / scale, -imageTop / scale));
      const sourceSize = frameSize / scale;
      const canvas = document.createElement("canvas");
      canvas.width = 320;
      canvas.height = 320;
      const context = canvas.getContext("2d");
      if (!context) throw new Error("Não foi possível preparar esta foto.");
      context.drawImage(imageRef.current, sourceX, sourceY, sourceSize, sourceSize, 0, 0, 320, 320);
      const blob = await new Promise<Blob | null>((resolve) => canvas.toBlob(resolve, "image/webp", 0.9));
      if (!blob) throw new Error("Não foi possível preparar esta foto.");
      await onApply(new File([blob], "perfil.webp", { type: "image/webp" }));
    } catch (reason) {
      setError(reason instanceof Error ? reason.message : "Não foi possível preparar esta foto.");
    } finally {
      setSaving(false);
    }
  }

  return <div className={styles.modal} role="presentation" onMouseDown={(event) => { if (event.target === event.currentTarget) onCancel(); }}>
    <section className={`${styles.dialog} ${styles.cropDialog}`} role="dialog" aria-modal="true" aria-labelledby="barber-avatar-crop-title">
      <div className={styles.cropHeading}><div><h2 id="barber-avatar-crop-title">Ajustar foto</h2><p>Arraste a imagem para enquadrar no perfil.</p></div><button className={`${styles.button} ${styles.secondary}`} type="button" onClick={onCancel} aria-label="Fechar editor">×</button></div>
      <div className={styles.cropFrame} onPointerDown={(event) => { if (!naturalSize.width) return; event.currentTarget.setPointerCapture(event.pointerId); dragRef.current = { x: event.clientX, y: event.clientY, offsetX: offset.x, offsetY: offset.y }; }} onPointerMove={(event) => { if (!dragRef.current) return; setOffset(clampOffset({ x: dragRef.current.offsetX + event.clientX - dragRef.current.x, y: dragRef.current.offsetY + event.clientY - dragRef.current.y })); }} onPointerUp={() => { dragRef.current = null; }} onPointerCancel={() => { dragRef.current = null; }}>
        <Image ref={imageRef} src={imageUrl} alt="Prévia para cortar" width={naturalSize.width || 1} height={naturalSize.height || 1} unoptimized draggable={false} className={styles.cropImage} onLoad={(event) => {
          const width = event.currentTarget.naturalWidth;
          const height = event.currentTarget.naturalHeight;
          if (width * height > 40_000_000) {
            setError("Esta foto tem resolução muito alta. Escolha outra imagem com até 40 megapixels.");
            setNaturalSize({ width: 0, height: 0 });
            return;
          }
          setError("");
          setNaturalSize({ width, height });
          setFrameSize(event.currentTarget.parentElement?.clientWidth || 280);
          setOffset({ x: 0, y: 0 });
          setZoom(1);
        }} style={{ width: imageWidth, height: imageHeight, left: imageLeft, top: imageTop }} />
      </div>
      <label className={styles.cropZoom}>Zoom<input type="range" min="1" max="3" step="0.01" value={zoom} onChange={(event) => { const next = Number(event.target.value); setZoom(next); setOffset((current) => clampOffset(current, next)); }} /></label>
      {error && <p className={styles.notice} role="alert">{error}</p>}
      <div className={styles.formActions}><button className={`${styles.button} ${styles.secondary}`} type="button" onClick={onCancel}>Cancelar</button><button className={styles.button} type="button" onClick={() => void applyCrop()} disabled={saving || !naturalSize.width}>{saving ? "Preparando…" : "Usar esta foto"}</button></div>
    </section>
  </div>;
}
