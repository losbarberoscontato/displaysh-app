"use client";

import { useEffect, useRef, useState } from "react";
import { AlertCircle } from "lucide-react";
import styles from "./manager-error-dialog.module.css";

const EVENT_NAME = "displaysh:manager-error";
type ErrorNotice = {
  message: string;
  title: string;
  action?: { label: string; onClick: () => void };
};

const pendingMessages: ErrorNotice[] = [];
const listeners = new Set<(notice: ErrorNotice) => void>();

export function showManagerError(
  message: string,
  options?: { title?: string; action?: ErrorNotice["action"] },
) {
  const cleanMessage = message.trim();
  if (!cleanMessage || typeof window === "undefined") return;
  const notice: ErrorNotice = {
    message: cleanMessage,
    title: options?.title?.trim() || "Não foi possível concluir",
    action: options?.action,
  };
  if (listeners.size === 0) {
    pendingMessages.push(notice);
    return;
  }
  window.dispatchEvent(new CustomEvent(EVENT_NAME, { detail: notice }));
}

export function ManagerErrorDialog() {
  const [messages, setMessages] = useState<ErrorNotice[]>([]);
  const okButtonRef = useRef<HTMLButtonElement>(null);
  const notice = messages[0] ?? null;

  useEffect(() => {
    const enqueue = (nextNotice: ErrorNotice) => setMessages((current) => [...current, nextNotice]);
    listeners.add(enqueue);
    for (const pending of pendingMessages.splice(0)) enqueue(pending);

    const handleError = (event: Event) => {
      const detail = (event as CustomEvent<ErrorNotice>).detail;
      if (detail && typeof detail.message === "string" && detail.message.trim()) enqueue(detail);
    };
    window.addEventListener(EVENT_NAME, handleError);
    return () => {
      listeners.delete(enqueue);
      window.removeEventListener(EVENT_NAME, handleError);
    };
  }, []);

  useEffect(() => {
    if (notice) okButtonRef.current?.focus();
  }, [notice]);

  if (!notice) return null;

  return (
    <div className={styles.overlay}>
      <section className={styles.dialog} role="alertdialog" aria-modal="true" aria-labelledby="manager-error-title" aria-describedby="manager-error-message">
        <span className={styles.icon}><AlertCircle size={22} aria-hidden="true" /></span>
        <div className={styles.content}>
          <h2 id="manager-error-title">{notice.title}</h2>
          <p id="manager-error-message">{notice.message}</p>
        </div>
        <button ref={okButtonRef} type="button" className={styles.okButton} onClick={() => {
          setMessages((current) => current.slice(1));
          notice.action?.onClick();
        }}>
          {notice.action?.label ?? "OK"}
        </button>
      </section>
    </div>
  );
}
