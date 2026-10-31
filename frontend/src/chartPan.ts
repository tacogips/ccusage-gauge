/** Keep native touch/trackpad momentum; add the same grab gesture for a mouse. */
export function attachChartPan(element: HTMLElement, onPan: () => void): () => void {
  let drag: { pointerId: number; x: number; time: number; velocity: number } | undefined;
  let frame: number | undefined;
  const stopMomentum = () => { if (frame != null) cancelAnimationFrame(frame); frame = undefined; };
  const down = (event: PointerEvent) => {
    stopMomentum();
    if (event.pointerType !== "mouse" || event.button !== 0 || element.scrollWidth <= element.clientWidth) return;
    drag = { pointerId: event.pointerId, x: event.clientX, time: event.timeStamp, velocity: 0 };
    element.setPointerCapture(event.pointerId);
    element.classList.add("is-panning");
    onPan();
  };
  const move = (event: PointerEvent) => {
    if (!drag || event.pointerId !== drag.pointerId) return;
    const delta = drag.x - event.clientX;
    const elapsed = Math.max(1, event.timeStamp - drag.time);
    drag.velocity = delta / elapsed;
    drag.x = event.clientX;
    drag.time = event.timeStamp;
    element.scrollLeft += delta;
    onPan();
    event.preventDefault();
  };
  const finish = (event: PointerEvent) => {
    if (!drag || event.pointerId !== drag.pointerId) return;
    const velocity = event.timeStamp - drag.time > 100 ? 0 : drag.velocity;
    drag = undefined;
    element.classList.remove("is-panning");
    if (element.hasPointerCapture(event.pointerId)) element.releasePointerCapture(event.pointerId);
    if (event.type === "pointercancel" || matchMedia("(prefers-reduced-motion: reduce)").matches) return;
    let speed = velocity;
    let previous = performance.now();
    const coast = (time: number) => {
      const elapsed = Math.min(time - previous, 40);
      previous = time;
      const before = element.scrollLeft;
      element.scrollLeft += speed * elapsed;
      speed *= Math.exp(-elapsed / 180);
      if (Math.abs(speed) > 0.015 && element.scrollLeft !== before) frame = requestAnimationFrame(coast);
      else frame = undefined;
    };
    if (Math.abs(speed) > 0.015) frame = requestAnimationFrame(coast);
  };
  element.addEventListener("pointerdown", down);
  element.addEventListener("pointermove", move);
  element.addEventListener("pointerup", finish);
  element.addEventListener("pointercancel", finish);
  element.addEventListener("wheel", stopMomentum, { passive: true });
  return () => {
    stopMomentum();
    element.classList.remove("is-panning");
    element.removeEventListener("pointerdown", down);
    element.removeEventListener("pointermove", move);
    element.removeEventListener("pointerup", finish);
    element.removeEventListener("pointercancel", finish);
    element.removeEventListener("wheel", stopMomentum);
  };
}
