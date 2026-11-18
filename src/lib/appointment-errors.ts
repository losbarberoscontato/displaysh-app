export const APPOINTMENT_SCHEDULE_CONFLICT_MESSAGE =
  "A duração do serviço ultrapassa o fim da escala deste profissional. Escolha um horário que termine dentro da jornada.";

const APPOINTMENT_OUTSIDE_SCHEDULE_ERROR = "appointment is outside the current barber schedule";

export function isAppointmentOutsideCurrentSchedule(error: unknown) {
  const message = error instanceof Error
    ? error.message
    : typeof error === "object" && error !== null && "message" in error
      ? String(error.message ?? "")
      : "";

  return message.toLowerCase().includes(APPOINTMENT_OUTSIDE_SCHEDULE_ERROR);
}
