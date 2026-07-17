import { Slide } from "../components/Slide";

const steps = [
  ["01", "Tier 1", "Real llama.cpp timing"],
  ["02", "Tier 2", "Explicit model operation ledger"],
  ["03", "Tier 3", "Neorv32 software baselines"],
  ["04", "Blueprint", "Services, interfaces and counters"],
  ["05", "hardware", "Proposal A and B engines"],
  ["06", "Evaluation", "Cycles, correctness and synthesis"],
];

export default function Method() {
  return (
    <Slide title="Three benchmark tiers bridge model behavior to hardware">
      <div className="timeline">
        {steps.map(([number, title, detail], index) => (
          <div className={`timeline-step ${index > 0 ? "fragment" : ""}`} key={number}>
            <strong>{number} · {title}</strong><p>{detail}</p>
          </div>
        ))}
      </div>
      <aside className="notes">Each tier answers a different question. The separation prevents a synthetic kernel from being mistaken for full-model performance.</aside>
    </Slide>
  );
}
