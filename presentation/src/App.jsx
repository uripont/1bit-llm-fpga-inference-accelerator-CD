import { useEffect, useRef, useState } from "react";
import Reveal from "reveal.js";
import RevealNotes from "reveal.js/plugin/notes/notes.esm.js";

import Cover from "./slides/00-Cover";
import Motivation from "./slides/01-Motivation";
import Taalas from "./slides/02-Taalas";
import Talos from "./slides/03-Talos";
import Bonsai from "./slides/04-Bonsai";
import Goal from "./slides/04-Goal";
import ReportsHandoff from "./slides/05-ReportsHandoff";

const slides = [
  Cover,
  Motivation,
  Taalas,
  Talos,
  Bonsai,
  Goal,
  ReportsHandoff,
];

export default function App() {
  const deckRef = useRef(null);
  const deckInstanceRef = useRef(null);
  const [currentSlide, setCurrentSlide] = useState(1);

  useEffect(() => {
    const host = deckRef.current;
    const viewport = () => ({
      width: Math.max(Math.round(host.clientWidth), 1),
      height: Math.max(Math.round(host.clientHeight), 1),
    });
    const deck = new Reveal(host, {
      ...viewport(),
      margin: 0,
      minScale: 1,
      maxScale: 1,
      controls: false,
      touch: true,
      progress: true,
      slideNumber: "c/t",
      hash: true,
      history: true,
      center: false,
      transition: "fade",
      backgroundTransition: "fade",
      plugins: [RevealNotes],
    });

    let disposed = false;
    let resizeFrame;
    let resizeObserver;
    let tapStart;

    const updateSlideNumber = (event) => {
      setCurrentSlide((event.indexh ?? deck.getIndices().h) + 1);
    };

    const isInteractive = (target) =>
      target instanceof Element && Boolean(target.closest("a, button, input, select, textarea, summary"));

    const handlePointerDown = (event) => {
      if (!event.isPrimary || isInteractive(event.target)) return;
      tapStart = {
        id: event.pointerId,
        x: event.clientX,
        y: event.clientY,
        time: performance.now(),
      };
    };

    const handlePointerUp = (event) => {
      if (!tapStart || tapStart.id !== event.pointerId || isInteractive(event.target)) {
        tapStart = undefined;
        return;
      }

      const distance = Math.hypot(event.clientX - tapStart.x, event.clientY - tapStart.y);
      const duration = performance.now() - tapStart.time;
      tapStart = undefined;
      if (distance > 12 || duration > 500 || window.getSelection()?.toString()) return;

      const bounds = host.getBoundingClientRect();
      if (event.clientX - bounds.left < bounds.width / 2) deck.prev();
      else deck.next();
    };

    const cancelTap = () => {
      tapStart = undefined;
    };

    host.addEventListener("pointerdown", handlePointerDown);
    host.addEventListener("pointerup", handlePointerUp);
    host.addEventListener("pointercancel", cancelTap);
    deck.on("ready", updateSlideNumber);
    deck.on("slidechanged", updateSlideNumber);
    deckInstanceRef.current = deck;

    deck.initialize().then(() => {
      if (disposed) return;

      resizeObserver = new ResizeObserver(() => {
        cancelAnimationFrame(resizeFrame);
        resizeFrame = requestAnimationFrame(() => {
          deck.configure(viewport());
          deck.layout();
        });
      });
      resizeObserver.observe(host);
    });

    return () => {
      disposed = true;
      resizeObserver?.disconnect();
      cancelAnimationFrame(resizeFrame);
      host.removeEventListener("pointerdown", handlePointerDown);
      host.removeEventListener("pointerup", handlePointerUp);
      host.removeEventListener("pointercancel", cancelTap);
      deck.off("ready", updateSlideNumber);
      deck.off("slidechanged", updateSlideNumber);
      deckInstanceRef.current = null;
      deck.destroy();
    };
  }, []);

  return (
    <>
      <div className="reveal" ref={deckRef}>
        <div className="slides">
          {slides.map((Slide, index) => (
            <Slide key={index} />
          ))}
        </div>
      </div>
      <div className="deck-page-count" aria-live="polite">
        {currentSlide} / {slides.length}
      </div>
      <nav className="deck-arrows" aria-label="Slide navigation">
        <button
          type="button"
          aria-label="Previous slide"
          disabled={currentSlide === 1}
          onClick={() => deckInstanceRef.current?.prev()}
        >
          ‹
        </button>
        <button
          type="button"
          aria-label="Next slide"
          disabled={currentSlide === slides.length}
          onClick={() => deckInstanceRef.current?.next()}
        >
          ›
        </button>
      </nav>
    </>
  );
}
