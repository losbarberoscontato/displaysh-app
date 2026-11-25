"use client";

import { MapPin, Search } from "lucide-react";
import styles from "@/components/connected-client/connected-client.module.css";

export function ClientMapHome() {
  return (
    <section className={styles.mapHome} aria-labelledby="map-home-title">
      <h1 id="map-home-title">Encontre o serviço que precisa</h1>
      <label className={styles.mapSearch}>
        <Search size={20} aria-hidden="true" />
        <input type="search" placeholder="Qual serviço você precisa hoje?" aria-label="Qual serviço você precisa hoje?" />
      </label>
      <div className={styles.mapCanvas} role="img" aria-label="Protótipo de mapa com estabelecimentos próximos">
        <span className={styles.mapPrototype}>Protótipo do mapa</span>
        <span className={`${styles.mapRoad} ${styles.mapRoadPrimary}`} />
        <span className={`${styles.mapRoad} ${styles.mapRoadSecondary}`} />
        <span className={`${styles.mapRoad} ${styles.mapRoadCross}`} />
        <span className={`${styles.mapBlock} ${styles.mapBlockOne}`} />
        <span className={`${styles.mapBlock} ${styles.mapBlockTwo}`} />
        <span className={`${styles.mapBlock} ${styles.mapBlockThree}`} />
        <span className={`${styles.mapBlock} ${styles.mapBlockFour}`} />
        <span className={`${styles.mapPin} ${styles.mapPinOne}`}><MapPin size={24} aria-hidden="true" /></span>
        <span className={`${styles.mapPin} ${styles.mapPinTwo}`}><MapPin size={24} aria-hidden="true" /></span>
        <span className={`${styles.mapPin} ${styles.mapPinThree}`}><MapPin size={24} aria-hidden="true" /></span>
        <span className={styles.mapYouAreHere}>Você está aqui</span>
      </div>
    </section>
  );
}
