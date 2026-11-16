"use client";

import { useEffect, useRef, useState } from "react";
import { AlertCircle } from "lucide-react";
import styles from "./manager-error-dialog.module.css";

const EVENT_NAME = "displaysh:manager-error";
const pendingMessages: string[] = [];
const listeners = new Set<(message: string) => void>();

export function showManagerError(message: string) {
  const cleanMessage = message.trim();
  if (!cleanMessage || typeof window === "undefined") return;
  if (listeners.size === 0) {
    pendingMessages.push(cleanMessage);
    return;
  }
  window.dispatchEvent(new CustomEvent(EVENT_NAME, { detail: cleanMessage }));
}

export function ManagerErrorDialog() {
  const [messages, setMessages] = useState<string[]>([]);
  const okButtonRef = useRef<HTMLButtonElement>(null);
  const message = messages[0] ?? "";

  useEffect(() => {
    const enqueue = (nextMessage: string) => setMessages((current) => [...current, nextMessage]);
    listeners.add(enqueue);
    for (const pending of pendingMessages.splice(0)) enqueue(pending);

    const handleError = (event: Event) => {
      const detail = (event as CustomEvent<string>).detail;
      if (typeof detail === "string" && detail.trim()) enqueue(detail.trim());
    };
    window.addEventListener(EVENT_NAME, handleError);
    return () => {
      listeners.delete(enqueue);
      window.removeEventListener(EVENT_NAME, handleError);
    };
  }, []);

  useEffect(() => {
    if (message) okButtonRef.current?.focus();
  }, [message]);

  if (!message) return null;

  return (
    <div className={styles.overlay}>
      <section className={styles.dialog} role="alertdialog" aria-modal="true" aria-labelledby="manager-error-title" aria-describedby="manager-error-message">
        <span className={styles.icon}><AlertCircle size={22} aria-hidden="true" /></span>
        <div className={styles.content}>
          <h2 id="manager-error-title">Não foi possível concluir</h2>
          <p id="manager-error-message">{message}</p>
        </div>
        <button ref={okButtonRef} type="button" className={styles.okButton} onClick={() => setMessages((current) => current.slice(1))}>
          OK
        </button>
      </section>
    </div>
  );
}
