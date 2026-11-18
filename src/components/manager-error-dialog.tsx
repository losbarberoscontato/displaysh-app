"use client";

import { useEffect, useRef, useState } from "react";
import { AlertCircle } from "lucide-react";
import styles from "./manager-error-dialog.module.css";

const EVENT_NAME = "displaysh:manager-error";
type ErrorNotice = {
  message: string;
  title: string;
  actionColor?: string;
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
    actionColor: options?.action ? resolveActionColor() : undefined,
    action: options?.action,
  };
  if (listeners.size === 0) {
    pendingMessages.push(notice);
    return;
  }
  window.dispatchEvent(new CustomEvent(EVENT_NAME, { detail: notice }));
}

function resolveActionColor() {
  const themedPage = document.querySelector<HTMLElement>('dialog[aria-labelledby="booking-step-title"][open]')
    ?? document.querySelector<HTMLElement>(".manager-shell, .productTheme")
    ?? document.documentElement;
  const styles = window.getComputedStyle(themedPage);
  return styles.getPropertyValue("--manager-action-bg").trim()
    || styles.getPropertyValue("--forest-900").trim()
    || undefined;
}

export function ManagerErrorDialog() {
  const [messages, setMessages] = useState<ErrorNotice[]>([]);
  const dialogRef = useRef<HTMLDialogElement>(null);
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
    const dialog = dialogRef.current;
    if (!dialog || !notice) return;
    if (!dialog.open) {
      if (typeof dialog.showModal === "function") dialog.showModal();
      else dialog.setAttribute("open", "");
    }
    okButtonRef.current?.focus();
  }, [notice]);

  if (!notice) return null;

  return (
    <dialog
      ref={dialogRef}
      className={styles.overlay}
      role="alertdialog"
      aria-modal="true"
      aria-labelledby="manager-error-title"
      aria-describedby="manager-error-message"
      onCancel={(event) => event.preventDefault()}
    >
      <section className={styles.dialog}>
        <span className={styles.icon}><AlertCircle size={22} aria-hidden="true" /></span>
        <div className={styles.content}>
          <h2 id="manager-error-title">{notice.title}</h2>
          <p id="manager-error-message">{notice.message}</p>
        </div>
        <button ref={okButtonRef} type="button" className={styles.okButton} style={notice.actionColor ? { backgroundColor: notice.actionColor } : undefined} onClick={() => {
          setMessages((current) => current.slice(1));
          notice.action?.onClick();
        }}>
          {notice.action?.label ?? "OK"}
        </button>
      </section>
    </dialog>
  );
}
