import { useEffect, useRef, useState } from "react";
import { ModelScale, Slide, Source } from "../components/Slide";

const TOKEN_RATE = 17_000;
const assistantResponse =
  "Certainly — here is a concise explanation. A dedicated inference chip fixes the model’s weights and execution path directly in silicon. That removes the overhead of fetching instructions and moving parameters through general-purpose hardware. The trade-off is flexibility: the same device cannot easily switch to another model, but for its chosen workload it can deliver complete answers almost as soon as they are requested. In practice, a response of this length would be generated many times over before a human reader reached the end.";
const responseTokens = assistantResponse.split(/\s+/);

function LanguageResponseStream() {
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
      const elapsed = Math.min(time - previousTime, 32);
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

      if (buffer.length > 900) buffer = buffer.slice(-900);
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
        setOutput(assistantResponse);
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
    if (!scroller) return;

    const maxScroll = scroller.scrollHeight - scroller.clientHeight;
    if (maxScroll <= 0) return;

    const nextScroll = scroller.scrollTop + Math.max(18, scroller.clientHeight * 0.08);
    scroller.scrollTop = nextScroll >= maxScroll ? 0 : nextScroll;
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

export default function Taalas() {
  return (
    <Slide
      title="Taalas: “the model is the computer”"
      source={<><Source href="https://taalas.com/products/">Taalas Hc1 product page</Source> · performance is a vendor claim</>}
    >
      <div className="grid-2 taalas-layout">
        <div className="taalas-model-panel">
          <div className="model-output-header model-output-header-size">
            <h3>8B parameters</h3>
          </div>
          <div className="taalas-model-window">
            <ModelScale
              value="8B parameters"
              detail="800 boxes · 10M weights each"
              size="large"
              showCopy={false}
            />
          </div>
          <div className="taalas-panel-footer">
            <p className="taalas-model-summary">Model fixed in silicon: built datapaths, static execution, and memory-bound data movement optimized for this workload.</p>
          </div>
        </div>
        <div
          className="taalas-stream taalas-stream-output-only"
          role="img"
          aria-label="An assistant-style response flowing vertically at 17,000 tokens per second"
        >
          <div className="model-output-header model-output-header-speed-only">
            <h3>17,000 tok/s</h3>
          </div>
          <div className="taalas-stream-window" aria-hidden="true">
            <LanguageResponseStream />
          </div>
          <div className="taalas-panel-footer taalas-token-cadence">
            <span>one token every</span>
            <strong>59 μs</strong>
          </div>
        </div>
      </div>
      <aside className="notes">Taalas is motivation, not a comparison point. Their Asic fixes an entire 8B model; this project targets two services on a tiny fpga.</aside>
    </Slide>
  );
}
