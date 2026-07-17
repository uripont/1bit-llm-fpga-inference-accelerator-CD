import { useEffect, useRef, useState } from "react";
import { Slide } from "../components/Slide";

const TOKEN_RATE = 80;
const responseText =
  "Large language models can answer questions, write code, summarize documents, reason through problems, and assist across many domains. That breadth makes every generated token a meaningful compute workload, while visible response latency still shapes how useful the experience feels.";
const responseTokens = responseText.split(/\s+/);

function TypicalResponseStream() {
  const scrollerRef = useRef(null);
  const [output, setOutput] = useState("");

  useEffect(() => {
    const slide = scrollerRef.current?.closest(".project-slide");
    if (!slide) return undefined;

    let frame;
    let cursor = 0;
    let buffer = [];
    let previousTime;
    let tokenRemainder = 0;
    let totalGenerated = 0;

    const stop = () => {
      window.cancelAnimationFrame(frame);
      frame = undefined;
      previousTime = undefined;
    };

    const draw = (time) => {
      if (previousTime === undefined) previousTime = time;
      const elapsed = Math.min(time - previousTime, 50);
      previousTime = time;
      tokenRemainder += elapsed * (TOKEN_RATE / 1000);
      const tokensToAdd = Math.floor(tokenRemainder);
      tokenRemainder -= tokensToAdd;
      totalGenerated += tokensToAdd;

      if (scrollerRef.current) {
        scrollerRef.current.dataset.generatedTokens = String(totalGenerated);
      }

      for (let index = 0; index < tokensToAdd; index += 1) {
        buffer.push(responseTokens[cursor]);
        cursor = (cursor + 1) % responseTokens.length;
      }

      if (buffer.length > 360) buffer = buffer.slice(-320);
      setOutput(buffer.join(" "));
      frame = window.requestAnimationFrame(draw);
    };

    const start = () => {
      stop();
      cursor = 0;
      buffer = [];
      tokenRemainder = 0;
      totalGenerated = 0;

      if (scrollerRef.current) {
        scrollerRef.current.dataset.generatedTokens = "0";
      }

      if (window.matchMedia("(prefers-reduced-motion: reduce)").matches) {
        setOutput(responseText);
        return;
      }

      setOutput("");
      frame = window.requestAnimationFrame(draw);
    };

    const sync = () => {
      if (slide.classList.contains("present")) start();
      else stop();
    };

    const observer = new MutationObserver(sync);
    observer.observe(slide, { attributes: true, attributeFilter: ["class"] });
    sync();

    return () => {
      observer.disconnect();
      stop();
    };
  }, []);

  useEffect(() => {
    const scroller = scrollerRef.current;
    if (scroller) scroller.scrollTop = scroller.scrollHeight;
  }, [output]);

  return (
    <div
      className="taalas-response-scroller"
      data-token-rate={TOKEN_RATE}
      ref={scrollerRef}
    >
      <p className="taalas-response-copy">
        <span className="taalas-assistant-mark" aria-hidden="true">✦</span>
        {output}<i className="taalas-response-cursor" />
      </p>
    </div>
  );
}

const mainPoints = [
  ["Broadly useful", "One model can write, reason, code, analyze, and support many products."],
  ["General-purpose hardware", "Most inference still runs on flexible GPU infrastructure."],
  ["Visible latency", "At 80 tokens per second, the response still visibly unfolds in front of the user."],
  ["Latency is the value", "Faster inference delivers the same intelligent result sooner."],
];

export default function Motivation() {
  return (
    <Slide
      className="motivation-slide"
      title="LLM inference is becoming a key compute workload"
    >
      <div className="grid-2 taalas-layout">
        <div className="taalas-model-panel">
          <div className="model-output-header model-output-header-blank" aria-hidden="true">
            <h3>&nbsp;</h3>
          </div>
          <div className="taalas-model-window output-points-window">
            <ul className="output-point-list output-point-list-four">
              {mainPoints.map(([title, detail]) => (
                <li key={title}>
                  <h3>{title}</h3>
                  <p>{detail}</p>
                </li>
              ))}
            </ul>
          </div>
          <div className="taalas-panel-footer" aria-hidden="true" />
        </div>

        <div
          className="taalas-stream"
          role="img"
          aria-label="An assistant-style response generated at 80 tokens per second"
        >
          <div className="model-output-header model-output-header-speed-only">
            <h3>80 tok/s</h3>
          </div>
          <div className="taalas-stream-window" aria-hidden="true">
            <TypicalResponseStream />
          </div>
          <div className="taalas-panel-footer taalas-token-cadence">
            <span>one token every</span>
            <strong>12.5 ms</strong>
          </div>
        </div>
      </div>

      <aside className="notes">
        LLMs are broadly useful and now form a major compute workload. At a representative 80 tokens per second, generation is responsive but still visibly unfolds; specialized acceleration reduces that wait without narrowing model capability.
      </aside>
    </Slide>
  );
}
