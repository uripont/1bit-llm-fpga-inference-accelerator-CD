import { ModelScale, Slide } from "../components/Slide";

const mainPoints = [
  ["Weights become cheap", "Q1_0 packs 128 one-bit signs plus one FP16 scale into an 18-byte block."],
  ["The Transformer stays full", "28 decoder layers · 2,048 hidden width · 6,144 feed-forward width."],
  ["Structure still dominates", "Grouped-query attention and a 151,669-token vocabulary keep the full-model dataflow."],
];

export default function Bonsai() {
  return (
    <Slide
      className="bonsai-model-slide"
      title="Bonsai-1.7B uses one-bit Transformer weights"
    >
      <div className="grid-2 taalas-layout bonsai-paired-layout">
        <div className="taalas-model-panel">
          <div className="model-output-header model-output-header-size">
            <h3>1.7B parameters</h3>
          </div>
          <div className="taalas-model-window">
            <ModelScale
              value="1.7B parameters"
              detail="170 boxes · 10M parameters each"
              size="large"
              showCopy={false}
              activeCells={170}
            />
          </div>
          <div className="taalas-panel-footer bonsai-memory-footer">
            <h3>≈242 MB model image</h3>
          </div>
        </div>

        <div className="taalas-stream bonsai-points-panel">
          <div className="model-output-header model-output-header-blank" aria-hidden="true">
            <h3>&nbsp;</h3>
          </div>
          <div className="taalas-model-window output-points-window">
            <ul className="output-point-list">
              {mainPoints.map(([title, detail]) => (
                <li key={title}>
                  <h3>{title}</h3>
                  <p>{detail}</p>
                </li>
              ))}
            </ul>
          </div>
          <div className="taalas-panel-footer">
            <p className="bonsai-host-summary">Full-model behavior stays on the host; board experiments preserve Bonsai’s operation shapes within an ≈1 MB memory budget.</p>
          </div>
        </div>
      </div>

      <aside className="notes">Bonsai is a real 1.7B-parameter Qwen3-family model with an approximately 242 MB Q1_0 image. Quantization compresses its weights, while the surrounding 28-layer Transformer structure and data movement remain.</aside>
    </Slide>
  );
}
