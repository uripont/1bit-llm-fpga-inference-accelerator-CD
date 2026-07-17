import { Slide } from "../components/Slide";

const benchmarkTiers = [
  ["Tier 1", "Real llama.cpp timing"],
  ["Tier 2", "Explicit operation ledger"],
  ["Tier 3", "Neorv32 baselines"],
];

const architectureEntries = [
  ["Proposal A", "Q1_0 row engine"],
  ["Proposal B", "Attention / K/V engine"],
  ["Shared shell", "Interfaces and counters"],
];

const evaluationEntries = [
  ["cpu push", "Software-delivered tiles"],
  ["memory stream", "Direct memory delivery"],
  ["Synthesis", "Board fit and timing"],
];

const reportPages = (folder, count) =>
  Array.from({ length: count }, (_, index) =>
    `/report-previews/${folder}/page-${index + 1}.jpg`,
  );

const benchmarkReportPages = reportPages("benchmark", 5);
const architectureReportPages = reportPages("architecture", 9);
const evaluationReportPages = reportPages("evaluation", 2);

function SubentryList({ entries }) {
  return (
    <ul className="method-subentry-list">
      {entries.map(([label, detail]) => (
        <li key={label}>
          <strong>{label}</strong>
          <span>{detail}</span>
        </li>
      ))}
    </ul>
  );
}

function ReportStack({ label, pages }) {
  const midpoint = (pages.length - 1) / 2;

  return (
    <figure
      className="method-report-stack"
      aria-label={`${label}, ${pages.length}-page PDF report`}
    >
      {pages.map((src, index) => {
        const distance = index - midpoint;

        return (
          <img
            key={src}
            src={src}
            alt=""
            aria-hidden="true"
            loading="eager"
            style={{
              "--page-x": `${distance * 18}px`,
              "--page-y": `${Math.abs(distance) * 1.25}px`,
              "--page-rotate": `${distance * 1.15}deg`,
              "--page-mobile-x": `${distance * 7}px`,
              "--page-mobile-rotate": `${distance * 0.65}deg`,
              "--page-delay": `${470 + index * 55}ms`,
              "--page-z": pages.length - index,
            }}
          />
        );
      })}
    </figure>
  );
}

export default function Goal() {
  return (
    <Slide
      className="method-overview-slide"
      title="Project stages followed, from model behaviour to measured hardware"
    >
      <div className="method-path" aria-label="Benchmarking, architecting, implementation and evaluation">
        <article
          className="method-stage method-stage-benchmarking fragment"
          data-fragment-index="0"
        >
          <div className="method-marker" aria-hidden="true"><span>01</span></div>
          <h3>Benchmarking</h3>
          <p className="method-purpose">Reproduce measured model work at hardware scale.</p>
          <SubentryList entries={benchmarkTiers} />
          <ReportStack label="Benchmarking" pages={benchmarkReportPages} />
        </article>

        <article className="method-stage fragment" data-fragment-index="1">
          <div className="method-marker" aria-hidden="true"><span>02</span></div>
          <h3>Architecting</h3>
          <p className="method-purpose">Define bounded services, interfaces and data movement.</p>
          <SubentryList entries={architectureEntries} />
          <ReportStack label="Architecting" pages={architectureReportPages} />
        </article>

        <article className="method-stage fragment" data-fragment-index="2">
          <div className="method-marker" aria-hidden="true"><span>03</span></div>
          <h3>Implementation + evaluation</h3>
          <p className="method-purpose">Build, verify cycles and test board feasibility.</p>
          <SubentryList entries={evaluationEntries} />
          <ReportStack label="Implementation and evaluation" pages={evaluationReportPages} />
        </article>
      </div>
      <aside className="notes">This is the project method, not the result. First we benchmark at three levels, then define Proposal A, Proposal B and their shared shell, and finally implement and compare processor-push and memory-stream delivery before synthesis.</aside>
    </Slide>
  );
}
