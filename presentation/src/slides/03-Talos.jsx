import { useEffect, useRef, useState } from "react";
import { ModelScale, Slide, Source } from "../components/Slide";

const TOKEN_RATE = 50_000;
const COLUMN_COUNT = 6;
const MAX_VISIBLE_ROWS = 7;
const generatedNames = [
  "kri", "maren", "salia", "elora", "niko", "amira",
  "tavi", "luma", "orin", "vesa", "cira", "daro",
  "mira", "soren", "alia", "reno", "kiva", "tala",
];

function namesForRow(rowIndex) {
  const offset = (rowIndex * COLUMN_COUNT) % generatedNames.length;
  return Array.from(
    { length: COLUMN_COUNT },
    (_, column) => generatedNames[(offset + column) % generatedNames.length],
  );
}

function CharacterGenerator() {
  const hostRef = useRef(null);
  const [output, setOutput] = useState({ rows: [], activeColumn: 0 });

  useEffect(() => {
    const slide = hostRef.current?.closest(".project-slide");
    if (!slide) return undefined;

    let frame;
    let rowIndex = 0;
    let columnIndex = 0;
    let characterIndex = 0;
    let targetNames = namesForRow(rowIndex);
    let currentRow = Array(COLUMN_COUNT).fill("");
    let completedRows = [];
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
      const elapsed = Math.min(time - previousTime, 60);
      previousTime = time;
      tokenRemainder += elapsed * (TOKEN_RATE / 1000);
      const tokensToAdd = Math.floor(tokenRemainder);
      tokenRemainder -= tokensToAdd;
      totalGenerated += tokensToAdd;

      if (hostRef.current) {
        hostRef.current.dataset.generatedCharacters = String(totalGenerated);
      }

      for (let index = 0; index < tokensToAdd; index += 1) {
        const targetName = targetNames[columnIndex];
        currentRow[columnIndex] += targetName[characterIndex];
        characterIndex += 1;

        if (characterIndex >= targetName.length) {
          characterIndex = 0;
          columnIndex += 1;

          if (columnIndex >= COLUMN_COUNT) {
            completedRows.push(currentRow);
            completedRows = completedRows.slice(-(MAX_VISIBLE_ROWS - 1));
            rowIndex += 1;
            columnIndex = 0;
            targetNames = namesForRow(rowIndex);
            currentRow = Array(COLUMN_COUNT).fill("");
          }
        }
      }

      setOutput({
        rows: [...completedRows, currentRow].slice(-MAX_VISIBLE_ROWS),
        activeColumn: columnIndex,
      });
      frame = window.requestAnimationFrame(draw);
    };

    const start = () => {
      stop();
      rowIndex = 0;
      columnIndex = 0;
      characterIndex = 0;
      targetNames = namesForRow(rowIndex);
      currentRow = Array(COLUMN_COUNT).fill("");
      completedRows = [];
      tokenRemainder = 0;
      totalGenerated = 0;

      if (hostRef.current) hostRef.current.dataset.generatedCharacters = "0";

      if (window.matchMedia("(prefers-reduced-motion: reduce)").matches) {
        setOutput({
          rows: Array.from({ length: 4 }, (_, index) => namesForRow(index)),
          activeColumn: COLUMN_COUNT - 1,
        });
        return;
      }

      setOutput({ rows: [], activeColumn: 0 });
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

  return (
    <div
      className="letter-name-output"
      data-character-rate={TOKEN_RATE}
      ref={hostRef}
    >
      {output.rows.map((row, rowPosition) => (
        <div className="letter-name-row" key={rowPosition}>
          {row.map((name, column) => (
            <span className="letter-name-cell" key={column}>
              {name}
              {rowPosition === output.rows.length - 1 && column === output.activeColumn
                ? <i className="talos-text-cursor" />
                : null}
            </span>
          ))}
        </div>
      ))}
    </div>
  );
}

export default function Talos() {
  return (
    <Slide
      className="talos-slide"
      title="Talos V2: microGpt lowered into FPGA hardware"
      source={<><Source href="https://v2.talos.wtf/">Talos V2 write-up</Source> · <Source href="https://github.com/Luthiraa/TALOS-V2">source repository</Source></>}
    >
      <div className="grid-2 taalas-layout">
        <div className="taalas-model-panel">
          <div className="model-output-header model-output-header-size">
            <h3>4,192 parameters</h3>
          </div>
          <div className="taalas-model-window">
            <ModelScale
              value="4,192 parameters"
              detail="0 full boxes · 0.00042 of one 10M-weight box"
              size="toy"
              showCopy={false}
            />
          </div>
          <div className="taalas-panel-footer">
            <p className="taalas-model-summary">Toy Transformer mapped end to end into FPGA hardware: weights in ROM, a reused 16-lane MatVec, scheduled attention, and on-chip sampling.</p>
          </div>
        </div>

        <div
          className="taalas-stream"
          role="img"
          aria-label="Talos generating six name-like words per row, one character at a time, at 50,000 characters per second"
        >
          <div className="model-output-header model-output-header-speed-only">
            <h3>50k char/s</h3>
          </div>
          <div className="letter-stream-window" aria-hidden="true">
            <CharacterGenerator />
          </div>
          <div className="taalas-panel-footer taalas-token-cadence">
            <span>one character every</span>
            <strong>20 µs</strong>
          </div>
        </div>
      </div>

      <aside className="notes">Talos demonstrates a complete Transformer mapped into FPGA hardware, but at toy scale: 4,192 parameters and character-by-character name generation at 50,000 characters per second, displayed in rows of six names.</aside>
    </Slide>
  );
}
